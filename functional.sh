#!/usr/bin/env bash
# ==============================================================================
# @file boot/functional.sh
# @brief Functional utilities for Bash 5+: map, filter, reduce, flatten, uniq, etc.
# @since 0.1.0
# @version 1.1.0
# ------------------------------------------------------------------------------
# Provides functional-style utilities for Bash arrays and streams.
# Safe under `set -euo pipefail`. Requires Bash 5+ (nameref support).
# ==============================================================================


# --- Internal guards ----------------------------------------------------------

##**
# Ensure that a given name is callable (function, builtin, keyword, or file).
#
# @param string $1  Name to check.
# @return 0         If callable.
# @return 127       If not callable (prints an error to stderr).
##**
boot::__require_callable() {
  local name="${1:?missing name}"
  if [[ "$(type -t -- "$name" 2>/dev/null)" =~ ^(function|file|builtin|keyword)$ ]]; then
    return 0
  fi
  printf 'boot: error: "%s" not callable\n' "$name" >&2
  return 127
}

##**
# Ensure a variable is a declared indexed array (declare -a).
#
# @param string $1  Variable name.
# @return 0         If indexed array.
# @return 2         If undeclared or not indexed.
##**
boot::__require_array_var() {
  local var="${1:?missing var}"
  local decl
  if ! decl=$(declare -p -- "$var" 2>/dev/null); then
    printf 'boot: error: "%s" not declared\n' "$var" >&2
    return 2
  fi
  if [[ ! "$decl" =~ ^declare\ -a\  ]]; then
    printf 'boot: error: "%s" is not an indexed array\n' "$var" >&2
    return 2
  fi
  return 0
}

