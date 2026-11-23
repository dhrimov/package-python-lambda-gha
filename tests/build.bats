#!/usr/bin/env bats
#
# Unit tests for build.sh's pure helpers. Sourcing the script defines its
# functions without running the pipeline, so these take milliseconds and need
# no uv, no network and no fixture.

setup() {
  source "$BATS_TEST_DIRNAME/../build.sh"
}

# --- platform_architecture ---

@test "platform_architecture maps the arm64 platform" {
  run platform_architecture aarch64-manylinux2014
  [ "$status" -eq 0 ]
  [ "$output" = "arm64" ]
}

@test "platform_architecture maps the x86_64 platform" {
  run platform_architecture x86_64-manylinux2014
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64" ]
}

@test "platform_architecture maps the arm64 manylinux_2_28 platform" {
  run platform_architecture aarch64-manylinux_2_28
  [ "$status" -eq 0 ]
  [ "$output" = "arm64" ]
}

@test "platform_architecture maps the x86_64 manylinux_2_28 platform" {
  run platform_architecture x86_64-manylinux_2_28
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64" ]
}

@test "platform_architecture maps the arm64 manylinux_2_34 platform" {
  run platform_architecture aarch64-manylinux_2_34
  [ "$status" -eq 0 ]
  [ "$output" = "arm64" ]
}

@test "platform_architecture maps the x86_64 manylinux_2_34 platform" {
  run platform_architecture x86_64-manylinux_2_34
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64" ]
}

@test "platform_architecture rejects a manylinux variant we do not support" {
  run platform_architecture aarch64-manylinux_2_31
  [ "$status" -ne 0 ]
}

@test "platform_architecture rejects a bare architecture" {
  run platform_architecture arm64
  [ "$status" -ne 0 ]
}

@test "platform_architecture rejects an empty platform" {
  run platform_architecture ""
  [ "$status" -ne 0 ]
}

@test "platform_architecture rejects two platforms in one value" {
  run platform_architecture "aarch64-manylinux2014 x86_64-manylinux2014"
  [ "$status" -ne 0 ]
}

@test "platform_architecture maps every supported platform" {
  for platform in $SUPPORTED_PLATFORMS; do
    run platform_architecture "$platform"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
}

# --- platform_supports_python ---

@test "platform_supports_python rejects 3.11 with every newer-glibc platform" {
  for platform in aarch64-manylinux_2_28 x86_64-manylinux_2_28 aarch64-manylinux_2_34 x86_64-manylinux_2_34; do
    run platform_supports_python "$platform" 3.11
    [ "$status" -ne 0 ]
  done
}

@test "platform_supports_python accepts 3.12 with a newer-glibc platform" {
  run platform_supports_python aarch64-manylinux_2_34 3.12
  [ "$status" -eq 0 ]
}

@test "platform_supports_python accepts 3.11 with manylinux2014" {
  run platform_supports_python aarch64-manylinux2014 3.11
  [ "$status" -eq 0 ]
}

# --- python_version_runtime ---

@test "python_version_runtime names the AWS runtime for every supported version" {
  for version in $SUPPORTED_PYTHON_VERSIONS; do
    run python_version_runtime "$version"
    [ "$status" -eq 0 ]
    [ "$output" = "python$version" ]
  done
}

@test "python_version_runtime rejects a deprecated runtime" {
  run python_version_runtime 3.10
  [ "$status" -ne 0 ]
}

@test "python_version_runtime rejects a preview runtime" {
  run python_version_runtime 3.15
  [ "$status" -ne 0 ]
}

@test "python_version_runtime rejects a runtime-prefixed value" {
  run python_version_runtime python3.13
  [ "$status" -ne 0 ]
}

@test "python_version_runtime rejects a patch version" {
  run python_version_runtime 3.13.1
  [ "$status" -ne 0 ]
}

@test "python_version_runtime rejects two versions in one value" {
  run python_version_runtime "3.12 3.13"
  [ "$status" -ne 0 ]
}

# --- python_version_deprecation_date ---

