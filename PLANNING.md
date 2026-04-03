# Multi-Server SSH Command Dispatcher — Thought Process & Planning Guide

---

## Step 1: Understand What You're Actually Building

Before touching any code, read the requirements twice and ask yourself: *"What problem does this solve in the real world?"*

This script is essentially a **remote execution fan-out** — you give it one command and it fires that command at every server simultaneously, then collects and presents the results. Think of it like a conductor leading an orchestra: every musician (server) plays at the same time, but the conductor (script) listens to each one and tells you who hit the right notes and who didn't.

Key insight: the word **"parallel"** is the most important part. Sequential SSH calls are fine for 3 servers. For 30, you're waiting minutes. Parallel background jobs mean all servers are contacted at once, and the total wait time is roughly the slowest single server — not the sum of all servers.

The second key insight: **you must not wait forever**. Networks drop. Servers hang. A missing timeout turns a 10-second script into one that blocks indefinitely on a single dead host.

---

## Step 2: Break Down the Problem Into Domains

Brainstorm every concern this script touches, grouped by domain:

**Configuration**
- Where does the server list live? (`servers.conf`)
- What fields does each entry need? (hostname, IP, SSH user)
- How do I parse it cleanly? (skip comments, skip blank lines)

**Execution**
- How do I run SSH in the background? (`&` with `ssh -o ConnectTimeout`)
- How do I pass an arbitrary command? (positional argument `$1`)
- How do I capture each server's output separately?
- How do I know when all background jobs are done? (`wait`)

**Timeout Handling**
- SSH has a built-in `ConnectTimeout` for the handshake — use it
- For command execution time, use `timeout` wrapper or `ssh -o ServerAliveInterval`
- What exit code does a timeout produce vs a real failure?

**Output & Status**
- Each server runs in a subshell — output must be buffered, not interleaved
- Colour-code: green = success, red = failure, yellow = timeout
- Display server identity alongside its output block

**Summary**
- Count successes, failures, and timeouts
- Print totals at the end

---

## Step 3: Identify the Hard Parts Early

This is where most beginners skip ahead and get stuck. Ask yourself: *"What's the trickiest part of this?"*

The hardest part here is **output isolation** — when 10 SSH processes run in parallel and all write to stdout at the same time, their output lines interleave into an unreadable mess. You need to buffer each server's output and print it as a single atomic block.

Options to brainstorm:
- Capture output into a variable inside a subshell, print it all at once when the job finishes
- Write each server's output to a temp file, then read and print them in order after `wait`
- Use a named pipe per server (overkill for this use case)

The temp file approach is the most reliable — it survives even if the subshell crashes, and you can read results in a predictable order after all jobs complete.

Second hardest: **distinguishing timeout from genuine failure**. The `timeout` command exits with code `124` on timeout. SSH itself exits non-zero for connection refused, auth failure, and remote command failure — all different codes. You need to check for `124` specifically before treating everything else as a generic failure.

---

## Step 4: Design the Data Flow (Before Writing Code)

Draw this out mentally or on paper:

```
[servers.conf parsed into array of entries]
        ↓
[Command validated — must be provided as $1]
        ↓
[For each server entry — launch background job &]
    → SSH with timeout to server
    → Capture stdout + stderr to temp file
    → Write exit code to separate temp file
    → Job runs in background
        ↓
[wait — block until all background jobs finish]
        ↓
[For each server — read temp files in order]
    → Exit code 0   → green SUCCESS block
    → Exit code 124 → yellow TIMEOUT block
    → Any other     → red FAILURE block
    → Print buffered output under the status header
        ↓
[Print summary: X succeeded, Y failed, Z timed out]
        ↓
[Cleanup temp files]
```

This flow tells you exactly what functions you need before writing a single line.

---

## Step 5: Plan Your Functions/Modules

From the data flow, extract your building blocks:

| Function | Responsibility |
|---|---|
| `load_servers` | Parse `servers.conf`, populate server list array |
| `validate_input` | Ensure a command was passed, conf file exists |
| `run_on_server` | SSH with timeout, capture output + exit code to temp files |
| `print_result` | Read temp files, colour-code and print one server's result block |
| `print_summary` | Tally and display final success/failure/timeout counts |
| `cleanup` | Remove all temp files on exit (trap EXIT) |
| `main` | Orchestrate: load → validate → fan-out → wait → report → summary |

Planning functions first means you can build and test each piece independently.

---

## Step 6: Think About Edge Cases

This is what separates a script that works in demos from one that works in production. Brainstorm failure scenarios:

