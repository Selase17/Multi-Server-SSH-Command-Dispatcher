#!/usr/bin/env bash
# =============================================================================
# dispatcher.sh — Multi-Server SSH Command Dispatcher
# =============================================================================
# Reads a list of servers from servers.conf and runs a given shell command
# on ALL of them simultaneously via SSH. Each server's output is captured
# in isolation, then printed as a clean colour-coded block once all jobs
# finish. A final summary line reports how many servers succeeded, failed,
# or timed out.
#
# Usage:
#   ./dispatcher.sh '<command>'
#   ./dispatcher.sh '<command>' [--config <file>] [--timeout <seconds>] [--port <port>]
#
# Examples:
#   ./dispatcher.sh 'df -h'
#   ./dispatcher.sh 'uptime'
#   ./dispatcher.sh 'systemctl status nginx'
#   ./dispatcher.sh 'free -m' --timeout 15
#   ./dispatcher.sh 'whoami'  --config /etc/dispatcher/servers.conf
#
# servers.conf format (space-separated, # = comment, blank lines ignored):
#   # hostname      ip               user
#   web-01          192.168.1.10     deploy
#   db-01           192.168.1.20     admin
#
# Exit codes:
#   0  — all servers succeeded
#   1  — one or more servers failed or timed out
#   2  — bad usage (missing command, missing config, empty server list)
#
# Requirements: bash 4+, ssh, timeout, mktemp (all standard on Linux)
# SSH prerequisite: key-based auth must be configured for every listed server
# =============================================================================

# -----------------------------------------------------------------------------
# Strict mode — fail fast on any unhandled error, unset variable, or bad pipe.
# This is the first line of defence against silent failures in a script that
# fans out to multiple remote hosts.
# -----------------------------------------------------------------------------
set -euo pipefail # -e: exit on any command failure; -u: error on unset variables; -o pipefail: catch failures in pipelines

# =============================================================================
# PLAN STEP 1 — CONSTANTS & DEFAULTS
# (PLANNING.md Step 7: Option A config format decided; SSH options hardcoded
#  to keep scope tight. Defaults set here; CLI flags override below.)
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"   # Used in usage/error messages
readonly SCRIPT_VERSION="1.0.0"           # Shown in --help output

# Default path to the server list — overridable with --config
CONF_FILE="servers.conf"

# Seconds to wait for a single server before declaring it timed out.
# PLANNING.md Step 3: timeout exit code 124 is the key distinguisher.
# ConnectTimeout covers the TCP handshake; SSH_TIMEOUT wraps the whole job.
SSH_TIMEOUT=10

# SSH port — overridable with --port for non-standard setups
SSH_PORT=22

# ConnectTimeout passed directly to ssh -o ConnectTimeout.
# Kept shorter than SSH_TIMEOUT so a hung handshake is caught before the
# outer timeout fires — gives us a cleaner error message.
readonly CONNECT_TIMEOUT=5

# Temp directory for this run — all per-server output and exit-code files
# live here. Created in main(), removed by cleanup() via trap EXIT.
# PLANNING.md Step 3: temp files are the chosen isolation strategy because
# they survive subshell crashes and allow ordered printing after wait.
TMPDIR_RUN=""

# =============================================================================
# PLAN STEP 2 — COLOUR CODES & OUTPUT HELPERS
# (PLANNING.md Step 8: output format planned before any logic is written)
#
# Colours are defined as variables so every print function references the
# same values — change one line here to restyle the entire output.
# =============================================================================

readonly RED=$'\033[0;31m'       # Failures
readonly GREEN=$'\033[0;32m'     # Successes
readonly YELLOW=$'\033[1;33m'    # Timeouts / warnings
readonly CYAN=$'\033[0;36m'      # Info messages
readonly BOLD=$'\033[1m'         # Headers and summary line
readonly RESET=$'\033[0m'        # Always reset after colouring

# Print an informational message to stdout (cyan, not a server result)
log_info() {
    echo -e "${CYAN}[INFO]${RESET}  $*"
}