@test "python_version_deprecation_date dates the last Amazon Linux 2 runtime" {
  run python_version_deprecation_date 3.11
  [ "$status" -eq 0 ]
  [ "$output" = "2027-06-30" ]
}

@test "python_version_deprecation_date says nothing for a current runtime" {
  run python_version_deprecation_date 3.13
  [ "$status" -ne 0 ]
  [ "$output" = "" ]
}

# --- source_date_epoch_is_valid ---

@test "source_date_epoch_is_valid accepts the zip epoch itself" {
  run source_date_epoch_is_valid 315532800
  [ "$status" -eq 0 ]
}

@test "source_date_epoch_is_valid accepts a present-day timestamp" {
  run source_date_epoch_is_valid 1780000000
  [ "$status" -eq 0 ]
}

@test "source_date_epoch_is_valid rejects a timestamp before the zip epoch" {
  run source_date_epoch_is_valid 315532799
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects zero" {
  run source_date_epoch_is_valid 0
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects a negative timestamp" {
  run source_date_epoch_is_valid -1
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects a non-integer" {
  run source_date_epoch_is_valid 1780000000.5
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects a non-number" {
  run source_date_epoch_is_valid yesterday
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid rejects an empty value" {
  run source_date_epoch_is_valid ""
  [ "$status" -ne 0 ]
}

@test "source_date_epoch_is_valid reads a zero-padded value as decimal, not octal" {
  run source_date_epoch_is_valid 0315532800
  [ "$status" -eq 0 ]
}

# --- format_bytes ---

@test "format_bytes leaves small counts in bytes" {
  run format_bytes 0
  [ "$output" = "0 B" ]
  run format_bytes 1023
  [ "$output" = "1023 B" ]
}

@test "format_bytes switches to KiB at the boundary" {
  run format_bytes 1024
  [ "$output" = "1.0 KiB" ]
}

@test "format_bytes formats a realistic zip size" {
  run format_bytes 130169
  [ "$output" = "127.1 KiB" ]
}

@test "format_bytes formats AWS's unzipped limit as a round 250 MiB" {
  run format_bytes "$AWS_LAMBDA_MAX_UNZIP_SIZE"
  [ "$output" = "250.0 MiB" ]
}

@test "format_bytes stops at GiB rather than making up a larger unit" {
  run format_bytes $((5 * 1024 * 1024 * 1024))
  [ "$output" = "5.0 GiB" ]
}

# --- path_contains ---

@test "path_contains counts a path as containing itself" {
  run path_contains /work/build /work/build
  [ "$status" -eq 0 ]
}

@test "path_contains finds a child several levels down" {
  run path_contains /work /work/services/orders
  [ "$status" -eq 0 ]
}

@test "path_contains treats the filesystem root as containing everything" {
  run path_contains / /work/build
  [ "$status" -eq 0 ]
}

@test "path_contains does not match a sibling that only shares a prefix" {
  run path_contains /work/build /work/build2
  [ "$status" -ne 0 ]
}

@test "path_contains does not count a child as containing its parent" {
  run path_contains /work/build /work
  [ "$status" -ne 0 ]
}

@test "path_contains does not match unrelated paths" {
  run path_contains /tmp/build /work/services/orders
  [ "$status" -ne 0 ]
}

# --- uv_version_is_supported ---

@test "uv_version_is_supported rejects a version older than the floor" {
  run uv_version_is_supported "uv 0.9.30"
  [ "$status" -ne 0 ]
}

@test "uv_version_is_supported accepts the floor itself" {
  run uv_version_is_supported "uv 0.10.0"
  [ "$status" -eq 0 ]
}

@test "uv_version_is_supported accepts a newer version" {
  run uv_version_is_supported "uv 1.2.3"
  [ "$status" -eq 0 ]
}

@test "uv_version_is_supported compares numbers, not text" {
  run uv_version_is_supported "uv 0.9.100"
  [ "$status" -ne 0 ]
  run uv_version_is_supported "uv 0.100.0"
  [ "$status" -eq 0 ]
}

@test "uv_version_is_supported ignores a pre-release suffix" {
  run uv_version_is_supported "uv 0.11.0-rc.1"
  [ "$status" -eq 0 ]
}

