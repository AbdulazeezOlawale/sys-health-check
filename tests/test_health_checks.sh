#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

tests=0
failures=0

mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/failbin" "${TMP_DIR}/netbin"

cat > "${TMP_DIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
mode=${FAKE_SYSTEMCTL_MODE:-ok}

case "$1" in
    --failed)
        if [[ "${mode}" == "failed" ]]; then
            printf '● broken.service loaded failed failed test\n'
        elif [[ "${mode}" == "error" ]]; then
            exit 1
        fi
        exit 0
        ;;
    is-active)
        [[ "${mode}" == "inactive" ]] && exit 3
        exit 0
        ;;
esac

exit 0
EOF

cat > "${TMP_DIR}/failbin/df" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "${TMP_DIR}/netbin/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_IP_MODE:-ok}" == "none" ]]; then
    exit 0
fi
printf 'default via 192.0.2.1 dev eth0 proto static\n'
EOF

cat > "${TMP_DIR}/netbin/ping" <<'EOF'
#!/usr/bin/env bash
target="${@: -1}"

if [[ "${target}" == "192.0.2.1" ]]; then
    mode=${FAKE_GATEWAY_MODE:-ok}
else
    mode=${FAKE_INTERNET_MODE:-ok}
fi

[[ "${mode}" == "fail" ]] && exit 1
exit 0
EOF

cat > "${TMP_DIR}/netbin/dig" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_DNS_MODE:-ok}" == "fail" ]]; then
    exit 0
fi
printf '93.184.216.34\n'
EOF

cat > "${TMP_DIR}/netbin/getent" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_GETENT_MODE:-ok}" == "ok" ]] && exit 0
exit 2
EOF

cat > "${TMP_DIR}/netbin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'
printf 'LISTEN 0 128 127.0.0.1:5432 0.0.0.0:*\n'
EOF

chmod +x "${TMP_DIR}/bin/systemctl" "${TMP_DIR}/failbin/df" \
    "${TMP_DIR}/netbin/ip" "${TMP_DIR}/netbin/ping" \
    "${TMP_DIR}/netbin/dig" "${TMP_DIR}/netbin/getent" \
    "${TMP_DIR}/netbin/ss"

make_disk_variant() {
    local warn=$1
    local crit=$2
    local dest=$3

    sed -e "s/^WARN_THRESHOLD=.*/WARN_THRESHOLD=${warn}/" \
        -e "s/^CRIT_THRESHOLD=.*/CRIT_THRESHOLD=${crit}/" \
        "${ROOT_DIR}/scripts/disk_check.sh" > "${dest}"
    chmod +x "${dest}"
}

make_cpu_variant() {
    local warn=$1
    local crit=$2
    local services=$3
    local dest=$4

    sed -e "s/^WARN_LOAD_PER_CORE=.*/WARN_LOAD_PER_CORE=${warn}/" \
        -e "s/^CRIT_LOAD_PER_CORE=.*/CRIT_LOAD_PER_CORE=${crit}/" \
        -e "s/^CRITICAL_SERVICES=.*/CRITICAL_SERVICES=(${services})/" \
        "${ROOT_DIR}/scripts/cpu_service_check.sh" > "${dest}"
    chmod +x "${dest}"
}

check_result() {
    local name=$1
    local expected=$2
    local actual=$3
    local pattern=$4
    local output=$5

    tests=$((tests + 1))
    if [[ "${actual}" -eq "${expected}" && "${output}" == *"${pattern}"* ]]; then
        printf 'PASS  %s\n' "${name}"
    else
        failures=$((failures + 1))
        printf 'FAIL  %s\n' "${name}"
        printf '      expected exit: %s, actual: %s\n' "${expected}" "${actual}"
        printf '      expected output to contain: %s\n' "${pattern}"
        printf '      actual output:\n%s\n' "${output}"
    fi
}

run_case() {
    local name=$1
    local expected=$2
    local pattern=$3
    local script=$4
    local mode=${5:-ok}
    local path_prefix=${6:-${TMP_DIR}/bin}
    local output
    local status

    output=$(env PATH="${path_prefix}:${PATH}" FAKE_SYSTEMCTL_MODE="${mode}" "${script}" 2>&1)
    status=$?
    check_result "${name}" "${expected}" "${status}" "${pattern}" "${output}"
}

