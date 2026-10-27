<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/header/graph.svg?title=sys-health-check&subtitle=Small%2C+readable+health+checks+for+Linux&logo=linux&mode=dark" />
    <img alt="sys-health-check" src="https://shieldcn.dev/header/graph.svg?title=sys-health-check&subtitle=Small%2C+readable+health+checks+for+Linux&logo=linux&mode=light" />
  </picture>
</p>

<p align="center">
  <a href="https://www.gnu.org/software/bash/"><img alt="Shell: Bash" src="https://shieldcn.dev/badge/shell-bash.svg?variant=secondary"></a>
  <a href="https://www.kernel.org/"><img alt="Platform: Linux" src="https://shieldcn.dev/badge/platform-linux.svg?variant=secondary"></a>
  <img alt="Runtime: systemd" src="https://shieldcn.dev/badge/runtime-systemd.svg?variant=secondary">
  <img alt="Exit codes: 0, 1, 2" src="https://shieldcn.dev/badge/exit%20codes-0%2F1%2F2.svg?variant=secondary">
</p>

<p align="center"><em>Disk, CPU load, and systemd services — one clear status.</em></p>

`sys-health-check` is a small collection of readable Bash checks for Linux:

- `scripts/disk_check.sh` watches root filesystem capacity.
- `scripts/cpu_service_check.sh` watches one-minute CPU load, failed systemd
  units, and an optional list of critical services.

Each check prints a plain-language result and returns the same simple contract:
`0` for OK, `1` for WARNING, and `2` for CRITICAL. The CPU/service script runs
all of its checks before choosing the worst status, so one problem never hides
another.

| Check | Script | Warning (`1`) | Critical (`2`) |
|---|---|---|---|
| Root filesystem usage | `disk_check.sh` | 80% or more | 90% or more |
| One-minute load per core | `cpu_service_check.sh` | 1.5 or more | 3.0 or more |
| Failed systemd units | `cpu_service_check.sh` | any | — |
| Critical service inactive | `cpu_service_check.sh` | — | any |

I built these while learning Linux system administration. They are intentionally
small — a few checks, no framework — because the goal was to understand the
fundamentals properly.

## What I learned

### 1. `chmod +x`: the difference between a text file and a program

I used to run scripts with `bash script.sh` and wonder why `./script.sh` failed
with `Permission denied`. The answer is the execute bit.

Bash can read any file you can read, so `bash script.sh` works even when the
file is not executable. But `./script.sh` asks the kernel to execute the file
directly, and that only works when the execute bit is set for your user:

```bash
chmod +x scripts/disk_check.sh
ls -l scripts/disk_check.sh
```

```text
-rwxr-xr-x 1 orion users 457 Oct 26 18:23 scripts/disk_check.sh
```

The `x` in `rwx` is the execute bit. The shebang, `#!/usr/bin/env bash`, tells
the kernel which interpreter to use once execution is allowed.

I also learned to be deliberate about permissions: `chmod u+x` is enough when
only the owner needs to run the script, and `chmod 777` is almost never the
right answer.

### 2. Cutting through noise: small tools, one job each

`df` and `systemctl` are written for humans, not parsers. Instead of reading
entire lines, I let each command do one small job:

```bash
df -P / | awk 'NR==2 {print $5}' | sed 's/%//'
systemctl --failed --no-legend | wc -l
```

`df -P` gives stable POSIX output, one line per filesystem. `awk` selects the
second record and its fifth field, and `sed` removes the percent sign. For the
service check, `--no-legend` removes the headers and footer, and `wc -l` counts
what remains. Inspecting the output after each stage is the shell equivalent of
testing as you go.

I also learned to state my assumptions. `NR==2` assumes root is the second line.
A more explicit version matches the mount point instead:

```bash
usage=$(df -P / | awk '$6 == "/" {gsub(/%/, "", $5); print $5}')
```

### 3. Exit codes: how a script talks to other software

An exit code is a script's API. People read the message; cron, CI, and
monitoring tools read the number.

- `0` means success.
- A non-zero value means failure, and the value can carry meaning.
- `$?` holds the status of the most recent command, so capture it immediately.
- An explicit `exit` sets the final status; without it, the last command decides.

