#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

tests=0
failures=0

mkdir -p "${TMP_DIR}/bin"

cat > "${TMP_DIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
mode=${FAKE_SYSTEMCTL_MODE:-ok}

case "$1" in
    --failed)
        if [[ "${mode}" == "failed" ]]; then
            printf '● broken.service loaded failed failed test\n'
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

chmod +x "${TMP_DIR}/bin/systemctl"

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

run_case() {
    local name=$1
    local expected=$2
    local pattern=$3
    local script=$4
    local mode=${5:-ok}
    local output
    local status

    tests=$((tests + 1))
    output=$(env PATH="${TMP_DIR}/bin:${PATH}" FAKE_SYSTEMCTL_MODE="${mode}" "${script}" 2>&1)
    status=$?

    if [[ "${status}" -eq "${expected}" && "${output}" == *"${pattern}"* ]]; then
        printf 'PASS  %s\n' "${name}"
    else
        failures=$((failures + 1))
        printf 'FAIL  %s\n' "${name}"
        printf '      expected exit: %s, actual: %s\n' "${expected}" "${status}"
        printf '      expected output to contain: %s\n' "${pattern}"
        printf '      actual output:\n%s\n' "${output}"
    fi
}

make_disk_variant 101 102 "${TMP_DIR}/disk_ok.sh"
make_disk_variant 0 101 "${TMP_DIR}/disk_warn.sh"
make_disk_variant 0 0 "${TMP_DIR}/disk_crit.sh"

run_case "disk_check.sh: healthy filesystem exits 0" 0 "OK:" "${TMP_DIR}/disk_ok.sh"
run_case "disk_check.sh: warning threshold exits 1" 1 "WARNING:" "${TMP_DIR}/disk_warn.sh"
run_case "disk_check.sh: critical threshold exits 2" 2 "CRITICAL:" "${TMP_DIR}/disk_crit.sh"

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

if (( failures > 0 )); then
    printf '\n%d test(s) failed, %d passed\n' "${failures}" "$((tests - failures))"
    exit 1
fi

printf '\nAll %d tests passed.\n' "${tests}"
