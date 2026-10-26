#!/usr/bin/env bash
# scripts/disk_check.sh

# Thresholds
WARN_THRESHOLD=80
CRIT_THRESHOLD=90

# Get system disk usage
usage=$(df -P / | awk 'NR==2 {print $5}' | sed 's/%//')

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