@test "uv_version_is_supported ignores a trailing build note" {
  run uv_version_is_supported "uv 0.13.6 (Homebrew 2026-10-26 aarch64-apple-darwin)"
  [ "$status" -eq 0 ]
}

@test "uv_version_is_supported rejects text with no version in it" {
  run uv_version_is_supported "uv"
  [ "$status" -ne 0 ]
}

# --- local_package_paths ---

@test "local_package_paths prints nothing when there are no local packages" {
  run local_package_paths "$(printf '%s\n' \
    '# This file was autogenerated by uv via the following command:' \
    '#    uv export --frozen --no-dev --no-editable --no-emit-project --no-hashes' \
    'orjson==3.12.0' \
    '    # via single-lambda')"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "local_package_paths prints nothing for an empty export" {
  run local_package_paths ""
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "local_package_paths finds one local package" {
  run local_package_paths "$(printf '%s\n' './libs/common' '    # via orders-lambda' 'orjson==3.12.0')"
  [ "$status" -eq 0 ]
  [ "$output" = "./libs/common" ]
}

@test "local_package_paths finds the workspace root's package as a bare ." {
  run local_package_paths "$(printf '%s\n' '.' '    # via member' 'orjson==3.12.0')"
  [ "$status" -eq 0 ]
  [ "$output" = "." ]
}

@test "local_package_paths finds a path dependency on the parent as a bare .." {
  run local_package_paths "$(printf '%s\n' '..' '    # via app' 'orjson==3.12.0')"
  [ "$status" -eq 0 ]
  [ "$output" = ".." ]
}

@test "local_package_paths finds transitive local packages, in export order" {
  run local_package_paths "$(printf '%s\n' \
    './libs/common' \
    '    # via orders-lambda' \
    './libs/core' \
    '    # via common' \
    'orjson==3.12.0')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' ./libs/common ./libs/core)" ]
}

@test "local_package_paths prints each local package once" {
  run local_package_paths "$(printf '%s\n' './libs/common' './libs/core' './libs/common')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' ./libs/common ./libs/core)" ]
}

@test "local_package_paths keeps spaces in a path" {
  run local_package_paths "$(printf '%s\n' './shared libs/common' 'orjson==3.12.0')"
  [ "$status" -eq 0 ]
  [ "$output" = "./shared libs/common" ]
}

@test "local_package_paths finds a path outside the workspace root" {
  run local_package_paths "$(printf '%s\n' '../vendored/common' 'orjson==3.12.0')"
  [ "$status" -eq 0 ]
  [ "$output" = "../vendored/common" ]
}

@test "local_package_paths ignores third-party lines, markers included" {
  run local_package_paths "$(printf '%s\n' \
    "colorama==0.4.6 ; sys_platform == 'win32'" \
    'pydantic==2.11.7' \
    '--index-url https://pypi.org/simple' \
    '    # via ./libs/common')"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "local_package_paths refuses a local package with an environment marker" {
  run local_package_paths "$(printf '%s\n' './libs/common' "./libs/winonly ; sys_platform == 'win32'")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment marker"* ]]
  [[ "$output" == *"./libs/winonly ; sys_platform == 'win32'"* ]]
}

@test "local_package_paths refuses an absolute path" {
  run local_package_paths "$(printf '%s\n' 'file:///opt/libs/common')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute"* ]]
  [[ "$output" == *"file:///opt/libs/common"* ]]
}

@test "local_package_paths refuses a wheel file" {
  run local_package_paths "$(printf '%s\n' './wheels/common-1.0.0-py3-none-any.whl')"
  [ "$status" -ne 0 ]
  [[ "$output" == *".whl"* ]]
  [[ "$output" == *"./wheels/common-1.0.0-py3-none-any.whl"* ]]
}

@test "local_package_paths refuses an absolute path written as a named URL" {
  run local_package_paths "$(printf '%s\n' 'common @ file:///opt/libs/common')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute"* ]]
}

@test "local_package_paths refuses an editable local package" {
  run local_package_paths "$(printf '%s\n' '-e ./libs/common')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"editable"* ]]
  [[ "$output" == *"-e ./libs/common"* ]]
}

