<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/header/graph.svg?title=sys-health-check&subtitle=A+small%2C+reliable+disk+check+for+Linux&logo=linux&mode=dark" />
    <img alt="sys-health-check" src="https://shieldcn.dev/header/graph.svg?title=sys-health-check&subtitle=A+small%2C+reliable+disk+check+for+Linux&logo=linux&mode=light" />
  </picture>
</p>

<p align="center">
  <a href="https://www.gnu.org/software/bash/"><img alt="Shell: Bash" src="https://shieldcn.dev/badge/shell-bash.svg?variant=secondary"></a>
  <a href="https://www.kernel.org/"><img alt="Platform: Linux" src="https://shieldcn.dev/badge/platform-linux.svg?variant=secondary"></a>
  <img alt="Dependencies: none" src="https://shieldcn.dev/badge/dependencies-none.svg?variant=secondary">
  <img alt="Exit codes: 0, 1, 2" src="https://shieldcn.dev/badge/exit%20codes-0%2F1%2F2.svg?variant=secondary">
</p>

<p align="center"><em>One script. One job. A clear answer about your root filesystem.</em></p>

`sys-health-check` is a small, dependency-free Bash utility that watches the
root filesystem. It reads disk usage, compares it against two thresholds, prints
a plain-language message, and exits with a status that other tools can act on.

| Usage | State | Exit code |
|---|---|---|
| Below 80% | OK | `0` |
| 80% to 89% | WARNING | `1` |
| 90% or higher | CRITICAL | `2` |

I built it while learning Linux system administration. It is intentionally
small — one script, one job — because the goal was to understand the
fundamentals properly, not to hide them behind a framework.

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

`df` is written for humans, not parsers. Instead of reading the whole line, I
let each command do one small job and built the pipeline one stage at a time:

```bash
df -P /
df -P / | awk 'NR==2 {print $5}'
df -P / | awk 'NR==2 {print $5}' | sed 's/%//'
```

`df -P` gives stable POSIX output, one line per filesystem. `awk` selects the
second record and its fifth field, and `sed` removes the percent sign. Inspecting
the output after every stage is the shell equivalent of testing as you go: when
something looks wrong, you know exactly which step caused it.

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
differently instead of treating every problem as the same emergency. If I had
returned `1` for everything, the message would still be useful to a human, but
the tool would be much less useful to a machine.

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
- `[ ... ]` is a command, so spacing and quoting matter. `(( ... ))` is a shell
  construct, so numeric variables can be written naturally.
- The script already requires Bash because of its shebang. There is no
  portability cost in this context.

The difference is easiest to see side by side:

| Intent | Arithmetic form | `test` form |
|---|---|---|
| Greater than or equal | `(( usage >= 80 ))` | `[ "$usage" -ge 80 ]` |
| Greater than | `(( usage > 80 ))` | `[ "$usage" -gt 80 ]` |
| Equal | `(( usage == 80 ))` | `[ "$usage" -eq 80 ]` |

`[[ ... ]]` is not a shortcut around this. Its `<` and `>` operators compare
strings, so `[[ 9 > 10 ]]` is true in lexicographic order. Numeric comparisons
still need `-ge` and `-gt`, which is another reason to keep numeric logic inside
`(( ... ))`.

The trade-off is that `(( ... ))` is not POSIX `sh`. If this needed to run under
a strictly POSIX shell, I would use `[ "$usage" -ge "$CRIT_THRESHOLD" ]` and
change the shebang. For this script, Bash is a deliberate choice, so the clearer
syntax wins.

### Other choices

- **`df -P /` instead of `df -h`.** Human-readable sizes are nice to read but
  awkward to parse. POSIX output is predictable and keeps one filesystem per
  line.
- **`awk` plus `sed` instead of one clever one-liner.** Each stage can be tested
  on its own, which matters more than saving a few characters.
- **Thresholds as named variables.** `WARN_THRESHOLD` and `CRIT_THRESHOLD` at the
  top of the file are self-documenting and easy to change.
- **Distinct exit codes `0`, `1`, and `2`.** The extra code is what separates a
  warning from an emergency.
- **Checking `/` only.** This is a deliberately small scope. Extending it to
  other mount points is a future improvement, not a hidden feature.
- **Explicit `exit` statements.** The script's job is to report a status, so it
  says exactly what that status is rather than relying on the last command.

## Running it

```bash
chmod +x scripts/disk_check.sh
./scripts/disk_check.sh
echo $?
```

Healthy output looks like this:

```console
$ ./scripts/disk_check.sh
OK: Root filesystem is 66% full.
$ echo $?
0
```

When a threshold is crossed, the message and status change:

```console
$ ./scripts/disk_check.sh
WARNING: Root filesystem is 84% full.
$ echo $?
1
```

## Using the exit code in automation

Capture the status before doing anything else:

```bash
./scripts/disk_check.sh
status=$?

case "${status}" in
    0) echo "Disk is healthy." ;;
    1) echo "Disk warning: schedule cleanup." ;;
    2) echo "Disk critical: investigate now." ;;
    *) echo "Disk check failed unexpectedly (status ${status})." ;;
esac
```

A cron entry that logs output and reports failures to syslog:

```cron
*/15 * * * * /opt/sys-health-check/scripts/disk_check.sh >> /var/log/disk-check.log 2>&1 || logger -t disk-check "disk check failed with status $?"
```

For production, prefer a systemd timer or your monitoring agent, and route `1`
and `2` to different alert severities.

## Requirements and layout

Linux, Bash 4 or newer, and the standard `df`, `awk`, and `sed` tools.

```text
sys-health-check/
├── README.md
└── scripts/
    └── disk_check.sh
```

The script checks capacity, not inode exhaustion, and it does not replace a
full monitoring agent. It is a small early warning that is easy to read, easy to
trust, and easy to extend.
# sys-health-check