run_net_case() {
    local name=$1
    local expected=$2
    local pattern=$3
    local script=$4
    local ip_mode=${5:-ok}
    local gateway_mode=${6:-ok}
    local internet_mode=${7:-ok}
    local dns_mode=${8:-ok}
    local getent_mode=${9:-ok}
    local output
    local status

    output=$(env PATH="${TMP_DIR}/netbin:${PATH}" \
        FAKE_IP_MODE="${ip_mode}" \
        FAKE_GATEWAY_MODE="${gateway_mode}" \
        FAKE_INTERNET_MODE="${internet_mode}" \
        FAKE_DNS_MODE="${dns_mode}" \
        FAKE_GETENT_MODE="${getent_mode}" \
        "${script}" 2>&1)
    status=$?
    check_result "${name}" "${expected}" "${status}" "${pattern}" "${output}"
}

make_disk_variant 101 102 "${TMP_DIR}/disk_ok.sh"
make_disk_variant 0 101 "${TMP_DIR}/disk_warn.sh"
make_disk_variant 0 0 "${TMP_DIR}/disk_crit.sh"

run_case "disk_check.sh: healthy filesystem exits 0" 0 "OK:" "${TMP_DIR}/disk_ok.sh"
run_case "disk_check.sh: warning threshold exits 1" 1 "WARNING:" "${TMP_DIR}/disk_warn.sh"
run_case "disk_check.sh: critical threshold exits 2" 2 "CRITICAL:" "${TMP_DIR}/disk_crit.sh"
run_case "disk_check.sh: unreadable df exits 127" 127 "UNKNOWN:" "${TMP_DIR}/disk_ok.sh" ok "${TMP_DIR}/failbin"

make_cpu_variant 999999 999999 "" "${TMP_DIR}/cpu_ok.sh"
make_cpu_variant 0 999999 "" "${TMP_DIR}/cpu_warn.sh"
make_cpu_variant 0 0 "" "${TMP_DIR}/cpu_crit.sh"
make_cpu_variant 999999 999999 "" "${TMP_DIR}/svc_warn.sh"
make_cpu_variant 0 999999 "missing.service" "${TMP_DIR}/svc_crit.sh"

run_case "cpu_service_check.sh: healthy CPU and services exits 0" 0 "OK: CPU load" "${TMP_DIR}/cpu_ok.sh" ok
run_case "cpu_service_check.sh: high load exits 1" 1 "WARNING: CPU load" "${TMP_DIR}/cpu_warn.sh" ok
run_case "cpu_service_check.sh: critical load exits 2" 2 "CRITICAL: CPU load" "${TMP_DIR}/cpu_crit.sh" ok
run_case "cpu_service_check.sh: failed unit exits 1" 1 "broken.service" "${TMP_DIR}/svc_warn.sh" failed
run_case "cpu_service_check.sh: dead critical service outranks CPU warning" 2 "missing.service" "${TMP_DIR}/svc_crit.sh" inactive
run_case "cpu_service_check.sh: systemctl failure exits 127" 127 "UNKNOWN:" "${TMP_DIR}/cpu_ok.sh" error

run_net_case "network_check.sh: healthy network exits 0" 0 "OK: Gateway" "${ROOT_DIR}/scripts/network_check.sh"
run_net_case "network_check.sh: unreachable gateway exits 2" 2 "Cannot reach gateway" "${ROOT_DIR}/scripts/network_check.sh" ok fail
run_net_case "network_check.sh: no internet exits 2" 2 "Cannot ping" "${ROOT_DIR}/scripts/network_check.sh" ok ok fail
run_net_case "network_check.sh: DNS failure exits 2" 2 "DNS resolution failed" "${ROOT_DIR}/scripts/network_check.sh" ok ok ok fail fail
run_net_case "network_check.sh: dig failure falls back to getent" 0 "using getent" "${ROOT_DIR}/scripts/network_check.sh" ok ok ok fail ok
run_net_case "network_check.sh: missing default route exits 2" 2 "No default gateway" "${ROOT_DIR}/scripts/network_check.sh" none

if (( failures > 0 )); then
    printf '\n%d test(s) failed, %d passed\n' "${failures}" "$((tests - failures))"
    exit 1
fi

printf '\nAll %d tests passed.\n' "${tests}"