@test "local_package_paths refuses a line it does not recognise" {
  run local_package_paths "$(printf '%s\n' './libs/common' 'libs/core')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not recognised"* ]]
  [[ "$output" == *"libs/core"* ]]
}

@test "local_package_paths prints only the reason when it fails" {
  run local_package_paths "$(printf '%s\n' './libs/common' './wheels/core-1.0.0-py3-none-any.whl')"
  [ "$status" -ne 0 ]
  [[ "$output" != *"./libs/common"* ]]
}

@test "local_package_paths accepts direct URL and blank lines" {
  run local_package_paths "$(printf '%s\n' \
    'requests @ git+https://github.com/psf/requests@v2.32.3' \
    '' \
    'Django[argon2]==5.1.4' \
    './libs/common')"
  [ "$status" -eq 0 ]
  [ "$output" = "./libs/common" ]
}

# --- fail and die ---

@test "fail closes an open group before it prints the error" {
  group "a step"
  run fail "boom"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "::endgroup::" ]
  [ "${lines[1]}" = "::error::boom" ]
}

@test "fail prints no endgroup when no group is open" {
  run fail "boom"
  [ "$status" -eq 1 ]
  [ "$output" = "::error::boom" ]
}

@test "die closes an open group before it prints the error" {
  group "a step"
  run die "boom"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "::endgroup::" ]
  [ "${lines[1]}" = "error: boom" ]
}

@test "die prints no endgroup when no group is open" {
  run die "boom"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "error: boom" ]
}

# --- the uv floor in the docs and the e2e suite ---

@test "the uv floor in action.yml, README.md and the uv-floor e2e job matches MIN_UV_VERSION" {
  local root="$BATS_TEST_DIRNAME/.."
  grep -qF "uv version to install, $MIN_UV_VERSION or later." "$root/action.yml"
  grep -qF "uv version to install, \`$MIN_UV_VERSION\` or later." "$root/README.md"
  grep -qF "uv-version: [\"$MIN_UV_VERSION\"]" "$root/.github/workflows/e2e.yml"
}

# --- the supported runtimes and platforms in the docs and the e2e suite ---

# Joins the words of $1 the way the README does: `a`, `b`, or `c`.
readme_list() {
  local item list="" last="${1##* }"
  for item in $1; do
    if [[ "$item" == "$last" ]]; then
      list+="or \`$item\`"
    else
      list+="\`$item\`, "
    fi
  done
  printf '%s' "$list"
}

@test "the Python versions in action.yml, README.md and the e2e suite match SUPPORTED_PYTHON_VERSIONS" {
  local root="$BATS_TEST_DIRNAME/.."
  local quoted="\"${SUPPORTED_PYTHON_VERSIONS// /\", \"}\""
  grep -qF "one of ${SUPPORTED_PYTHON_VERSIONS// /, }." "$root/action.yml"
  grep -qF "Target AWS Lambda Python runtime: $(readme_list "$SUPPORTED_PYTHON_VERSIONS")." "$root/README.md"
  grep -qF "\`${SUPPORTED_PYTHON_VERSIONS// /\`, \`}\`. Anything else fails." "$root/README.md"
  grep -qF "python-version: [$quoted]" "$root/.github/workflows/e2e.yml"
}

@test "the platforms in action.yml, README.md, usage and the e2e suite match SUPPORTED_PLATFORMS" {
  local root="$BATS_TEST_DIRNAME/.."
  # The action.yml description is folded over several lines.
  tr -s ' \n' ' ' <"$root/action.yml" |
    grep -qF "uv target platform, one of ${SUPPORTED_PLATFORMS// /, }."
  grep -qF "uv target platform: $(readme_list "$SUPPORTED_PLATFORMS")." "$root/README.md"
  local usage_text platform
  usage_text="$(usage)"
  for platform in $SUPPORTED_PLATFORMS; do
    grep -qF "$platform" <<<"$usage_text"
    grep -qE "^ +- $platform\$|platform: \[(.*, )?$platform(, .*)?\]" "$root/.github/workflows/e2e.yml"
  done
}