# Print a warning to stdout (yellow)
log_warn() {
    echo -e "${YELLOW}[WARN]${RESET}  $*"
}

# Print an error to stderr (red) — used for fatal pre-flight failures
log_error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

# =============================================================================
# PLAN STEP 3 — USAGE / HELP
# (PLANNING.md Step 11: README planning — usage text mirrors the README so
#  the user gets the same information whether they read the file or run --help)
# =============================================================================

usage() {
    echo -e "
${BOLD}${SCRIPT_NAME}${RESET} v${SCRIPT_VERSION} — Multi-Server SSH Command Dispatcher

${BOLD}USAGE:${RESET}
  ./${SCRIPT_NAME} '<command>' [OPTIONS]

${BOLD}OPTIONS:${RESET}
  --config  <file>     Path to server list file       (default: servers.conf)
  --timeout <seconds>  Per-server timeout in seconds  (default: 10)
  --port    <port>     SSH port for all servers        (default: 22)
  --help               Show this help message and exit
  --version            Show version number and exit

${BOLD}EXAMPLES:${RESET}
  ./${SCRIPT_NAME} 'df -h'
  ./${SCRIPT_NAME} 'uptime' --timeout 15
  ./${SCRIPT_NAME} 'systemctl status nginx' --config /etc/dispatcher/servers.conf
  ./${SCRIPT_NAME} 'free -m' --port 2222

${BOLD}SERVERS.CONF FORMAT:${RESET}
  # hostname      ip               user
  web-01          192.168.1.10     deploy
  db-01           192.168.1.20     admin

  Lines starting with # and blank lines are ignored.
  Fields are whitespace-separated: HOSTNAME  IP  USER

${BOLD}PREREQUISITES:${RESET}
  - SSH key-based authentication must be set up for every listed server.
  - 'timeout' and 'ssh' must be available (standard on all Linux systems).
"
}

# =============================================================================
# PLAN STEP 4 — CLEANUP (trap EXIT)
# (PLANNING.md Step 6 edge case: script killed mid-run must not leave temp
#  files behind. trap EXIT fires on normal exit, Ctrl+C, and SIGTERM.)
# =============================================================================

cleanup() {
    # Only attempt removal if the temp directory was actually created
    if [[ -n "$TMPDIR_RUN" && -d "$TMPDIR_RUN" ]]; then
        rm -rf "$TMPDIR_RUN"   # Remove all per-server output and exit-code files
    fi
}

# Register cleanup to run automatically whenever the script exits for any reason
trap cleanup EXIT

# =============================================================================
# PLAN STEP 5 — PARSE CLI ARGUMENTS
# (PLANNING.md Step 7: CLI flags override defaults set in PLAN STEP 1.
#  The command to run is the first positional argument — everything else
#  is a named flag. We validate that a command was actually provided here.)
# =============================================================================

parse_args() {
    # Edge case: no arguments at all — print usage and exit with code 2
    if [[ $# -eq 0 ]]; then
        usage
        exit 2
    fi

    # The very first argument is always the remote command to execute.
    # It may contain spaces (e.g. 'df -h'), so we capture it as a single
    # quoted string and never word-split it again after this point.
    CMD="$1"
    shift   # Consume the command; remaining args are flags

    # Edge case: user passed --help as the first argument instead of a command
    if [[ "$CMD" == "--help" || "$CMD" == "-h" ]]; then
        usage
        exit 0
    fi

    # Parse remaining optional flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                # Custom path to servers.conf
                CONF_FILE="$2"
                shift 2
                ;;
            --timeout)
                #|Guard: ensure a value was actually provided after the flag
                if [[ -z "${2:-}" ]]; then
                    log_error "--timeout flag requires a value. Example: --timeout 15"
                    exit 2
                fi 

                # Per-server timeout in seconds — must be a positive integer
                SSH_TIMEOUT="$2"
                shift 2
                ;;
            --port)
                #|Guard: ensure a value was actually provided after the flag

                if [[ -z "${2:-}" ]]; then
                    log_error "--port flag requires a value. Example: --port 2222"
                    exit 2
                fi

                # SSH port — useful when servers run sshd on a non-standard port
                SSH_PORT="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --version)
                echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
                exit 0
                ;;
            *)
                # Unknown flag — fail loudly rather than silently ignoring it
                log_error "Unknown option: '$1'. Run ./${SCRIPT_NAME} --help for usage."
                exit 2
                ;;
        esac
    done
}

