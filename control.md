# control.md — Boot Control Helpers (Bash 5+)

Portable control-flow utilities: **try/capture**, **backoff**, **retry**, **timeout**, and **exclusive locks** — all safe under `set -Eeuo pipefail`.

---

## ⚙️ Setup

At the top of your script:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"
```

That’s it—`boot::` APIs are ready.

---

## 🚀 Quick glance

```bash
# 1) Capture stdout/stderr without aborting the script
out="" err=""
if boot::try out err -- curl -fsS https://example.com; then
  boot::log success "ok: ${#out} bytes"
else
  boot::log error "curl failed: $err"
fi

# 2) Retry with exponential backoff (base=0.2s, up to 5 tries)
boot::retry 5 boot::backoff_expo 0.2 -- curl -fsS https://api/ping

# 3) Kill long-running tasks after 3.5 seconds; rc=124 on timeout
if ! boot::timeout 3.5 -- some_task --maybe-slow; then
  [[ $? -eq 124 ]] && boot::log warn "timed out"
fi

# 4) Exclusive section (flock if available; mkdir fallback); 10s max wait
boot::with_lock "/tmp/my.lock" --timeout 10 -- bash -lc 'critical_update'
```

---

## 📚 API Overview

| Function                                               | Purpose                                                        | Returns                         |
| ------------------------------------------------------ | -------------------------------------------------------------- | ------------------------------- |
| `boot::try OUT ERR -- cmd...`                          | Capture stdout/stderr of `cmd` into vars; propagate `cmd`’s rc | `cmd`’s rc                      |
| `boot::backoff_const base`                             | Constant backoff                                               | seconds (float) on stdout       |
| `boot::backoff_expo base n`                            | Exponential `base * 2^(n-1)`                                   | seconds (float) on stdout       |
| `boot::backoff_jitter base n`                          | Uniform random in `[0, base*n]`                                | seconds (float) on stdout       |
| `boot::retry N backoff BASE -- cmd...`                 | Retry with pluggable backoff                                   | `0` (success) or last rc        |
| `boot::timeout SECONDS -- cmd...`                      | Run with timeout (GNU `timeout` if present)                    | `124` on timeout, else `cmd` rc |
| `boot::with_lock /path/lock [--timeout SEC] -- cmd...` | Exclusive lock (flock → mkdir fallback)                        | `124` on timeout, else `cmd` rc |

> **Dependencies:** `awk` recommended (backoff math, jitter). If present: `timeout(1)` and `flock(1)` are preferred; otherwise portable fallbacks are used.

---

## 🧪 `boot::try` — capture stdout/stderr

**Signature**

```bash
boot::try OUT_VAR ERR_VAR -- command arg...
# OUT_VAR and ERR_VAR are variable *names* (identifiers)
```

**Example**

```bash
html="" err=""
if boot::try html err -- wget -qO- https://example.com; then
  printf '%s\n' "$html" | wc -c
else
  boot::log error "wget failed: $err"
fi
```

**Notes**

* OUT/ERR vars are cleared first, then filled with captured text.
* Exit code is exactly the command’s exit code.

---

## ⏱ Backoff helpers

All print the sleep time to stdout.

```bash
boot::backoff_const 0.5        # → 0.5
boot::backoff_expo 0.2 3       # → 0.8   (0.2 * 2^(3-1))
boot::backoff_jitter 0.5 4     # → [0.000000 .. 2.000000]
```

Use them directly with `boot::retry`, or roll your own as long as it prints seconds.

---

## 🔁 `boot::retry` — robust retries

**Signature**

```bash
boot::retry ATTEMPTS BACKOFF_FN BASE -- command arg...
# BACKOFF_FN base attempt_index -> prints seconds to sleep
```

**Behavior**

* Stops on first success (`rc=0`).
* On failures, sleeps for the amount printed by `BACKOFF_FN BASE attempt`.
* Logs retries via `boot::log warn` when available.

**Example: exponential with jitter**

```bash
# Composite backoff: min(expo, jitter+expo)
my_backoff() {
  local base="${1:-0.2}" n="${2:-1}"
  local e j
  e="$(boot::backoff_expo "$base" "$n")"
  j="$(boot::backoff_jitter "$base" "$n")"
  # choose the smaller to cap spikes
  awk -v a="$e" -v b="$j" 'BEGIN{print (a<b)?a:b}'
}