Here, `1` means warning and `2` means critical. That lets automation escalate
differently instead of treating every problem as the same emergency.

### 4. Bash cannot compare floats, so `awk` does it

Bash arithmetic is integer-only. A comparison such as `(( load >= 1.5 ))` fails
with an invalid arithmetic operator, and `[ "$load" -ge 1.5 ]` reports that an
integer is expected. Load average is a decimal, so the comparison needs a tool
that understands floats:

```bash
if awk "BEGIN {exit !($load_1m >= $crit_thresh)}"; then
    echo "CRITICAL: CPU load is $load_1m (Threshold $crit_thresh)"
    cpu_status=2
fi
```

`awk` does the decimal math, and `exit` turns the result into a shell status.
When the comparison is true, `!true` is `0`, which means success to `if`. When
it is false, the status is `1`.

### 5. `BEGIN` runs once, before any input

`BEGIN` is a special `awk` block that runs once before `awk` reads its first
input record. That makes it perfect for a pure calculation:

```bash
warn_thresh=$(awk "BEGIN {print $cores * $WARN_LOAD_PER_CORE}")
```

There is no file to read and no reason to wait for standard input. `BEGIN` runs
the block once and finishes. The float comparison uses the same idea; `exit`
inside `BEGIN` sets the status without needing an input file.

### 6. `nproc` counts CPUs, not processes

I assumed `nproc` returned the number of running processes. It does not: it
reports the number of processing units available to the process — the CPU cores
or threads that Linux will schedule work on.

That distinction matters because load average is system-wide. Comparing a raw
load of `6.0` against a fixed threshold of `1.5` would only make sense on a
single-core machine. The script scales the thresholds by the number of cores:

```bash
warn_thresh=$(awk "BEGIN {print $cores * $WARN_LOAD_PER_CORE}")
```

With four cores, the warning threshold becomes `6.0` and the critical threshold
becomes `12.0`.

### 7. `--no-legend` keeps the service count clean

```bash
failed_count=$(systemctl --failed --no-legend | wc -l)
```

By default, `systemctl` includes a header and footer in its output. Piping that
straight into `wc -l` would count formatting lines as if they were failed
services. `--no-legend` removes the legend, leaving one line per failed unit.

The spelling matters: it is `--no-legend`, not `--no-legent`. One extra detail:
failed units still carry a bullet marker in this mode, which is why the display
loop uses `$2` for the unit name. Adding `--plain` would remove the bullet and
make the unit name `$1`.

### 8. Aggregate exit codes: collect first, decide last

A multi-check script should not exit on the first problem. If it does, the reader
never sees the other results. Each check stores its own status:

```bash
cpu_status=0
svc_status=0

# ... run the CPU and service checks ...
# cpu_status and svc_status are set to 0, 1, or 2

if (( cpu_status == 2 || svc_status == 2 )); then
    exit 2
elif (( cpu_status == 1 || svc_status == 1 )); then
    exit 1
else
    exit 0
fi
```

The final decision follows severity order: `2` beats `1`, and `1` beats `0`.
That way the caller gets one meaningful status, but every check still gets a
chance to report its finding.

## My choices along the way

### Why `(( usage >= CRIT_THRESHOLD ))` instead of `[ ... ]`

```bash
if (( usage >= CRIT_THRESHOLD )); then
```

The alternative would look like this:

```bash
if [ "$usage" -ge "$CRIT_THRESHOLD" ]; then
```

Both are valid. I chose the arithmetic form for a few reasons:

- `(( ... ))` is Bash's arithmetic context. It evaluates variable names
  automatically, so `usage` needs no `$`. In `[ ... ]`, the `$` is required for
  expansion; without it, the test compares against the literal text `usage`.
- Comparisons use familiar math operators: `>=`, `>`, `<=`, `==`. The `[ ... ]`
  command uses test operators such as `-ge`, `-gt`, `-le`, and `-eq`, which are
  easy to mix up and can produce confusing errors.
- The script already requires Bash because of its shebang, so there is no
  portability cost here.