# =============================================================================
# PLAN STEP 6 — VALIDATE INPUT
# (PLANNING.md Step 6 edge cases: missing conf file, empty server list,
#  missing command, non-numeric timeout. All checked before any SSH fires.)
# =============================================================================

validate_input() {
    # Guard: the command string must not be empty or just whitespace
    if [[ -z "${CMD// /}" ]]; then
        log_error "No command provided. Usage: ./${SCRIPT_NAME} '<command>'"
        exit 2
    fi

    # Guard: servers.conf must exist and be a regular file
    if [[ ! -f "$CONF_FILE" ]]; then
        log_error "Config file not found: '$CONF_FILE'"
        log_error "Create it or pass a different path with --config."
        exit 2
    fi

    # Guard: timeout must be a positive integer — non-numeric values would
    # silently pass to the timeout command and produce confusing errors
    if ! [[ "$SSH_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$SSH_TIMEOUT" -lt 1 ]]; then
        log_error "--timeout must be a positive integer. Got: '$SSH_TIMEOUT'"
        exit 2
    fi

    # Guard: SSH port must be a valid port number (1–65535)
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]]; then
        log_error "--port must be between 1 and 65535. Got: '$SSH_PORT'"
        exit 2
    fi
}

# =============================================================================
# PLAN STEP 7 — LOAD SERVERS
# (PLANNING.md Step 7, Option A: space-separated three-column format.
#  Parser is a single while-read loop — skips comments and blank lines.
#  Populates three parallel indexed arrays: HOSTNAMES, IPS, USERS.)
#
# Why parallel arrays instead of one associative array?
# Bash associative arrays don't preserve insertion order, which matters
# when we want to print results in the same order as servers.conf.
# =============================================================================

# Parallel arrays — index N in each array describes the same server
declare -a HOSTNAMES=()   # Human-readable hostname (e.g. web-01)
declare -a IPS=()         # IP address used for the actual SSH connection
declare -a USERS=()       # SSH login user for that server

load_servers() {
    local line_num=0   # Track line number for useful error messages

    while IFS= read -r line; do
        (( line_num++ )) || true   # Increment even if line is blank

        # Skip blank lines — IFS= read preserves them, so check explicitly
        [[ -z "$line" ]] && continue

        # Skip comment lines — any line whose first non-space character is #
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split the line into fields on whitespace.
        # read -r with IFS=' ' splits on any run of spaces/tabs.
        # shellcheck disable=SC2162
        read -r hostname ip user extra <<< "$line"

        # Guard: all three fields must be present
        if [[ -z "$hostname" || -z "$ip" || -z "$user" ]]; then
            log_warn "Line $line_num in '$CONF_FILE' is malformed (need: HOSTNAME IP USER) — skipping: '$line'"
            continue
        fi

        # Guard: warn if extra fields are present — they are ignored but
        # likely indicate a typo or wrong format
        if [[ -n "$extra" ]]; then
            log_warn "Line $line_num has extra fields after USER — ignoring them: '$extra'"
        fi

        # Append to parallel arrays — all three arrays stay in sync
        HOSTNAMES+=("$hostname")
        IPS+=("$ip")
        USERS+=("$user")

    done < "$CONF_FILE"

    # Edge case: conf file existed but contained no valid server entries
    if [[ "${#HOSTNAMES[@]}" -eq 0 ]]; then
        log_error "'$CONF_FILE' contains no valid server entries. Nothing to do."
        exit 2
    fi

    log_info "Loaded ${#HOSTNAMES[@]} server(s) from '$CONF_FILE'"
}