boot::retry 6 my_backoff 0.3 -- curl -fsS https://api/service
```

---

## ⌛ `boot::timeout` — hard time limits

**Signature**

```bash
boot::timeout SECONDS -- command arg...
```

**Returns**

* `124` if the command exceeded the time limit.
* Otherwise the command’s own exit code.

**Example**

```bash
if ! boot::timeout 5.0 -- python long_job.py; then
  case $? in
    124) boot::log warn "long_job: timed out after 5s" ;;
    *)   boot::log error "long_job failed (rc=$?)" ;;
  esac
fi
```

**Fallback details**

* If GNU `timeout` is missing, a watchdog uses integer-ceiled seconds, sends **TERM**, then **KILL** after ~1s if still running.
* Tries to signal the **process group** (better for pipelines) when `setsid` is available.

---

## 🔒 `boot::with_lock` — exclusive critical sections

**Signature**

```bash
boot::with_lock /path/to/lockfile [--timeout SEC] -- command arg...
# Default timeout: 30 (seconds, integer)
```

**Behavior**

* If `flock(1)` exists: uses FD-based exclusive lock with `-w SEC`.
* Else: portable `mkdir` spinlock with light random jitter.
* Ensures parent directory exists.

**Examples**

```bash
# Run a migration step once across many cron workers
boot::with_lock "/var/lock/migrate.lock" -- timeout 60s php artisan migrate --force

# Protect a small critical update; wait up to 10s
boot::with_lock "/tmp/cache.lock" --timeout 10 -- bash -lc 'rebuild_cache'
```

**Return codes**

* `124` on lock acquisition timeout.
* Command’s rc on success; `2` for invalid usage.

---

## 🍳 Cookbooks

### 1) Capture + Retry + Timeout (resilient fetch)

```bash
fetch_json() {
  local out="" err=""
  if ! boot::timeout 4.0 -- boot::try out err -- curl -fsS "https://api/foo"; then
    [[ $? -eq 124 ]] && { boot::log warn "fetch timed out"; return 124; }
  fi
  printf '%s\n' "$out"
}

boot::retry 5 boot::backoff_expo 0.25 -- bash -lc 'fetch_json'
```

### 2) Cross-process mutual exclusion for cron

```bash
job() { echo "do work $(date)"; sleep 2; }
boot::with_lock "/var/lock/daily.lock" --timeout 15 -- job
```

### 3) Safe pipeline with timeout (group kill)

```bash
# Whole pipeline is protected when GNU timeout exists; fallback tries process-group signals.
boot::timeout 6 -- bash -lc 'producer | grep -v noisy | consumer'
```

### 4) Idempotent file writes with lock

```bash
update_conf() { printf 'key=value\n' > /etc/myapp.conf; }
boot::with_lock "/var/lock/myapp.conf.lock" --timeout 5 -- update_conf
```

---

## 🧩 Notes & guarantees

* All functions validate arguments; identifiers must be valid shell names; arrays must be `declare -a`.
* `boot::try` uses secure temp files (umask `077`) and cleans up even on failure.
* `boot::retry` accepts any callable backoff function as long as it **prints seconds**.
* `boot::timeout` emulates GNU `timeout`’s `124` exit code on overrun.
* `boot::with_lock` is safe to run concurrently across many processes/shells.

---

## 🛠 Troubleshooting

| Symptom                        | Cause / Fix                                            |
| ------------------------------ | ------------------------------------------------------ |
| `with_lock: command required`  | Missing `--` separator before the command              |
| `retry: attempts must be >=1`  | First arg to `boot::retry` must be `1+`                |
| Timeouts don’t stop a pipeline | Ensure GNU `timeout` is installed for best results     |
| Lock never acquired            | Path not writeable; check parent directory permissions |
| Backoff always 0               | `awk` missing? Install it or use `boot::backoff_const` |

---

## 🔎 Return-code summary

* **`boot::try`** → command rc
* **`boot::retry`** → `0` on success; otherwise last rc
* **`boot::timeout`** → `124` on timeout; else command rc
* **`boot::with_lock`** → `124` on timeout; `2` usage error; else command rc

---

**Happy scripting!**
