#!/usr/bin/env bash

# variable declaration
WARN_LOAD_PER_CORE=1.5
CRIT_LOAD_PER_CORE=3.0
CRITICAL_SERVICES=()

for cmd in awk nproc systemctl wc; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "UNKNOWN: required command '${cmd}' not found" >&2
        exit 127
    fi
done

if [[ ! -r /proc/loadavg ]]; then
    echo "UNKNOWN: /proc/loadavg is not readable" >&2
    exit 127
fi

# core services
load_1m=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc)

if [[ ! "${load_1m}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "UNKNOWN: unable to read CPU load" >&2
    exit 127
fi

if [[ ! "${cores}" =~ ^[0-9]+$ ]] || (( cores < 1 )); then
    echo "UNKNOWN: unable to determine CPU count" >&2
    exit 127
fi

# calculate total thresholds
warn_thresh=$(awk "BEGIN {print $cores * $WARN_LOAD_PER_CORE}")
crit_thresh=$(awk "BEGIN {print $cores * $CRIT_LOAD_PER_CORE}")

# compare floats using awk
cpu_status=0
if awk "BEGIN {exit !($load_1m >= $crit_thresh)}"; then
    echo "CRITICAL: CPU load is $load_1m (Threshold $crit_thresh)"
    cpu_status=2
elif awk "BEGIN {exit !($load_1m >= $warn_thresh)}"; then
    echo "WARNING: CPU load is $load_1m (Threshold $warn_thresh)"
    cpu_status=1
else
    echo "OK: CPU load is $load_1m"
fi

# service check
svc_status=0

if ! failed_units=$(systemctl --failed --no-legend 2>/dev/null); then
    echo "UNKNOWN: unable to query systemd" >&2
    exit 127
fi

failed_count=0
if [[ -n "${failed_units}" ]]; then
    failed_count=$(printf '%s\n' "${failed_units}" | wc -l)
fi

if (( failed_count > 0 )); then
    echo "WARNING: ${failed_count} systemd service(s) failed:"
    printf '%s\n' "${failed_units}" | awk '{print "  - " $2}'
    svc_status=1
else
    echo "OK: No failed systemd services."
fi


# Check specific critical services
for svc in "${CRITICAL_SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$svc"; then
        echo "CRITICAL: Essential service '$svc' is not running!"
        svc_status=2
    fi
done

# --- Final Exit Code ---
# Return the worst status encountered (2 > 1 > 0)
if (( cpu_status == 2 || svc_status == 2 )); then
    exit 2
elif (( cpu_status == 1 || svc_status == 1 )); then
    exit 1
else
    exit 0
fi