| Intent | Arithmetic form | `test` form |
|---|---|---|
| Greater than or equal | `(( usage >= 80 ))` | `[ "$usage" -ge 80 ]` |
| Greater than | `(( usage > 80 ))` | `[ "$usage" -gt 80 ]` |
| Equal | `(( usage == 80 ))` | `[ "$usage" -eq 80 ]` |

`[[ ... ]]` is not a shortcut around this. Its `<` and `>` operators compare
strings, so `[[ 9 > 10 ]]` is true in lexicographic order. Numeric comparisons
still need `-ge` and `-gt`.

### Other choices

- **`awk` instead of `bc` for floats.** `awk` was already part of the toolset,
  understands decimals, and can translate its result into an exit status. `bc`
  would add another dependency and more plumbing.
- **Per-core thresholds instead of a raw load limit.** A load of `6.0` is busy
  on one core and relaxed on eight. Scaling by `nproc` makes the check portable
  across machines.
- **`--no-legend` before `wc -l`.** Counting formatted output is fragile.
  Removing the legend first keeps the count tied to real units.
- **Collect statuses, then exit once.** Early exits are simpler in a one-check
  script, but they hide information in a multi-check script.
- **Separate scripts by concern.** Disk, CPU, and services fail in different
  ways and are easier to read and schedule separately.
- **An empty `CRITICAL_SERVICES` list by default.** Service names differ between
  distributions and roles. Add your own to the array at the top of the script
  instead of letting the script guess.
- **`df -P /` instead of `df -h`.** Human-readable sizes are nice to read but
  awkward to parse. POSIX output is predictable and keeps one filesystem per
  line.

## Running it

```bash
chmod +x scripts/*.sh
./scripts/disk_check.sh
./scripts/cpu_service_check.sh
```

Sample output from a healthy host:

```console
░▒▓ ❄️   …/sys-health-check   main ?   14:39 
❯ ./scripts/disk_check.sh
OK: Root filesystem is 42% full.
❯ ./scripts/cpu_service_check.sh
OK: CPU load is 4.32
OK: No failed systemd services.
```

To check essential services as well, add their unit names to the array near the
top of `cpu_service_check.sh`:

```bash
CRITICAL_SERVICES=(sshd nginx)
```

## Test run

`tests/test_health_checks.sh` runs both checks against temporary copies with
controlled thresholds and a small fake `systemctl`. The tests do not depend on
the current CPU load or the state of services on the machine, so the result is
repeatable.

```console
░▒▓ ❄️   …/sys-health-check   main ?   14:39 
❯ ./tests/test_health_checks.sh
PASS  disk_check.sh: healthy filesystem exits 0
PASS  disk_check.sh: warning threshold exits 1
PASS  disk_check.sh: critical threshold exits 2
PASS  cpu_service_check.sh: healthy CPU and services exits 0
PASS  cpu_service_check.sh: high load exits 1
PASS  cpu_service_check.sh: critical load exits 2
PASS  cpu_service_check.sh: failed unit exits 1
PASS  cpu_service_check.sh: dead critical service outranks CPU warning

All 8 tests passed.
```

## Automating both checks

Each script sets `$?`, so a wrapper can run both and keep the worst status:

```bash
./scripts/disk_check.sh; disk_status=$?
./scripts/cpu_service_check.sh; cpu_status=$?

status=$(( disk_status > cpu_status ? disk_status : cpu_status ))
echo "Overall status: ${status}"
exit "${status}"
```

The same pattern works in cron, a systemd timer, or a monitoring agent. Route
`1` and `2` to different alert severities when your tooling supports it.

## Requirements and layout

- Linux, with systemd available for `cpu_service_check.sh`
- Bash 4 or newer
- Standard tools: `df`, `awk`, `sed`, `nproc`, and `wc`
- `/proc/loadavg` for the one-minute load average

```text
sys-health-check/
├── README.md
├── scripts/
│   ├── cpu_service_check.sh
│   └── disk_check.sh
└── tests/
    └── test_health_checks.sh
```

`disk_check.sh` checks capacity, not inode exhaustion. `cpu_service_check.sh`
checks load and selected services, not every process on the host. Neither script
replaces a full monitoring agent; they are small early warnings that are easy to
read and easy to extend.