# =============================================================================
# PLAN STEP 8 — RUN ON SERVER (background worker)
# (PLANNING.md Step 3: the hard part — output isolation via temp files.
#  This function is launched as a background job (&) for every server.
#  It writes stdout+stderr to an output temp file and the exit code to a
#  separate exit-code temp file. The parent process reads both after wait.)
#
# Args: $1=index  $2=hostname  $3=ip  $4=user
#
# Temp file naming uses the server index (not hostname) so duplicate
# hostnames never collide — PLANNING.md Step 6 edge case.
# =============================================================================

run_on_server() {
    set +e   # Disable exit-on-error for this function — SSH failures are expected and handled explicitly via exit code capture below
    local idx="$1"        # Numeric index — used to name temp files
    local hostname="$2"   # For display only
    local ip="$3"         # Actual SSH target
    local user="$4"       # SSH login user

    # Paths to this server's temp files — parent reads these after wait
    local out_file="${TMPDIR_RUN}/out_${idx}"    # stdout + stderr from SSH
    local rc_file="${TMPDIR_RUN}/rc_${idx}"      # Exit code (single integer)

    # Run SSH wrapped in `timeout` so we never block forever.
    # PLANNING.md Step 3: timeout exits with code 124 — we check for that
    # specifically in print_result to distinguish timeout from real failure.
    #
    # SSH flags explained:
    #   -o BatchMode=yes          — never prompt for a password; fail instead
    #                               (PLANNING.md Step 6: prevents hanging on
    #                                servers without key auth configured)
    #   -o ConnectTimeout=N       — abort the TCP handshake after N seconds
    #                               (catches unreachable hosts quickly)
    #   -o StrictHostKeyChecking=no — skip host key verification prompt
    #                               (acceptable in a lab/internal network;
    #                                remove this for production hardening)
    #   -o LogLevel=ERROR         — suppress SSH's own banner/info messages
    #                               so only the remote command's output lands
    #                               in the output file
    #   -p $SSH_PORT              — support non-standard SSH ports
    #   2>&1                      — merge stderr into stdout so connection
    #                               errors appear in the output block, not
    #                               scattered to the terminal
    timeout "$SSH_TIMEOUT" ssh \
        -o BatchMode=yes \
        -o ConnectTimeout="${CONNECT_TIMEOUT}" \
        -o StrictHostKeyChecking=no \
        -o LogLevel=ERROR \
        -p "$SSH_PORT" \
        "${user}@${ip}" \
        "$CMD" \
        > "$out_file" 2>&1 
    local exit_code=$?   # Capture immediately — next command would overwrite $?

    # Write the exit code to its own file so the parent can read it cleanly.
    # A plain echo is sufficient — the file will contain a single integer.
    echo "$exit_code" > "$rc_file"
    # Return true so set -e doesn't kill the background job on SSH failure
    return 0  # The actual success/failure is determined by the exit code we wrote to the file
}

# =============================================================================
# PLAN STEP 9 — PRINT RESULT
# (PLANNING.md Step 8: output block format designed before coding.
#  Reads the two temp files written by run_on_server and prints a
#  colour-coded bordered block for one server.
#
# Exit code classification (PLANNING.md Step 3, second hard part):
#   0   → SUCCESS  (green)
#   124 → TIMEOUT  (yellow) — this is timeout(1)'s specific exit code
#   *   → FAILED   (red)    — any other non-zero SSH or remote exit code
#
# Args: $1=index  $2=hostname  $3=ip)
# =============================================================================