- What if `servers.conf` doesn't exist? → Exit early with a clear error message
- What if `servers.conf` is empty or has only comments? → Warn and exit, nothing to do
- What if no command is passed? → Print usage and exit
- What if SSH key auth isn't set up for a server? → SSH exits non-zero, treat as failure, don't hang on password prompt (`-o BatchMode=yes`)
- What if two servers have the same hostname? → They'll still get separate temp files (use index-based naming)
- What if the command itself contains spaces or special characters? → Pass `$1` quoted, use `"$CMD"` throughout
- What if `/tmp` is full? → Temp file creation fails; check with a guard or use `mktemp`
- What if the script is killed mid-run? → `trap cleanup EXIT` ensures temp files are removed

---

## Step 7: Plan Your Configuration Strategy

Decide the `servers.conf` format before coding because the parser shape depends on it:

**Option A — Space-separated fields**
```
# hostname        ip              user
web-01            192.168.1.10    deploy
db-01             192.168.1.20    admin
```
Simple to parse with `read` or `awk`. Easy to edit. This is the right choice.

**Option B — INI sections per server**
```
[web-01]
ip=192.168.1.10
user=deploy
```
More structured but requires a real parser — overkill here.

**Option C — JSON/YAML**
Requires `jq` or `python` — adds a dependency for no real gain at this scale.

Go with Option A. Three space-separated columns, `#` for comments, blank lines ignored. The parser is a single `while read` loop.

For SSH options, hardcode the sensible defaults (`BatchMode=yes`, `StrictHostKeyChecking=no` for lab use, `ConnectTimeout`) rather than making them configurable — keep the scope tight.

---

## Step 8: Plan Your Output Format

Decide what a result block looks like before writing the print function. You want it to be:
- Instantly scannable (colour + label)
- Clear about which server produced which output
- Not interleaved with other servers' output

Think through what a block should contain:
```
┌─ [SUCCESS] web-01 (192.168.1.10) ──────────────────────
│ Filesystem      Size  Used Avail Use% Mounted on
│ /dev/sda1        20G   8G   11G  43% /
└─────────────────────────────────────────────────────────
```

And for failures:
```
┌─ [FAILED] db-02 (192.168.1.25) ────────────────────────
│ ssh: connect to host 192.168.1.25 port 22: Connection refused
└─────────────────────────────────────────────────────────
```

If you plan the format now, the colour-coding logic is just wrapping the header line in ANSI escape codes — trivial to implement.

---

## Step 9: Plan Your Testing Strategy

You can't test parallel SSH execution by just running it against live servers you don't control. Think about how to validate each piece:

- Test `load_servers` by printing parsed entries before any SSH runs — verify fields are correct
- Test with `localhost` first — SSH to your own machine with a simple `echo hello` to confirm the pipeline works end-to-end
- Test timeout handling by adding a fake server entry with an unreachable IP (e.g. `10.255.255.1`) and confirming it hits the timeout path, not the failure path
- Test output isolation by running a command that produces multi-line output (`df -h`) across multiple servers simultaneously — verify no interleaving
- Test the summary counter by deliberately mixing reachable and unreachable servers
- Test with a command that fails on the remote side (`ls /nonexistent`) — exit code should be non-zero but not `124`

---

## Step 10: Build Order (Incremental Approach)

Don't build everything at once. Here's the order that lets you validate as you go:

1. `servers.conf` format + parser → print parsed entries, verify fields are read correctly
2. Single-server SSH execution (no parallelism yet) → confirm output capture and exit code recording work
3. Add background jobs + `wait` → confirm all servers run in parallel, output still captured cleanly
4. Add timeout wrapper → test with an unreachable IP, confirm `124` exit code is produced
5. Output formatting + colour-coding → verify blocks are clean and not interleaved
6. Summary counter → verify tallies match what you see in the output blocks
7. `trap cleanup EXIT` → confirm temp files are removed even on Ctrl+C
8. README + `servers.conf.example` last — documentation is additive, not foundational

---

## Step 11: README Planning

Plan the README before you finish the script, not after. It forces you to think about the user experience:

- What's the one-line description?
- What are the prerequisites? (`ssh`, `timeout`, key-based auth configured)
- What does a sample `servers.conf` look like?
- What does sample output look like? (include a real colour-coded block and summary line)
- What is the exact invocation syntax? (`./dispatcher.sh 'df -h'`)
- What SSH options are baked in and why? (`BatchMode`, `ConnectTimeout`)
- What does the exit code of the dispatcher itself mean?

---

## The Mental Model Summary

Think of this project in three layers:

```
Layer 3 — Interface:    servers.conf, CLI argument ($1), colour output, README
Layer 2 — Logic:        Fan-out, timeout detection, exit code classification, summary tallying
Layer 1 — Data:         SSH output, exit codes, temp files, server list array
```

Always build from Layer 1 up. Never start at Layer 3. The most common mistake is writing the pretty colour output first and then discovering the output-interleaving problem only when you add the second server.

The script that passes a demo is built top-down. The script that works across 50 servers at 2am is built bottom-up.
