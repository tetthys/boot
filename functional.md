# functional.md — Boot Functional Utilities (Bash 5+)

> Functional-style utilities for Bash arrays and streams.
> Safe, composable, pure functions for everyday scripting.

---

## ⚙️ Setup

Add this header at the top of your script:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"
```

Then you can call any `boot::` function right away.

---

## 🧩 Basic idea

You can treat arrays *functionally*:

* `map` → transform values
* `filter` → keep matching values
* `reduce` → fold to a single value
* `find` → get first match
* `some` / `every` → boolean checks
* `flatten`, `uniq`, `join` → utility helpers

All operate **in-place by array name**, not value.
All callbacks receive `(value, index)`.

---

## 🚀 Quick example

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${ROOT}/boot.sh"

declare -a nums=(1 2 3 4 5)

# Map: square numbers
square() { printf '%d\n' "$(( $1 * $1 ))"; }
declare -a squares
boot::map nums squares square

# Filter: even squares only
is_even() { (( $1 % 2 == 0 )); }
declare -a evens
boot::filter squares evens is_even

# Reduce: sum all
sum2() { printf '%d\n' "$(( $1 + $2 ))"; }
total=0
boot::reduce evens 0 total sum2

echo "Squares: ${squares[*]}"
echo "Evens:   ${evens[*]}"
echo "Total:   $total"
```

Output:

```
Squares: 1 4 9 16 25
Evens:   4 16
Total:   20
```

---

## 🧠 Core functions

### `boot::each IN_ARRAY CALLBACK`

Iterate array for side effects.

```bash
declare -a fruits=(apple banana cherry)
log_item() { printf '%s → %s\n' "$2" "$1"; }  # index → value
boot::each fruits log_item
```

---

### `boot::map IN_ARRAY OUT_ARRAY CALLBACK`

Transform each element `(value, index) -> echo result`.

```bash
upper() { printf '%s\n' "${1^^}"; }
declare -a caps
boot::map fruits caps upper
# caps = (APPLE BANANA CHERRY)
```

---

### `boot::filter IN_ARRAY OUT_ARRAY PREDICATE`

Keep only items where predicate exits 0.

```bash
starts_with_b() { [[ "$1" == b* ]]; }
declare -a b_fruits
boot::filter fruits b_fruits starts_with_b
# b_fruits = (banana)
```

---

### `boot::reduce IN_ARRAY INITIAL OUT_VAR REDUCER`

Accumulate into one value `(acc, value) -> echo new_acc`.

```bash
join_csv() {
  [[ -z "$1" ]] && printf '%s\n' "$2" || printf '%s,%s\n' "$1" "$2"
}
csv=""
boot::reduce fruits "" csv join_csv
echo "$csv"  # apple,banana,cherry
```

---

### `boot::find IN_ARRAY PREDICATE`

Return first element that matches (printed to stdout).

```bash
has_n() { [[ "$1" == *n* ]]; }
found="$(boot::find fruits has_n || true)"
echo "$found"  # banana
```

---

### `boot::some IN_ARRAY PREDICATE`

Check if any element matches.

```bash
has_c() { [[ "$1" == c* ]]; }
boot::some fruits has_c && echo "has C fruit"
```

---

### `boot::every IN_ARRAY PREDICATE`

Check if all elements match.

```bash
is_lower() { [[ "$1" =~ ^[a-z]+$ ]]; }
boot::every fruits is_lower && echo "all lowercase"
```

---

### `boot::flatten IN_ARRAY OUT_ARRAY`

Flatten one-level nested arrays written like strings.

```bash
declare -a nested=("a" "(b c)" "(d e f)")
declare -a flat
boot::flatten nested flat
# flat = (a b c d e f)
```

---

### `boot::uniq IN_ARRAY OUT_ARRAY`

Remove duplicates (preserve first occurrence).

```bash
declare -a words=(a b a b c)
declare -a unique
boot::uniq words unique
# unique = (a b c)
```

---

### `boot::join IN_ARRAY [DELIM=" "]`

Join elements and print to stdout.

```bash
declare -a nums=(1 2 3)
boot::join nums ","   # → 1,2,3
```

---

## 🧰 Advanced composition

### Map + Filter + Reduce chain

```bash
is_odd() { (( $1 % 2 == 1 )); }
square() { printf '%d\n' "$(( $1 * $1 ))"; }
add2()   { printf '%d\n' "$(( $1 + $2 ))"; }

declare -a odds squares
boot::filter nums odds is_odd
boot::map odds squares square
sum=0
boot::reduce squares 0 sum add2
echo "$sum"  # sum of odd squares
```

---

### Find & act

```bash
exists() { [[ -e "$1" ]]; }
declare -a paths=(/nope /etc/passwd /etc/hosts)
found="$(boot::find paths exists || true)"
[[ -n "$found" ]] && echo "Found file: $found"
```

---

## 🧩 Notes

| Behavior        | Detail                                                   |
| --------------- | -------------------------------------------------------- |
| **All arrays**  | Passed by name (`declare -a arr=()` required)            |
| **Callbacks**   | Must be callable (`function`, `builtin`, etc.)           |
| **Error codes** | 0 ok · 1 not found · 2 invalid var/id · 127 not callable |
| **Safe under**  | `set -Eeuo pipefail`                                     |
| **Requires**    | Bash ≥ 5.0 (for namerefs)                                |

---

## ⚠️ Common pitfalls

| Symptom                      | Fix                                                |
| ---------------------------- | -------------------------------------------------- |
| “not declared”               | Add `declare -a arr` before using it               |
| Empty output from `map`      | Your callback didn’t echo a result                 |
| “not callable”               | Typo or unexported function name                   |
| Wrong quoting                | Always `"$1"` / `"$2"` inside callbacks            |
| Dangerous input to `flatten` | Avoid `eval` injection; trust only internal arrays |

---

## ✅ Checklist for writing callbacks

✔ Always quote args:

```bash
local v="$1" i="$2"
```

✔ Use `printf` instead of `echo` for safety.
✔ Return `0` / `1` in predicates.
✔ Print only the intended output in `map` / `reduce`.

---

## 📄 License

MIT — reuse freely with attribution.
Tested on **Bash 5.0+** (Ubuntu, Alpine).