print_result() {
    local idx="$1"
    local hostname="$2"
    local ip="$3"

    local out_file="${TMPDIR_RUN}/out_${idx}"
    local rc_file="${TMPDIR_RUN}/rc_${idx}"

    # Read the exit code written by the background job.
    # Default to 1 (failure) if the file is missing — should never happen
    # unless the subshell was killed before it could write the file.
    local exit_code=1
    [[ -f "$rc_file" ]] && exit_code=$(< "$rc_file")

    # Determine label and colour based on exit code
    local label colour
    if [[ "$exit_code" -eq 0 ]]; then
        label="SUCCESS"
        colour="$GREEN"
    elif [[ "$exit_code" -eq 124 ]]; then
        label="TIMEOUT"
        colour="$YELLOW"
    else
        label="FAILED "    # Trailing space keeps label width uniform
        colour="$RED"
    fi

    # -------------------------------------------------------------------------
    # Print the bordered output block.
    # PLANNING.md Step 8 planned this exact format:
    #   ┌─ [LABEL] hostname (ip) ──────────────────
    #   │ <output line>
    #   │ <output line>
    #   └──────────────────────────────────────────
    #
    # The header is colour-coded; the output lines are plain so terminal
    # colour codes inside remote command output don't interfere.
    # -------------------------------------------------------------------------

    # Top border — colour-coded label + server identity
    # Calculate how many dashes to print based on what's already on the line
    local header_text="┌─ [${label}] ${hostname} (${ip}) "
    local header_len=${#header_text}
    local dash_count=$(( 75 - header_len ))
    [[ "$dash_count" -lt 5 ]] && dash_count=5   # Minimum 5 dashes

    echo -e "${colour}${BOLD}${header_text}$(printf '─%.0s' $(seq 1 $dash_count))${RESET}"
    
    # Output lines — prefix each with the border character for visual alignment
    if [[ -f "$out_file" && -s "$out_file" ]]; then
        # -s checks the file is non-empty — avoids printing a blank │ line
        while IFS= read -r output_line; do
            echo -e "${colour}│${RESET} ${output_line}"
        done < "$out_file"
    else
        # No output at all — print a placeholder so the block isn't empty
        echo -e "${colour}│${RESET} ${YELLOW}(no output)${RESET}"
    fi

    # Bottom border — plain line to close the block
    echo -e "${colour}${BOLD}└$(printf '─%.0s' {1..55})${RESET}"
    echo ""   # Blank line between server blocks for readability
}

# =============================================================================
# PLAN STEP 10 — PRINT SUMMARY
# (PLANNING.md Step 5: print_summary — tally and display final counts.
#  Called after all result blocks have been printed.
#
# Args: $1=succeeded  $2=failed  $3=timedout  $4=total)
# =============================================================================

print_summary() {
    local succeeded="$1"
    local failed="$2"
    local timedout="$3"
    local total="$4"

    echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  SUMMARY — ${total} server(s) contacted${RESET}"
    echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"

    # Each counter is colour-coded to match the result blocks above it
    echo -e "  ${GREEN}${BOLD}✔  Succeeded : ${succeeded}${RESET}"
    echo -e "  ${RED}${BOLD}✘  Failed    : ${failed}${RESET}"
    echo -e "  ${YELLOW}${BOLD}⏱  Timed out : ${timedout}${RESET}"

    echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
    echo ""
}

# =============================================================================
# PLAN STEP 11 — MAIN
# (PLANNING.md Step 4: the full data flow implemented here in order.
#  PLANNING.md Step 10: build order — Layer 1 (data) before Layer 3 (output).
#
# Flow:
#   1. Parse CLI args
#   2. Validate all inputs
#   3. Load server list into arrays
#   4. Create temp directory for this run
#   5. Fan-out: launch one background SSH job per server
#   6. wait — block until every background job has finished
#   7. Print each server's result block in order
#   8. Print summary
#   9. Exit with 0 if all succeeded, 1 if any failed or timed out
# =============================================================================

main() {
    # -------------------------------------------------------------------------
    # PLAN STEP 1 (execution): Parse CLI arguments.
    # CMD, CONF_FILE, SSH_TIMEOUT, SSH_PORT are set here.
    # -------------------------------------------------------------------------
    parse_args "$@"

    # -------------------------------------------------------------------------
    # PLAN STEP 2 (execution): Validate all inputs before touching the network.
    # Fail fast with a clear message rather than discovering problems mid-run.
    # -------------------------------------------------------------------------
    validate_input

    # -------------------------------------------------------------------------
    # PLAN STEP 3 (execution): Load the server list from servers.conf.
    # HOSTNAMES, IPS, USERS arrays are populated here.
    # -------------------------------------------------------------------------
    load_servers

    # -------------------------------------------------------------------------
    # PLAN STEP 4 (execution): Create the temp directory for this run.
    # mktemp -d creates a unique directory under /tmp — safer than a fixed path
    # because multiple dispatcher runs can coexist without colliding.
    # PLANNING.md Step 6: guard against /tmp being full.
    # -------------------------------------------------------------------------
    TMPDIR_RUN="$(mktemp -d 2>/dev/null)" || {
        log_error "Failed to create temp directory in /tmp. Is the filesystem full?"
        exit 1
    }

    # -------------------------------------------------------------------------
    # PLAN STEP 5 (execution): Fan-out — launch one background job per server.
    # PLANNING.md Step 3: parallel execution via & is the core of this tool.
    # Each job runs run_on_server in a subshell; the parent continues the loop
    # immediately without waiting, so all servers are contacted simultaneously.
    # -------------------------------------------------------------------------
    local total="${#HOSTNAMES[@]}"

    log_info "Dispatching '${CMD}' to ${total} server(s) with ${SSH_TIMEOUT}s timeout..."
    echo ""   # Visual separation before the result blocks

    for (( i=0; i<total; i++ )); do
        # Launch the SSH job in the background.
        # run_on_server writes output and exit code to temp files — it does NOT
        # print anything to stdout, so there is zero risk of interleaving here.
        run_on_server "$i" "${HOSTNAMES[$i]}" "${IPS[$i]}" "${USERS[$i]}" &
        # The & sends the subshell to the background; the loop continues
        # immediately to launch the next server's job.
    done

    # -------------------------------------------------------------------------
    # PLAN STEP 6 (execution): Wait for ALL background jobs to finish.
    # `wait` blocks until every child process spawned by this shell has exited.
    # After this line, every temp file is guaranteed to be fully written.
    # -------------------------------------------------------------------------
    wait

    # -------------------------------------------------------------------------
    # PLAN STEP 7 (execution): Print results in the original servers.conf order.
    # PLANNING.md Step 3: temp files allow ordered printing after wait — this
    # is why we chose temp files over capturing output inside the subshell.
    # Tally counters are incremented here as we read each exit code.
    # -------------------------------------------------------------------------
    local succeeded=0
    local failed=0
    local timedout=0

    for (( i=0; i<total; i++ )); do
        # Read the exit code written by this server's background job
        local rc_file="${TMPDIR_RUN}/rc_${i}"
        local exit_code=1
        [[ -f "$rc_file" ]] && exit_code=$(< "$rc_file")

        # Increment the appropriate counter before printing the block
        if [[ "$exit_code" -eq 0 ]]; then
            (( succeeded++ )) || true   # || true prevents set -e from firing on 0
        elif [[ "$exit_code" -eq 124 ]]; then
            (( timedout++ )) || true
        else
            (( failed++ )) || true
        fi

        # Print the colour-coded output block for this server
        print_result "$i" "${HOSTNAMES[$i]}" "${IPS[$i]}"
    done

    # -------------------------------------------------------------------------
    # PLAN STEP 8 (execution): Print the final summary.
    # PLANNING.md Step 5: print_summary — X succeeded, Y failed, Z timed out.
    # -------------------------------------------------------------------------
    print_summary "$succeeded" "$failed" "$timedout" "$total"

    # -------------------------------------------------------------------------
    # PLAN STEP 9 (execution): Exit code for the dispatcher itself.
    # PLANNING.md Step 11: README planning — document what the exit code means.
    #   0 = every server returned exit code 0
    #   1 = at least one server failed or timed out
    # This allows the dispatcher to be used in CI pipelines or chained scripts.
    # -------------------------------------------------------------------------
    if [[ "$failed" -gt 0 || "$timedout" -gt 0 ]]; then
        exit 1   # At least one server did not succeed
    fi

    exit 0   # All servers succeeded
}

# -----------------------------------------------------------------------------
# Entrypoint — pass all CLI arguments to main unchanged.
# Keeping this separate from main() means the script can be sourced for
# testing individual functions without triggering execution.
# -----------------------------------------------------------------------------
main "$@"
