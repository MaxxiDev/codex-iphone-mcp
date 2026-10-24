#!/bin/zsh
# Read-only evidence collection; never resets Bluetooth or changes pairing data.
set -uo pipefail
SCRIPT_DIR="${0:A:h}"

usage() {
    cat <<'EOF'
Usage: scripts/diagnose-bluetooth.sh [minutes]

Collect Bluetooth connection evidence on stdout. Redirect it to save a report:
  scripts/diagnose-bluetooth.sh 10 > bluetooth-report.txt

minutes: recent system log window, 1..60 (default: 10)
IPHONE_USE_PORT: local HTTP port, 1..65535 (default: 7390)

Run immediately after a failure, preferably before restarting iphone-use.
A partial report exits with status 1; invalid arguments exit with status 2.
EOF
}

if (( $# == 1 )) && [[ "$1" == --help || "$1" == -h ]]; then
    usage
    exit 0
fi

minutes="${1-10}"
port="${IPHONE_USE_PORT-7390}"
if (( $# > 1 )) || [[ ! "$minutes" =~ '^[1-9][0-9]?$' ]] || (( minutes > 60 )); then
    print -u2 -- 'Error: minutes must be an integer from 1 to 60.'
    exit 2
fi
if [[ ! "$port" =~ '^[1-9][0-9]{0,4}$' ]] || (( port > 65535 )); then
    print -u2 -- 'Error: IPHONE_USE_PORT must be an integer from 1 to 65535.'
    exit 2
fi

report_exit=0
collect() {
    local label="$1"
    shift
    printf '\n=== %s ===\n' "$label"
    if "$@" 2>&1; then
        printf '\n'
    else
        local command_exit=$?
        printf '\n[Collection gap] %s failed (exit %s); continuing.\n' "$label" "$command_exit"
        report_exit=1
    fi
}

process_snapshot() {
    # comm contains the executable path, not shell arguments that may mention iphone-use.
    /bin/ps -axo pid=,lstart=,comm= | /usr/bin/awk '
        /(^|[[:space:]\/])iphone-use$/ { print; found = 1 }
        END { if (!found) print "No running iphone-use process found." }
    '
}

print -- 'iPhone Use Bluetooth diagnostic report'
print -- 'Read-only collection; no services, connections or pairing data are changed.'
print -- 'System logs cover all Mac Bluetooth devices. Correlate time, host UUID and address.'
print -- 'An empty log section does not prove that no failure occurred; this report infers no root cause.'
collect 'Collection time' /bin/date '+%Y-%m-%d %H:%M:%S %Z (%z)'
collect 'macOS version' /usr/bin/sw_vers
collect 'iphone-use processes: PID, start time, executable' process_snapshot
collect "Local API status (port $port)" python3 "$SCRIPT_DIR/local_api.py" "http://127.0.0.1:$port/status"

# Limit logs to low-frequency connection/security transitions, excluding key material and HID traffic.
predicate='process == "bluetoothd" AND (
    eventMessage CONTAINS[c] "Received a pairing request" OR
    eventMessage CONTAINS[c] "Denying pairing request" OR
    eventMessage CONTAINS[c] "smpPairingCompleted" OR
    eventMessage CONTAINS[c] "Pairing failed" OR
    eventMessage CONTAINS[c] "Encryption is now enabled" OR
    eventMessage CONTAINS[c] "encryptionStatusChangedCb" OR
    eventMessage CONTAINS[c] "incoming LE connection complete" OR
    eventMessage CONTAINS[c] "LE Link disconnected" OR
    eventMessage CONTAINS[c] "LE ConnManager disconnection complete" OR
    eventMessage CONTAINS[c] "Disconnected from device" OR
    eventMessage CONTAINS[c] "Connection timed out to device" OR
    eventMessage CONTAINS[c] "is already connected" OR
    eventMessage CONTAINS[c] "Disconnecting duplicate" OR
    eventMessage CONTAINS[c] "Controller reported a duplicate connection" OR
    eventMessage CONTAINS[c] "Registering pairing agent" OR
    eventMessage CONTAINS[c] "Creating pairing agent" OR
    eventMessage CONTAINS[c] "Unregistering pairing agent" OR
    eventMessage CONTAINS[c] "Removing pairing agent" OR
    eventMessage CONTAINS[c] "Destroying pairing agent" OR
    eventMessage CONTAINS[c] "PairingAgentRegistered" OR
    eventMessage CONTAINS[c] "PairingAgentUnregistered"
)'
collect "Bluetooth system events (last $minutes minutes)" /usr/bin/log show \
    --last "${minutes}m" --style compact --info --predicate "$predicate"

if (( report_exit != 0 )); then
    print -- '[Incomplete report] One or more sections could not be collected; see collection gaps above.'
fi
exit "$report_exit"
