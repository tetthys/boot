# core.md — API & Usage Guide (boot/core.sh)

> Core runtime utilities for **modern Bash 5+**: strict mode, traps, defers, logging, and environment helpers.
> Safe under `set -Eeuo pipefail`. Designed for reliability in production scripts.

---

## ⚙️ Setup

Add this to the top of your script:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"
```

After sourcing, all `boot::*` APIs become available.

---

## 🧩 API Overview

| Function                                | Purpose                                        | Returns          |
| --------------------------------------- | ---------------------------------------------- | ---------------- |
| **boot::strict**                        | Enable strict Bash mode + error trap           | —                |
| **boot::on_err code line**              | Default error handler with optional stacktrace | —                |
| **boot::trap_push SIGNAL 'cmd'**        | Push a handler for a signal (stackable)        | 0                |
| **boot::trap_pop SIGNAL**               | Remove the latest handler for that signal      | 0                |
| **boot::defer 'cmd'**                   | Register a deferred command (LIFO)             | 0                |
| **boot::defer_run**                     | Execute all deferred commands (reverse order)  | 0                |
| **boot::log level message...**          | Print a formatted log line                     | 0                |
| **boot::require cmd...**                | Verify commands exist in PATH                  | 0 if all present |
| **boot::is_sourced**                    | Detect if current file is sourced              | 0 if sourced     |
| **boot::now_ms**                        | Print current epoch milliseconds               | int              |
| **boot::stacktrace**                    | Print a call stack                             | —                |
| **boot::env_get name [default]**        | Get env var or default                         | string           |
| **boot::env_get_int name [default=0]**  | Get integer env or default                     | int              |
| **boot::env_get_bool name [default=0]** | Parse env as boolean                           | 1 or 0           |
| **boot::__has cmd**                     | Internal: check if command exists              | 0 if found       |
| **boot::__require_ident name**          | Validate shell identifier                      | 0/2              |
| **boot::__require_callable name**       | Ensure function/builtin/file callable          | 0/127            |
| **boot::__is_uint str**                 | Check if unsigned int                          | 0/1              |

---

## 🚀 Usage Examples

### 1. Strict mode and error trap

Enable strict flags and automatic stack traces on failure.

```bash
boot::strict

run_critical() {
  false  # force failure
}

run_critical
```

Output:

```
[boot:error] ERR(1) at line 5
#1 run_critical (script.sh:5)
#2 main (script.sh:7)
```

---

### 2. Deferred cleanup (LIFO)

Defer cleanup commands that run automatically when exiting.

```bash
boot::strict
boot::trap_push EXIT 'boot::defer_run'

tmp="$(mktemp)"
boot::defer 'rm -f "$tmp"'
boot::log info "Temp file: $tmp"
```

When the script exits, it automatically runs:

```
rm -f /tmp/.tmp.XXXXXXX
```

---

### 3. Stackable traps

Add multiple handlers for the same signal safely.

```bash
boot::trap_push EXIT 'boot::log info "first cleanup"'
boot::trap_push EXIT 'boot::log info "second cleanup"'
```

When the script exits:

```
[boot:info] first cleanup
[boot:info] second cleanup
```

To remove the latest:

```bash
boot::trap_pop EXIT
```

---

### 4. Logging and levels

```bash
BOOT_LOG_LEVEL=debug  # default is info
boot::log debug "debug message"
boot::log info  "starting process"
boot::log warn  "retrying..."
boot::log error "failed to connect"
boot::log success "done"
```

Output:

```
[boot:debug] debug message
[boot:info] starting process
[boot:warn] retrying...
[boot:error] failed to connect
[boot:success] done
```

---

### 5. Dependency checking

```bash
boot::require curl jq || exit 1
```

Logs any missing commands:

```
[boot:warn] missing command: jq
```

---

### 6. Environment variable helpers

```bash
export ENABLE_CACHE=true
export RETRY_COUNT=3

if [[ "$(boot::env_get_bool ENABLE_CACHE 0)" -eq 1 ]]; then
  boot::log info "Cache enabled"
fi

retries="$(boot::env_get_int RETRY_COUNT 1)"
boot::log info "Retries: $retries"

api_url="$(boot::env_get API_URL "https://default/api")"
boot::log info "API URL: $api_url"
```

---

### 7. Stacktrace (manual use)

```bash
foo() { bar; }
bar() { boot::stacktrace; }
foo
```

Output:

```
#1 bar (script.sh:2)
#2 foo (script.sh:1)
#3 main (script.sh:3)
```

---

### 8. Detect sourcing

```bash
if boot::is_sourced; then
  boot::log debug "Loaded as a module"
else
  boot::log info "Running as main script"
fi
```

---

## 🔧 Configuration (environment variables)

| Variable             | Default   | Description                                |
| -------------------- | --------- | ------------------------------------------ |
| **BOOT_LOG_LEVEL**   | `info`    | Minimum log level to display               |
| **BOOT_DEBUG_STACK** | `1`       | Whether to print stack trace on error      |
| **BOOT_CACHE_DIR**   | *(empty)* | Custom cache directory (for other modules) |

---

## 🧠 Tips

* Always call `boot::strict` at the top of your script for safer behavior.
* Always pair `boot::defer` with `boot::trap_push EXIT 'boot::defer_run'`.
* Adjust `BOOT_LOG_LEVEL` to control verbosity (`debug`, `info`, `warn`, `error`, `silent`).
* Use `boot::stacktrace` liberally when debugging.

---

## 🧩 Example: full script

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"

boot::strict
boot::trap_push EXIT 'boot::defer_run'

tmp="$(mktemp)"
boot::defer 'rm -f "$tmp"'

boot::require curl || exit 1
boot::log info "Fetching data..."

if ! curl -fsS https://example.com -o "$tmp"; then
  boot::on_err $? $LINENO
  exit 1
fi

boot::log success "Downloaded $(stat -c%s "$tmp") bytes"
```

---

**boot/core.sh** gives you:
✅ strict runtime
✅ layered traps
✅ clean defers
✅ consistent logs
✅ easy environment access

**Use it as the foundation for any robust Bash toolkit.**
