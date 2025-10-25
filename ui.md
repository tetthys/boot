# ui.md — API & Usage Guide (boot/ui.sh)

> **boot/ui.sh** is a lightweight Bash wrapper around **Python + Rich**, providing a clean, colored, and modern command-line UI for your Bash scripts.
> Requires `python3` and the `rich` package.

---

## ⚙️ Setup

Add this to the top of your script:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"
```

Install dependencies if missing:

```bash
python3 -m pip install rich
```

---

## 🧩 Public API

| Function                                          | Purpose                            |
| ------------------------------------------------- | ---------------------------------- |
| `boot::log LEVEL MSG...`                          | Rich-styled log messages           |
| `boot::banner "Title"`                            | Print a centered banner            |
| `boot::hr`                                        | Print a horizontal divider         |
| `boot::ui::table HEAD ROWS [--sort COL] [--desc]` | Render an aligned table            |
| `boot::ui::kv_dump MAP [PAD]`                     | Pretty-print key-value pairs       |
| `boot::ui::timeline EVENTS`                       | Render timeline events             |
| `boot::spinner [--label TEXT] -- cmd args...`     | Show spinner while running command |
| `boot::progress PERCENT ["Label"]`                | Show progress bar                  |

---

## 🧱 Environment Options

| Variable             | Default   | Description                      |
| -------------------- | --------- | -------------------------------- |
| `BOOT_NO_COLOR`      | `0`       | Disable colors                   |
| `BOOT_EMOJI`         | `1`       | Enable emoji icons               |
| `BOOT_TS`            | `time`    | Timestamp style (`time`, `none`) |
| `BOOT_THEME`         | `dark`    | Theme (`light`, `dark`, `mono`)  |
| `BOOT_LOG_FORMAT`    | `text`    | Log format (`text`, `json`)      |
| `BOOT_LOG_FILE`      | *(empty)* | Optional log file                |
| `BOOT_LOG_JSON_FILE` | *(empty)* | Optional JSON log file           |
| `BOOT_PY_UI`         | *(auto)*  | Override path to `boot_ui.py`    |

---

## 🧠 Logging

```bash
boot::log debug "debug message"
boot::log info  "Starting server..."
boot::log warn  "Low memory"
boot::log error "Connection failed"
boot::log success "All done!"
```

---

## 🎉 Banner and Divider

```bash
boot::banner "Setup Complete"
boot::hr
```

---

## 📊 Tables

```bash
HEAD=(ID Name Score)
ROWS=($'1\tAlice\t98' $'2\tBob\t87')
boot::ui::table HEAD ROWS --sort Score --desc
```

---

## 🔑 Key–Value Dump

```bash
declare -A CONFIG=(
  ["Host"]="api.example.com"
  ["Port"]="443"
)
boot::ui::kv_dump CONFIG
```

Optional padding for neat alignment:

```bash
boot::ui::kv_dump CONFIG 10
```

---

## ⏳ Timeline

```bash
EVENTS=(
  "2025-01-01\tInit project"
  "2025-01-03\tSetup CI/CD"
)
boot::ui::timeline EVENTS
```

---

## 🔄 Spinner

```bash
boot::spinner --label "Building..." -- sleep 3
```

---

## 📈 Progress Bar

```bash
boot::progress 30 "Uploading"
boot::progress 60 "Uploading"
boot::progress 100 "Done"
```

---

## 🧩 Full Example

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"

boot::banner "Demo UI"

boot::log info "Starting..."
boot::spinner --label "Processing..." -- sleep 2
boot::progress 100 "Completed"

HEAD=(Step Status Time)
ROWS=($'Build\t✅\t2s' $'Test\t✅\t1s')
boot::ui::table HEAD ROWS

declare -A META=(
  ["User"]="admin"
  ["Version"]="1.3.0"
)
boot::ui::kv_dump META

boot::hr
boot::log success "All done!"
```

---

## 🧰 Notes

* Requires **Python 3** and **Rich** (`pip install rich`).
* Automatically locates `boot/boot_ui.py`, or override with `BOOT_PY_UI`.
* Fully replaces plain `boot::log` from core for rich, colored output.
* Designed for human-friendly CLI and script dashboards.
