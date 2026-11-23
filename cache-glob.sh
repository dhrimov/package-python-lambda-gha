#!/usr/bin/env bash
#
# The cache-dependency-glob that action.yml passes to setup-uv.
#
# A uv workspace member has no uv.lock of its own: the lock sits at the
# workspace root, somewhere above input-path. If the glob matches no file,
# setup-uv uses a fixed cache key, saves the cache once and never updates it.
# action.yml sources this file before setup-uv runs, so it can't use build.sh
# or uv. tests/cache-glob.bats sources it the same way. It has no set -euo
# pipefail of its own, because it is only ever sourced.

# Turns a path into a glob that matches only that path. setup-uv hands the glob to
# @actions/glob, where *, ? and [ are special, and wrapping one in [] makes it
# literal. On Linux \ is special too - it is the escape character - so it
# gets doubled. Braces and extglobs are not: @actions/glob turns both off.
glob_escape() {
  local path="$1" escaped="" char i
  for ((i = 0; i < ${#path}; i++)); do
    char="${path:i:1}"
    case "$char" in
      '*' | '?' | '[') escaped+="[$char]" ;;
      '\') escaped+='\\' ;;
      *) escaped+="$char" ;;
    esac
  done
  printf '%s' "$escaped"
}

# Prints the nearest uv.lock at or above input-path as an escaped, absolute
# glob. It never looks above the workspace. The glob is absolute so it does
# not depend on which directory setup-uv resolves relative globs against.
#
# If input-path is outside the workspace, only its own directory is checked.
# If no lock is found, it prints <input-path>/uv.lock and returns 1, so the
# caller can say so. setup-uv then warns about the missing file.
cache_dependency_glob() {
  local input="$1" workspace dir fallback="$1/uv.lock"
  if ! workspace="$(cd -P "$2" 2>/dev/null && pwd -P)"; then
    glob_escape "$fallback"
    return 1
  fi
  if [[ "$input" != /* ]]; then
    fallback="$workspace/$fallback"
  fi
  if ! dir="$(cd "$workspace" && cd -P "$input" 2>/dev/null && pwd -P)"; then
    glob_escape "$fallback"
    return 1
  fi

  while :; do
    if [[ -f "$dir/uv.lock" ]]; then
      glob_escape "$dir/uv.lock"
      return 0
    fi
    [[ "$dir" == "$workspace"/* ]] || break
    dir="${dir%/*}"
  done

  glob_escape "$fallback"
  return 1
}
