# Multi-Server SSH Command Dispatcher

![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25.svg?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux-FCC624.svg?logo=linux&logoColor=black)
![Status](https://img.shields.io/badge/Status-Stable-success.svg)


A Bash tool that reads a list of servers from `servers.conf` and runs any shell command across all of them simultaneously via SSH. Each server's output is captured in isolation and printed as a clean colour-coded block. A final summary line reports how many servers succeeded, failed, or timed out.

![Demo](demo.gif)

---

## How It Works

`dispatcher.sh` fans out a single command to every server in parallel using background jobs (`&`). Each SSH session writes its output and exit code to a temporary file. Once all jobs finish (`wait`), the script reads the temp files in order and prints a bordered, colour-coded result block per server — no interleaving, no waiting for one server before starting the next.

```
[servers.conf parsed → HOSTNAME / IP / USER arrays]
              ↓
[Command validated — must be provided as $1]
              ↓
[For each server — launch background SSH job &]
    → timeout wraps the SSH call
    → stdout + stderr → temp output file
    → exit code       → temp rc file
    → job runs in background, loop continues immediately
              ↓
[wait — block until ALL background jobs finish]
              ↓
[For each server — read temp files in order]
    → exit code 0   → GREEN  [SUCCESS] block
    → exit code 124 → YELLOW [TIMEOUT] block
    → any other     → RED    [FAILED]  block
    → print buffered output lines under the header
              ↓
[Summary: X succeeded, Y failed, Z timed out]
              ↓
[Cleanup temp files — runs automatically on exit]
```

---

## Requirements

- Bash 4+
- `ssh` — OpenSSH client (standard on all Linux systems)
- `timeout` — GNU coreutils (standard on all Linux systems)
- `mktemp` — GNU coreutils (standard on all Linux systems)
- SSH key-based authentication configured for every server in `servers.conf`

No external dependencies. No Python, no `jq`, no third-party tools.

---

## Files

| File                  | Description                                              |
|-----------------------|----------------------------------------------------------|
| `dispatcher.sh`       | Main script                                              |
| `servers.conf`        | Live server list (hostname, IP, SSH user)                |
| `servers.conf.example`| Blank template — copy to `servers.conf` and fill in      |
| `PLANNING.md`         | Full thought process and design decisions                |
| `README.md`           | This file                                                |

---

## Quick Start

```bash
# 1. Navigate to the project directory
cd Multi-Server-SSH-Command-Dispatcher

# 2. Make the script executable
chmod +x dispatcher.sh

# 3. Copy the example config and fill in your real server details
#    Never edit servers.conf.example directly — keep it as a clean template
cp servers.conf.example servers.conf
nano servers.conf

# 4. Run a command across all servers
./dispatcher.sh 'df -h'
```

---

## Usage

```
./dispatcher.sh '<command>' [OPTIONS]
```

The command to run remotely is always the **first argument**, quoted as a single string.

### Options

| Flag               | Description                              | Default        |
|--------------------|------------------------------------------|----------------|
| `--config <file>`  | Path to the server list file             | `servers.conf` |
| `--timeout <secs>` | Per-server timeout in seconds            | `10`           |
| `--port <port>`    | SSH port for all servers                 | `22`           |
| `--help`           | Show usage information and exit          | —              |

### Examples

```bash
# Check disk usage on all servers
./dispatcher.sh 'df -h'

# Check memory on all servers
./dispatcher.sh 'free -m'

# Check uptime
./dispatcher.sh 'uptime'

# Check a service status
./dispatcher.sh 'systemctl status nginx'

# Run as a specific user with a longer timeout
./dispatcher.sh 'tail -5 /var/log/syslog' --timeout 20

# Use a different server list
./dispatcher.sh 'whoami' --config /etc/dispatcher/prod-servers.conf

# Connect on a non-standard SSH port
./dispatcher.sh 'hostname' --port 2222

# Combine flags
./dispatcher.sh 'uptime' --config staging.conf --timeout 15 --port 2222
```

---

## servers.conf Format

Three whitespace-separated columns per line. Lines starting with `#` and blank lines are ignored.

```
# hostname        ip               user
web-01            192.168.1.10     deploy
web-02            192.168.1.11     deploy
db-01             192.168.1.20     admin
db-02             192.168.1.21     admin
cache-01          192.168.1.30     deploy
monitor-01        192.168.1.40     ops
```

- **hostname** — display label only; does not need to be DNS-resolvable
- **ip** — the address SSH connects to (IPv4, IPv6, or a resolvable hostname)
- **user** — the remote login user; must have your public key in `~/.ssh/authorized_keys`

---

## SSH Key Setup

The dispatcher uses `BatchMode=yes` which means it will **never prompt for a password**. Key-based authentication must be set up for every server before running the script.

```bash
# Step 1 — Generate a key pair (skip if you already have one)
ssh-keygen -t ed25519 -C "dispatcher"

# Step 2 — Copy your public key to each server
ssh-copy-id -i ~/.ssh/id_ed25519.pub deploy@192.168.1.10
ssh-copy-id -i ~/.ssh/id_ed25519.pub deploy@192.168.1.11
ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@192.168.1.20

# Step 3 — Test each connection manually before adding to servers.conf
ssh -o BatchMode=yes deploy@192.168.1.10 'echo ok'
# Expected output: ok
# If you see a password prompt, key auth is not set up correctly.
```

---

## Sample Output

```
[INFO]  Loaded 4 server(s) from 'servers.conf'
[INFO]  Dispatching 'df -h' to 4 server(s) with 10s timeout...

┌─ [SUCCESS] web-01 (192.168.1.10) ────────────────────────────────────────
│ Filesystem      Size  Used Avail Use% Mounted on
│ /dev/sda1        40G   12G   26G  32% /
│ tmpfs           2.0G     0  2.0G   0% /dev/shm
└───────────────────────────────────────────────────────────────────────────

┌─ [SUCCESS] web-02 (192.168.1.11) ────────────────────────────────────────
│ Filesystem      Size  Used Avail Use% Mounted on
│ /dev/sda1        40G   15G   23G  40% /
└───────────────────────────────────────────────────────────────────────────

┌─ [FAILED ] db-01 (192.168.1.20) ─────────────────────────────────────────
│ ssh: connect to host 192.168.1.20 port 22: Connection refused
└───────────────────────────────────────────────────────────────────────────

┌─ [TIMEOUT] cache-01 (192.168.1.30) ──────────────────────────────────────
│ (no output)
└───────────────────────────────────────────────────────────────────────────

════════════════════════════════════════════════════════
  SUMMARY — 4 server(s) contacted
════════════════════════════════════════════════════════
  ✔  Succeeded : 2
  ✘  Failed    : 1
  ⏱  Timed out : 1
════════════════════════════════════════════════════════
```

Colours in a real terminal:
- `[SUCCESS]` header — **green**
- `[FAILED ]` header — **red**
- `[TIMEOUT]` header — **yellow**

---

## Exit Codes

| Code | Meaning                                          |
|------|--------------------------------------------------|
| `0`  | Every server returned exit code 0 (all succeeded)|
| `1`  | At least one server failed or timed out          |
| `2`  | Bad usage — missing command, missing config file, invalid option |

The exit code makes the dispatcher composable in shell pipelines and CI scripts:

```bash
./dispatcher.sh 'systemctl is-active nginx' && echo "nginx is up everywhere"
```

---

## Timeout Behaviour

Each server gets its own independent timeout. A slow or unresponsive server does not delay the others — all jobs run in parallel.

- The `timeout` command wraps the entire SSH session. If the session (connection + command execution) takes longer than `--timeout` seconds, the job is killed and the exit code is set to `124`.
- `ConnectTimeout` (hardcoded to 5 seconds) covers only the TCP handshake. This catches unreachable hosts quickly without waiting for the full `--timeout` to expire.
- A server that is reachable but whose command runs slowly will hit the outer `--timeout`, not `ConnectTimeout`.

```bash
# Increase timeout for commands that take longer to run
./dispatcher.sh 'find / -name "*.log" -mtime +30' --timeout 60
```

---

## Hardcoded SSH Options

These SSH options are baked into the script. They are appropriate for internal/lab networks:

| Option                    | Value  | Reason                                                    |
|---------------------------|--------|-----------------------------------------------------------|
| `BatchMode`               | `yes`  | Never prompt for a password — fail immediately instead    |
| `ConnectTimeout`          | `5`    | Abort the TCP handshake after 5 seconds                   |
| `StrictHostKeyChecking`   | `no`   | Skip the "add to known_hosts?" prompt for new servers     |
| `LogLevel`                | `ERROR`| Suppress SSH banners so only command output is captured   |

> **Production note:** Change `StrictHostKeyChecking` to `yes` and pre-populate `~/.ssh/known_hosts` for hardened environments where host verification matters.

---

## Troubleshooting

**"Config file not found"**
```
[ERROR] Config file not found: 'servers.conf'
```
You are not in the project directory, or the file doesn't exist yet. Either `cd` to the right directory or pass `--config /path/to/servers.conf`.

---

**All servers show [FAILED] with "Permission denied"**
```
│ deploy@192.168.1.10: Permission denied (publickey)
```
SSH key auth is not set up. Run `ssh-copy-id` for each server (see SSH Key Setup above).

---

**All servers show [TIMEOUT]**
The servers are unreachable from your machine. Check:
1. Are the IPs in `servers.conf` correct?
2. Is the SSH port correct? (try `--port 2222` if servers use a non-standard port)
3. Is there a firewall blocking port 22?
4. Can you `ping` the servers?

---

**"(no output)" in a SUCCESS block**
The remote command ran successfully but produced no stdout. This is normal for commands like `touch`, `mkdir`, or `systemctl restart`.

---

**Command with special characters not working**
Always quote the command as a single string:
```bash
# Wrong — shell interprets the pipe before passing to dispatcher
./dispatcher.sh df -h | grep sda

# Correct — the entire string is passed to the remote shell
./dispatcher.sh 'df -h | grep sda'
```

---

## Notes

- Servers are always printed in the same order they appear in `servers.conf`, regardless of which server finished first.
- Two servers with the same hostname are handled correctly — temp files are named by index, not hostname.
- Temp files are created under `/tmp` using `mktemp -d` and are removed automatically when the script exits, even on Ctrl+C.
- The script does not modify any files on the remote servers — it only reads output.
- There is no limit on the number of servers. For very large fleets (hundreds of servers), consider batching with `split` or using a dedicated tool like Ansible.



## What I Learned

Building this dispatcher pushed me into the practical realities of remote execution and concurrent process management:

- **SSH non-interactive options matter more than the command itself.** `-o BatchMode=yes`, `-o ConnectTimeout=5`, and `-o StrictHostKeyChecking=accept-new` are the difference between a script that hangs forever on an unreachable host and one that fails fast and moves on. The first version of this tool froze the entire run when one host was down — fixing it taught me to design for failure first.

- **Parallel execution in Bash is trickier than it looks.** Running commands with `&` is the easy part. Capturing each background job's stdout, stderr, exit code, and tagging it back to the right host requires careful use of temp files or named pipes — I went with per-host log files for simplicity and traceability.

- **Exit codes are the API of shell scripts.** Aggregating exit codes across N hosts and producing a single meaningful summary (all-pass / partial-pass / all-fail) taught me to treat the script's own exit code as a contract for any caller — including CI pipelines that might use this tool.

- **Colour-coded output is part of the UX.** A wall of plain-text output from 20 hosts is unreadable. Adding green/red status markers and per-host section separators made the same data instantly scannable — small change, huge impact on usability.

- **Inventory files should be plain and forgiving.** I support comments, blank lines, and optional custom ports per host. The parser took longer to write than the SSH execution itself — that's normal for any "small" config format.

- **Connection timeouts protect the whole run.** Without a per-host timeout, a single slow or hung server blocks every other server's result. Setting an aggressive timeout (5s default) and surfacing it as a CLI flag made the tool usable on flaky networks.


## Production Hardening Checklist

This project is a focused utility for ad-hoc operations. For production fleet management, the following would need to be added:

- [ ] SSH key management via an agent or vault rather than relying on `~/.ssh/config`
- [ ] Concurrency limiter (max N parallel SSH sessions) to avoid overwhelming the local machine on large fleets
- [ ] Structured output mode (JSON) for piping into other tools or dashboards
- [ ] Retry-with-backoff for transient connection failures
- [ ] Audit log of every command dispatched, by whom, to which hosts, with exit codes
- [ ] Dry-run mode showing exactly which hosts would receive which commands
- [ ] Integration with proper inventory systems (Ansible inventory format, AWS tags, Consul)
- [ ] Sudo password handling via a secrets manager rather than interactive prompts
- [ ] At larger scale, this whole pattern is replaced by Ansible — which is the right answer for fleet ops