##**
# Ensure a string is a valid shell identifier.
#
# @param string $1  Identifier name.
# @return 0         If valid.
# @return 2         If invalid.
##**
boot::__require_ident() {
  local v="${1:?}"
  [[ "$v" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && return 0
  printf 'boot: error: invalid identifier "%s"\n' "$v" >&2
  return 2
}


# --- Core functional utilities ------------------------------------------------

##**
# Apply a callback to each element of an array (value, index).
# Discards the result (side-effect only).
#
# @param string $1  Input array name.
# @param string $2  Callback name.
# @return 0         Always succeeds unless callback fails.
##**
boot::each() {
  local in_name="${1:?missing IN array}" cb="${2:?missing callback}"
  boot::__require_ident "$in_name" && boot::__require_array_var "$in_name" || return $?
  boot::__require_callable "$cb" || return $?

  local -n __in="$in_name"
  local i
  for i in "${!__in[@]}"; do
    "$cb" "${__in[$i]}" "$i" || return $?
  done
}

##**
# Map array through a callback (value, index) -> echo result.
#
# @param string $1  Input array.
# @param string $2  Output array.
# @param string $3  Callback function/command.
# @return 0         Success.
##**
boot::map() {
  local in_name="${1:?}" out_name="${2:?}" cb="${3:?}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name"  || return $?
  boot::__require_ident "$out_name" && boot::__require_callable "$cb"        || return $?

  local -n __in="$in_name" __out="$out_name"
  __out=()
  local i out
  for i in "${!__in[@]}"; do
    if out="$("$cb" "${__in[$i]}" "$i")"; then
      __out+=("$out")
    fi
  done
}

##**
# Filter array using predicate (value, index) -> exit 0 to keep.
#
# @param string $1  Input array.
# @param string $2  Output array.
# @param string $3  Predicate function/command.
# @return 0         Success.
##**
boot::filter() {
  local in_name="${1:?}" out_name="${2:?}" pd="${3:?}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name"  || return $?
  boot::__require_ident "$out_name" && boot::__require_callable "$pd"        || return $?

  local -n __in="$in_name" __out="$out_name"
  __out=()
  local i v
  for i in "${!__in[@]}"; do
    v="${__in[$i]}"
    if "$pd" "$v" "$i"; then
      __out+=("$v")
    fi
  done
}

##**
# Reduce an array to a single value using reducer(acc, value) -> echo new_acc.
#
# @param string $1  Input array.
# @param string $2  Initial accumulator.
# @param string $3  Output scalar name.
# @param string $4  Reducer function.
# @return 0         Success.
##**
boot::reduce() {
  local in_name="${1:?}" acc="${2:?}" out_name="${3:?}" rd="${4:?}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name" || return $?
  boot::__require_ident "$out_name" && boot::__require_callable "$rd"       || return $?

  local -n __in="$in_name" __out="$out_name"
  local v
  for v in "${__in[@]}"; do
    acc="$("$rd" "$acc" "$v")" || return $?
  done
  __out="$acc"
}

##**
# Return the first element that matches a predicate (value, index).
#
# @param string $1  Input array.
# @param string $2  Predicate function/command.
# @return string    First matching value printed to stdout.
# @return 1         If no match found.
##**
boot::find() {
  local in_name="${1:?}" pd="${2:?}"
  boot::__require_ident "$in_name" && boot::__require_array_var "$in_name" || return $?
  boot::__require_callable "$pd" || return $?

  local -n __in="$in_name"
  local i v
  for i in "${!__in[@]}"; do
    v="${__in[$i]}"
    if "$pd" "$v" "$i"; then
      printf '%s\n' "$v"
      return 0
    fi
  done
  return 1
}

##**
# Check if any element satisfies the predicate.
#
# @param string $1  Input array.
# @param string $2  Predicate function/command.
# @return 0         If at least one matches.
# @return 1         Otherwise.
##**
boot::some() {
  local in_name="${1:?}" pd="${2:?}"
  boot::__require_ident "$in_name" && boot::__require_array_var "$in_name" || return $?
  boot::__require_callable "$pd" || return $?
  local -n __in="$in_name"
  local i v
  for i in "${!__in[@]}"; do
    v="${__in[$i]}"
    "$pd" "$v" "$i" && return 0
  done
  return 1
}

##**
# Check if all elements satisfy the predicate.
#
# @param string $1  Input array.
# @param string $2  Predicate function/command.
# @return 0         If all match.
# @return 1         If any fails.
##**
boot::every() {
  local in_name="${1:?}" pd="${2:?}"
  boot::__require_ident "$in_name" && boot::__require_array_var "$in_name" || return $?
  boot::__require_callable "$pd" || return $?
  local -n __in="$in_name"
  local i v
  for i in "${!__in[@]}"; do
    v="${__in[$i]}"
    if ! "$pd" "$v" "$i"; then
      return 1
    fi
  done
}

##**
# Flatten nested arrays into a single-level array.
#
# @param string $1  Input array.
# @param string $2  Output array.
# @return 0         Success.
##**
boot::flatten() {
  local in_name="${1:?}" out_name="${2:?}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name" || return $?
  boot::__require_ident "$out_name" || return $?

  local -n __in="$in_name" __out="$out_name"
  __out=()
  local v
  for v in "${__in[@]}"; do
    if [[ "$v" =~ ^\(.*\)$ ]]; then
      eval "local -a tmp=$v"
      __out+=("${tmp[@]}")
    else
      __out+=("$v")
    fi
  done
}

##**
# Remove duplicate elements from an array.
#
# @param string $1  Input array.
# @param string $2  Output array.
# @return 0         Success.
##**
boot::uniq() {
  local in_name="${1:?}" out_name="${2:?}"
  boot::__require_ident "$in_name"  && boot::__require_array_var "$in_name" || return $?
  boot::__require_ident "$out_name" || return $?

  local -n __in="$in_name" __out="$out_name"
  __out=()
  declare -A seen=()
  local v
  for v in "${__in[@]}"; do
    if [[ -z "${seen[$v]:-}" ]]; then
      seen["$v"]=1
      __out+=("$v")
    fi
  done
}

##**
# Join array elements with a delimiter.
#
# @param string $1  Input array.
# @param string $2  Delimiter string.
# @return string    Joined string printed to stdout.
##**
boot::join() {
  local in_name="${1:?}" delim="${2:- }"
  boot::__require_ident "$in_name" && boot::__require_array_var "$in_name" || return $?
  local -n __in="$in_name"
  local IFS="$delim"
  printf '%s\n' "${__in[*]}"
}
