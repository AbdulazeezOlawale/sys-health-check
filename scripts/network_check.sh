#!/usr/bin/env bash

# variable declaration
TARGET_IP="8.8.8.8"
TARGET_DOMAIN="google.com"
status=0

for cmd in ip ping awk ss sort head; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "UNKNOWN: required command '${cmd}' not found" >&2
        exit 127
    fi
done

if ! command -v dig >/dev/null 2>&1 && ! command -v getent >/dev/null 2>&1; then
    echo "UNKNOWN: neither 'dig' nor 'getent' found on system" >&2
    exit 127
fi

# check default gateway
if ! route_output=$(ip route 2>/dev/null); then
    echo "UNKNOWN: unable to read routing table" >&2
    exit 127
fi

gateway=$(printf '%s\n' "$route_output" | awk '/default/ {print $3; exit}')
if [[ -z "$gateway" ]]; then
    echo "CRITICAL: No default gateway found."
    exit 2
fi

if ! ping -c 1 -w 2 "$gateway" > /dev/null 2>&1; then
    echo "CRITICAL: Cannot reach gateway ($gateway)."
    status=2
else
    echo "OK: Gateway ($gateway) reachable."
fi

# check internet (ping)
if ! ping -c 1 -w 2 "$TARGET_IP" > /dev/null 2>&1; then
    echo "CRITICAL: Cannot ping $TARGET_IP."
    status=2
else
    echo "OK: Internet connectivity verified."
fi

# Check DNS
if command -v dig > /dev/null 2>&1; then
    resolved=$(dig +short "$TARGET_DOMAIN" 2>/dev/null)
    if [[ -n "$resolved" ]]; then
        echo "OK: DNS resolution successful."
    elif command -v getent > /dev/null 2>&1 && getent hosts "$TARGET_DOMAIN" > /dev/null 2>&1; then
        echo "OK: DNS resolution successful (using getent fallback)."
    else
        echo "CRITICAL: DNS resolution failed for $TARGET_DOMAIN."
        status=2
    fi
elif command -v getent > /dev/null 2>&1; then
    if ! getent hosts "$TARGET_DOMAIN" > /dev/null 2>&1; then
        echo "CRITICAL: DNS resolution failed for $TARGET_DOMAIN (using getent)."
        status=2
    else
        echo "OK: DNS resolution successful (using getent)."
    fi
fi

# Info: Listening Ports
echo "--- Top Listening TCP Ports ---"
ss -tln | awk 'NR>1 {print $4}' | sort -u | head -n 5

exit "${status}"