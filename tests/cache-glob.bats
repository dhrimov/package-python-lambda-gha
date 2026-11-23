#!/usr/bin/env bats
#
# Unit tests for cache-glob.sh. Each test builds a small directory tree with
# empty uv.lock files, so these need no uv and no network.

setup() {
  source "$BATS_TEST_DIRNAME/../cache-glob.sh"
  # Resolved, because the helper prints resolved paths: on macOS the temp
  # directory sits behind the /var -> /private/var symlink.
  workspace="$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)/workspace"
  mkdir -p "$workspace"
}

@test "cache_dependency_glob uses the lock in input-path" {
  mkdir -p "$workspace/services/orders"
  touch "$workspace/services/orders/uv.lock"
  run cache_dependency_glob services/orders "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/services/orders/uv.lock" ]
}

@test "cache_dependency_glob uses a parent's lock for a workspace member" {
  mkdir -p "$workspace/mono/lambdas/orders"
  touch "$workspace/mono/uv.lock"
  run cache_dependency_glob mono/lambdas/orders "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/mono/uv.lock" ]
}

@test "cache_dependency_glob uses the nearest lock when there are several" {
  mkdir -p "$workspace/mono/lambdas/orders"
  touch "$workspace/uv.lock" "$workspace/mono/uv.lock"
  run cache_dependency_glob mono/lambdas/orders "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/mono/uv.lock" ]
}

@test "cache_dependency_glob uses the workspace's own lock" {
  mkdir -p "$workspace/lambdas/orders"
  touch "$workspace/uv.lock"
  run cache_dependency_glob lambdas/orders "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/uv.lock" ]
}

@test "cache_dependency_glob handles input-path being the workspace" {
  touch "$workspace/uv.lock"
  run cache_dependency_glob . "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/uv.lock" ]
}

@test "cache_dependency_glob accepts an absolute input-path inside the workspace" {
  mkdir -p "$workspace/lambdas/orders"
  touch "$workspace/uv.lock"
  run cache_dependency_glob "$workspace/lambdas/orders" "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/uv.lock" ]
}

@test "cache_dependency_glob accepts a trailing slash and .. in input-path" {
  mkdir -p "$workspace/lambdas/orders" "$workspace/lambdas/payments"
  touch "$workspace/lambdas/payments/uv.lock"
  run cache_dependency_glob lambdas/orders/../payments/ "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/lambdas/payments/uv.lock" ]
}

@test "cache_dependency_glob checks only input-path itself when it is outside the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/orders"
  touch "$BATS_TEST_TMPDIR/elsewhere/orders/uv.lock"
  outside="$(cd -P "$BATS_TEST_TMPDIR/elsewhere/orders" && pwd -P)"
  run cache_dependency_glob "$outside" "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$outside/uv.lock" ]
}

@test "cache_dependency_glob does not walk up from an input-path outside the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/orders"
  touch "$BATS_TEST_TMPDIR/elsewhere/uv.lock"
  outside="$(cd -P "$BATS_TEST_TMPDIR/elsewhere/orders" && pwd -P)"
  run cache_dependency_glob "$outside" "$workspace"
  [ "$status" -eq 1 ]
  [ "$output" = "$outside/uv.lock" ]
}

@test "cache_dependency_glob escapes glob characters in the path" {
  mkdir -p "$workspace/lambdas/[orders]*?"
  touch "$workspace/uv.lock"
  run cache_dependency_glob "lambdas/[orders]*?" "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/uv.lock" ]

  touch "$workspace/lambdas/[orders]*?/uv.lock"
  run cache_dependency_glob "lambdas/[orders]*?" "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/lambdas/[[]orders][*][?]/uv.lock" ]
}

@test "cache_dependency_glob doubles a backslash in the path" {
  mkdir -p "$workspace/lambdas/or\\ders"
  touch "$workspace/lambdas/or\\ders/uv.lock"
  run cache_dependency_glob "lambdas/or\\ders" "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/lambdas/or\\\\ders/uv.lock" ]
}

@test "cache_dependency_glob falls back to <input-path>/uv.lock when no lock is found" {
  mkdir -p "$workspace/services/orders"
  run cache_dependency_glob services/orders "$workspace"
  [ "$status" -eq 1 ]
  [ "$output" = "$workspace/services/orders/uv.lock" ]
}

@test "cache_dependency_glob does not use a lock above the workspace" {
  mkdir -p "$workspace/services/orders"
  touch "$BATS_TEST_TMPDIR/uv.lock"
  run cache_dependency_glob services/orders "$workspace"
  [ "$status" -eq 1 ]
  [ "$output" = "$workspace/services/orders/uv.lock" ]
}

@test "cache_dependency_glob falls back when input-path does not exist" {
  run cache_dependency_glob services/missing "$workspace"
  [ "$status" -eq 1 ]
  [ "$output" = "$workspace/services/missing/uv.lock" ]
}

@test "cache_dependency_glob keeps an absolute input-path as given in the fallback" {
  run cache_dependency_glob /does/not/exist "$workspace"
  [ "$status" -eq 1 ]
  [ "$output" = "/does/not/exist/uv.lock" ]
}
