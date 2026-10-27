#!/usr/bin/env bash

# variable declaration
WARN_LOAD_PER_CORE=1.5
CRIT_LOAD_PER_CORE=3.0
CRITICAL_SERVICES=()

# core services
load_1m=$(awk '{print $1}' /proc/loadavg)
cores=$(nproc)

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
failed_count=$(systemctl --failed --no-legend | wc -l)

if (( failed_count > 0 )); then
    echo "WARNING: ${failed_count} systemd service(s) failed:"
    systemctl --failed --no-legend | awk '{print "  - " $2}'
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