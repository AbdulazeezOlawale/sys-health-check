#!/usr/bin/env bash
# scripts/disk_check.sh

# Thresholds
WARN_THRESHOLD=80
CRIT_THRESHOLD=90

for cmd in df awk sed; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "UNKNOWN: required command '${cmd}' not found" >&2
        exit 127
    fi
done

# Get system disk usage
usage=$(df -P / 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')

if [[ ! "${usage}" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: unable to read root filesystem usage" >&2
    exit 127
fi

if (( usage >= CRIT_THRESHOLD )); then
    echo "CRITICAL: Root filesystem is ${usage}% full!"
    exit 2
elif (( usage >= WARN_THRESHOLD )); then
    echo "WARNING: Root filesystem is ${usage}% full."
    exit 1
else
    echo "OK: Root filesystem is ${usage}% full."
    exit 0
fi