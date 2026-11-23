#!/usr/bin/env bash
#
# Package a Python project into an AWS Lambda deployment zip.
#
#   build.sh --input <dir> --output <dir> --python <version> --platform <platform>
#
# Builds the project as a wheel, plus a wheel for each local package it depends
# on - uv workspace members and path dependencies. Installs them with
# the locked third-party dependencies into a throwaway venv built for the
# Lambda platform. Then hands that venv to package-python-function, which
# writes a reproducible zip named after the project.
#
# Everything that talks to GitHub Actions lives here rather than in action.yml:
# the runner guard, the input checks, the collapsible ::group:: sections,
# and the $GITHUB_OUTPUT writes. Sourcing this file defines its functions
# without running the pipeline, which is how the bats suite tests the pure
# helpers below.

set -euo pipefail

# --- constants --------------------------------------------------------------

DEFAULT_PACKAGER_VERSION="1.0.0"

# AWS Lambda's unzipped deployment package limit, in bytes: exactly 250 MiB.
AWS_LAMBDA_MAX_UNZIP_SIZE=262144000

# The zip format's own epoch, 1980-01-01T00:00:00Z. No timestamp below it can
# be stored in a zip entry, so no SOURCE_DATE_EPOCH below it is usable.
MIN_SOURCE_DATE_EPOCH=315532800

# The AWS Lambda Python runtimes this action supports, checked by hand against
# AWS's Lambda runtimes docs. There is no API to ask for the supported set, so
# this list needs an edit whenever AWS adds a version.
SUPPORTED_PYTHON_VERSIONS="3.11 3.12 3.13 3.14"

# The oldest uv that has every command and flag the pipeline uses. The newest
# one is `uv workspace dir`, stable since 0.10.0.
MIN_UV_VERSION="0.10.0"

# --- pure helpers -----------------------------------------------------------
#
# Everything in this section depends only on its arguments, so the bats suite
# can source this file and call it directly.

# The Lambda CPU architecture a uv target platform builds for. Doubles as the
# platform allow-list: an unsupported platform has no architecture to name.
platform_architecture() {
  case "$1" in
    aarch64-manylinux2014 | aarch64-manylinux_2_28 | aarch64-manylinux_2_34) printf 'arm64' ;;
    x86_64-manylinux2014 | x86_64-manylinux_2_28 | x86_64-manylinux_2_34) printf 'x86_64' ;;
    *) return 1 ;;
  esac
}

# Whether a target Python version's Lambda runtime can load wheels built for a
# platform. 3.11 is the one runtime on Amazon Linux 2, whose glibc 2.26 is too
# old for manylinux_2_28 and manylinux_2_34 wheels. 3.12 and later run on
# Amazon Linux 2023, glibc 2.34, which loads all of them. A package built for
# the wrong pair still deploys, and only fails when the function imports it.
platform_supports_python() {
  case "$1:$2" in
    *-manylinux_2_28:3.11 | *-manylinux_2_34:3.11) return 1 ;;
    *) return 0 ;;
  esac
}

# The AWS Lambda runtime identifier for a target Python version, e.g.
# 3.13 -> python3.13. Fails for any version outside the supported set.
python_version_runtime() {
  case " $SUPPORTED_PYTHON_VERSIONS " in
    *" $1 "*) printf 'python%s' "$1" ;;
    *) return 1 ;;
  esac
}

# The date AWS retires a runtime that still works but is on its way out, or
# failure for one with no announced end. 3.11 is the last Amazon Linux 2 Python
# runtime. It warns rather than fails: AWS still supports it, and this action's
# job is catching drift the caller didn't mean to introduce, not pushing an
# upgrade schedule. (Amazon Linux 2's own EOL, Jun 30 2026, is a different date
# and is not a runtime deprecation.)
python_version_deprecation_date() {
  case "$1" in
    3.11) printf '2027-06-30' ;;
    *) return 1 ;;
  esac
}

# Whether a SOURCE_DATE_EPOCH value is usable: a non-negative integer no
# earlier than the zip epoch. The packager checks it too, but it runs last, so
# a bad value would otherwise cost a full venv build first.
source_date_epoch_is_valid() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  ((10#$1 >= MIN_SOURCE_DATE_EPOCH))
}

# Whether the output of `uv --version` names MIN_UV_VERSION or newer. Only the
# second field is read, so a build note after it, like Homebrew's, is ignored.
# Only the three numbers are compared, so a pre-release suffix is ignored too.
uv_version_is_supported() {
  local version
  read -r _ version _ <<<"$1"
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  local have=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

  local want
  IFS=. read -r -a want <<<"$MIN_UV_VERSION"

  local i
  for i in 0 1 2; do
    ((10#${have[i]} > 10#${want[i]})) && return 0
    ((10#${have[i]} < 10#${want[i]})) && return 1
  done
  return 0
}

# A third-party line in a uv export: a name, optional extras, then a pinned
# version or a direct URL, with an optional marker after it.
THIRD_PARTY_LINE='^[A-Za-z0-9][A-Za-z0-9._-]*(\[[^]]*\])?(==| @ )'

# Prints the local packages in a closure export (uv export --no-emit-project
# --no-hashes), one per line, with each path relative to the workspace root as
# uv wrote it. uv writes a local package as a bare path, so a line that is
# . or .., or starts with ./ or ../, is one, and the whole line is the path,
# spaces included. A bare . is the workspace root's own package. Third-party lines, comments, options and blank lines are skipped.
#
# On failure it prints only the reason and returns 1, so the caller can pass
# that to fail. It fails on local packages the pipeline can't build into a
# wheel and install: an editable one, a path with an environment marker, an
# absolute path (uv writes those as file:// URLs), and a .whl file. It also
# fails on any line it does not recognise. That way a change in uv's export
# format stops the build here instead of quietly leaving a local package out.
local_package_paths() {
  local line seen found=()
  while IFS= read -r line; do
    if [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    case "$line" in
      -e\ * | --editable*)
        printf 'editable local dependency is not supported: %s' "$line"
        return 1
        ;;
      -*) continue ;;
      file://* | *" @ file://"*)
        printf 'local dependency with an absolute path is not supported: %s. %s' \
          "$line" "Make it a path relative to the workspace root."
        return 1
        ;;
      . | .. | ./* | ../*) ;;
      *)
        [[ "$line" =~ $THIRD_PARTY_LINE ]] && continue
        printf 'line in the uv export output not recognised: %s' "$line"
        return 1
        ;;
    esac
    if [[ "$line" == *" ;"* ]]; then
      printf 'local dependency with an environment marker is not supported: %s' "$line"
      return 1
    fi
    if [[ "$line" == *.whl ]]; then
      printf 'local dependency on a .whl file is not supported: %s' "$line"
      return 1
    fi

    for seen in ${found[@]+"${found[@]}"}; do
      [[ "$seen" != "$line" ]] || continue 2
    done
    found+=("$line")
  done <<<"$1"

  if ((${#found[@]} > 0)); then
    printf '%s\n' "${found[@]}"
  fi
}

# Whether the first path is the second one or one of its parents. Both must
# already be resolved to absolute paths: this compares strings, and does not
# follow symlinks. The trailing slash is stripped first so that / still works.
path_contains() {
  [[ "$1" == "$2" || "$2" == "${1%/}"/* ]]
}

# A byte count in the nearest binary unit with one decimal place, e.g.
# 130169 -> "127.1 KiB". For reading only, never parsed.
format_bytes() {
  local bytes="$1"
  if ((bytes < 1024)); then
    printf '%d B' "$bytes"
    return 0
  fi

  local units=(KiB MiB GiB)
  local index=0
  local scale=1024
  while ((index < ${#units[@]} - 1 && bytes >= scale * 1024)); do
    scale=$((scale * 1024))
    index=$((index + 1))
  done

  printf '%d.%d %s' $((bytes / scale)) $((bytes * 10 / scale % 10)) "${units[index]}"
}

# --- logging ----------------------------------------------------------------

log() {
  printf '\n==> %s\n' "$*"
}

# Pipeline stages become collapsible sections in the Actions log. IN_GROUP
# lets fail and die close an open section before they print the error.
IN_GROUP=false

group() {
  printf '\n::group::%s\n' "$*"
  IN_GROUP=true
}

endgroup() {
  printf '::endgroup::\n'
  IN_GROUP=false
}

warn() {
  printf '::warning::%s\n' "$*" >&2
}

usage() {
  cat <<EOF
Usage: ${0##*/} --input <dir> --output <dir> --python <version> --platform <platform>
                [--build-dir <dir>] [--packager-version <version>]
                [--fail-on-non-linux <true|false>]

  --input      directory containing the project's pyproject.toml
  --output     directory to write the zip into (created if missing)
  --python     Python version to build against, one of:
               $SUPPORTED_PYTHON_VERSIONS
  --platform   uv target platform, one of: aarch64-manylinux2014,
               x86_64-manylinux2014, aarch64-manylinux_2_28,
               x86_64-manylinux_2_28, aarch64-manylinux_2_34,
               x86_64-manylinux_2_34. The manylinux_2_28 and
               manylinux_2_34 ones need --python 3.12 or later.
  --build-dir  scratch directory for intermediates, which build.sh takes over
               completely: it is deleted, not emptied, before and after every
               build. Never point it at a directory holding anything you want
               to keep, and never share it between builds running at the same
               time - each one deletes the other's work in progress. It can't
               be a symlink, and it can't be or contain the input or output
               directory, \$RUNNER_TEMP, \$HOME or \$GITHUB_ACTION_PATH.
               Symlinks further up the path are followed before that check.
               Defaults to <input>/build, on the same terms.
  --packager-version
               package-python-function version to package with. Defaults to
               $DEFAULT_PACKAGER_VERSION. Earlier releases are 0.0.x with no
               --report flag, and are not checked for: an older pin fails at
               the packaging step, after the venv is built.
  --fail-on-non-linux
               refuse to run on a non-Linux GitHub Actions runner. Linux
               runners are the only ones this action is tested on. Defaults
               to true.

The first four are required: a default platform would quietly pick the
architecture of every compiled dependency in the package.

Example:
  ${0##*/} --input . --output terraform --python 3.13 --platform aarch64-manylinux2014
EOF
}

# A usage error: the caller passed the wrong flags. Any open log section is
# closed first, as in fail.
die() {
  if [[ "$IN_GROUP" == true ]]; then
    endgroup
  fi
  echo "error: $*" >&2
  usage >&2
  exit 1
}

# A validation error: the flags parse, but the build they ask for cannot work.
# Annotated so it shows up on the Actions job summary and not only in the log.
# The guard rails raise it before any uv work starts. The pipeline steps also
# raise it, for checks where uv does not annotate the failure itself. Any open
# log section is closed first, so the error is not hidden inside it.
fail() {
  if [[ "$IN_GROUP" == true ]]; then
    endgroup
  fi
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# The zip's SHA-256, lowercase hex. sha256sum ships with coreutils and is
# always there on the Linux runners this action targets. The shasum fallback
# keeps the script runnable on a macOS dev machine.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- main -------------------------------------------------------------------

main() {
  INPUT=""
  OUTPUT=""
  PYTHON_VERSION=""
  PLATFORM=""
  BUILD_DIR=""
  PACKAGER_VERSION="$DEFAULT_PACKAGER_VERSION"
  FAIL_ON_NON_LINUX="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --input | --output | --python | --platform | --build-dir | --packager-version | --fail-on-non-linux)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        case "$1" in
          --input) INPUT="$2" ;;
          --output) OUTPUT="$2" ;;
          --python) PYTHON_VERSION="$2" ;;
          --platform) PLATFORM="$2" ;;
          --build-dir) BUILD_DIR="$2" ;;
          --packager-version) PACKAGER_VERSION="$2" ;;
          --fail-on-non-linux) FAIL_ON_NON_LINUX="$2" ;;
        esac
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$INPUT" ]] || die "missing --input"
  [[ -n "$OUTPUT" ]] || die "missing --output"
  [[ -n "$PYTHON_VERSION" ]] || die "missing --python"
  [[ -n "$PLATFORM" ]] || die "missing --platform"
  [[ -n "$PACKAGER_VERSION" ]] || die "missing --packager-version"

  case "$FAIL_ON_NON_LINUX" in
    true | false) ;;
    *) die "--fail-on-non-linux must be true or false, got: $FAIL_ON_NON_LINUX" ;;
  esac

  # --- guard rails ---
  #
  # Everything below runs before the first uv call, so a build that cannot work
  # fails in seconds rather than after a full venv install.

  # RUNNER_OS is set by GitHub Actions and unset for a local run, where there
  # is no runner to refuse.
  if [[ "$FAIL_ON_NON_LINUX" == "true" && -n "${RUNNER_OS:-}" && "$RUNNER_OS" != "Linux" ]]; then
    fail "this action packages Lambda zips on Linux runners only, but RUNNER_OS is $RUNNER_OS." \
      "Linux runners are the only ones this action is tested on, and a build that goes wrong on" \
      "another one goes wrong quietly: a package that deploys fine and then breaks at Lambda" \
      "runtime. Set fail-on-non-linux: false to override."
  fi

  local architecture
  architecture="$(platform_architecture "$PLATFORM")" ||
    fail "unsupported platform: $PLATFORM. Expected one of: aarch64-manylinux2014," \
      "x86_64-manylinux2014, aarch64-manylinux_2_28, x86_64-manylinux_2_28," \
      "aarch64-manylinux_2_34, x86_64-manylinux_2_34."

  local runtime
  runtime="$(python_version_runtime "$PYTHON_VERSION")" ||
    fail "unsupported python-version: $PYTHON_VERSION. Expected one of: $SUPPORTED_PYTHON_VERSIONS."

  platform_supports_python "$PLATFORM" "$PYTHON_VERSION" ||
    fail "$runtime runs on Amazon Linux 2 (glibc 2.26), which cannot load manylinux_2_28 or" \
      "manylinux_2_34 wheels. Use ${PLATFORM%%-*}-manylinux2014, or python-version 3.12 or later."

  local deprecation_date
  if deprecation_date="$(python_version_deprecation_date "$PYTHON_VERSION")"; then
    warn "$runtime is on its way out: AWS retires it on $deprecation_date." \
      "Packaging carries on - it is still a supported runtime today."
  fi

  # Passed through untouched rather than unset or overridden, so a caller who
  # set it on purpose keeps it working.
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]] && ! source_date_epoch_is_valid "$SOURCE_DATE_EPOCH"; then
    fail "SOURCE_DATE_EPOCH must be an integer >= $MIN_SOURCE_DATE_EPOCH (1980-01-01, the zip" \
      "format's epoch), got: $SOURCE_DATE_EPOCH"
  fi

  # jq reads the packager's report. All three come preinstalled on the
  # GitHub-hosted runners, so this check is really for local runs.
  local tool
  for tool in uv uvx jq; do
    command -v "$tool" >/dev/null 2>&1 ||
      die "required tool not found on PATH: $tool"
  done

  [[ -f "$INPUT/pyproject.toml" ]] || die "no pyproject.toml in: $INPUT"

  # Resolve every path now, so the uv --directory below cannot shift them.
  # Every path is resolved with cd -P and pwd -P, so the build-dir checks below
  # compare real locations: through a symlink, two different strings can name
  # one directory. Plain cd is not enough, because it collapses .. by text:
  # with hop -> /real/child, it turns hop/../x into ./x, while the filesystem
  # checks (-f, -L, mkdir) look at /real/x.
  # The two that may need creating go through $resolved, so a failure still
  # has the path the caller asked for to report.
  INPUT="$(cd -P "$INPUT" && pwd -P)"
  local resolved
  resolved="$(mkdir -p "$OUTPUT" && cd -P "$OUTPUT" && pwd -P)" ||
    fail "cannot create output-path: $OUTPUT"
  OUTPUT="$resolved"

  : "${BUILD_DIR:=$INPUT/build}"
  # Checked before pwd -P below swaps the link for its target: cleanup would
  # then delete the target's contents, where rm -rf on the link removes only
  # the link. A trailing / or /. makes -L follow the link and miss it, so
  # those are stripped first, as many times as they repeat.
  local link_check="$BUILD_DIR"
  while [[ "$link_check" != / && ("$link_check" == */ || "$link_check" == */.) ]]; do
    link_check="${link_check%/}"
    link_check="${link_check%/.}"
  done
  [[ ! -L "$link_check" ]] ||
    fail "build-dir $BUILD_DIR is a symlink, so cleaning it up would delete" \
      "the directory it points to. Point build-dir at a real directory."
  resolved="$(mkdir -p "$BUILD_DIR" && cd -P "$BUILD_DIR" && pwd -P)" ||
    fail "cannot create build-dir: $BUILD_DIR"
  BUILD_DIR="$resolved"

  # Everything below deletes this directory, so refuse any path that would take
  # something else down with it: the project, the finished zip, the runner's
  # temp directory (which holds $GITHUB_OUTPUT), the home directory, or this
  # action's own checkout. Each entry is name=path, and the directory itself
  # counts as well as its parents.
  local protected=("input-path=$INPUT" "output-path=$OUTPUT")
  local var
  for var in RUNNER_TEMP HOME GITHUB_ACTION_PATH; do
    if [[ -d "${!var:-}" ]]; then
      protected+=("$var=$(cd -P "${!var}" && pwd -P)")
    fi
  done

  local entry
  for entry in "${protected[@]}"; do
    ! path_contains "$BUILD_DIR" "${entry#*=}" ||
      fail "build-dir $BUILD_DIR is the same as or a parent of ${entry%%=*}" \
        "${entry#*=}, so cleaning it up would delete ${entry%%=*} too."
  done

  # --- pipeline ---

  trap clean_build_dir EXIT
  clean_build_dir
  mkdir -p "$BUILD_DIR"

  group "[1/9] checking uv version"
  local uv_version
  uv_version="$(uv --version)"
  echo "$uv_version"
  uv_version_is_supported "$uv_version" ||
    fail "this action needs uv $MIN_UV_VERSION or newer, but uv --version says: $uv_version." \
      "Set uv-version to $MIN_UV_VERSION or later, or update the uv pin at the repo root."
  endgroup

  # The exports below use --frozen, so they read uv.lock as it is. This step
  # fails first on a lock that no longer matches pyproject.toml. It only needs
  # the network to re-resolve, and it only re-resolves when the lock is stale.
  group "[2/9] checking uv.lock is up to date"
  uv lock --directory "$INPUT" --check ||
    fail "uv lock --check failed for $INPUT - see uv's message above. If uv.lock" \
      "is out of date with pyproject.toml, run uv lock at the workspace root and" \
      "commit the result."
  endgroup

  # A local package - a workspace member or a plain path dependency - can't go
  # in the requirements file as a path. uv writes the path relative to the
  # workspace root, but uv pip install reads it relative to the current
  # directory. So each local package is built into a wheel next to the
  # project's own, and the requirements export leaves them all out.
  group "[3/9] listing local packages"
  local closure locals_text path
  closure="$(uv export \
    --directory "$INPUT" \
    --frozen \
    --no-dev \
    --no-editable \
    --no-emit-project \
    --no-hashes)"
  if ! locals_text="$(local_package_paths "$closure")"; then
    fail "$locals_text"
  fi
  local locals=()
  while IFS= read -r path; do
    if [[ -n "$path" ]]; then
      locals+=("$path")
    fi
  done <<<"$locals_text"
  if ((${#locals[@]} == 0)); then
    echo "none"
  else
    printf '%s\n' "${locals[@]}"
  fi
  endgroup

  # Built by path and not with --package, so a path dependency that is not a
  # workspace member gets built too. The paths are relative to the workspace
  # root, so uv build runs from there.
  group "[4/9] building local package wheels"
  if ((${#locals[@]} == 0)); then
    echo "no local packages to build"
  else
    local root
    root="$(uv workspace dir --directory "$INPUT")"
    for path in "${locals[@]}"; do
      uv build --directory "$root" --wheel -o "$BUILD_DIR/dist" "$path"
    done
  fi
  endgroup

  # --no-emit-local also leaves out the project itself, since it is local too.
  # --no-emit-workspace is not enough: it keeps a path dependency that is not
  # a workspace member, and the install step then fails on it.
  group "[5/9] exporting locked third-party dependencies"
  uv export \
    --directory "$INPUT" \
    --frozen \
    --no-dev \
    --no-editable \
    --no-emit-local \
    -o "$BUILD_DIR/requirements.txt"
  endgroup

  group "[6/9] building wheel"
  uv build --directory "$INPUT" --wheel -o "$BUILD_DIR/dist"
  endgroup

  group "[7/9] creating venv (python $PYTHON_VERSION)"
  uv venv --python "$PYTHON_VERSION" "$BUILD_DIR/venv"
  endgroup

  # With --no-deps, uv installs only what is listed: the wheels and the locked
  # requirements, and nothing extra from an index. --no-deps also turns off the
  # dependency check, so uv pip check does it instead. With --python-platform it
  # reads markers for the target platform, not for the runner.
  group "[8/9] installing wheels and dependencies for $PLATFORM ($architecture)"
  uv pip install \
    --python "$BUILD_DIR/venv/bin/python" \
    --python-platform "$PLATFORM" \
    --only-binary=:all: \
    --no-installer-metadata \
    --no-compile-bytecode \
    --no-deps \
    "$BUILD_DIR"/dist/*.whl \
    -r "$BUILD_DIR/requirements.txt"
  uv pip check \
    --python "$BUILD_DIR/venv/bin/python" \
    --python-platform "$PLATFORM" ||
    fail "uv pip check found missing or conflicting dependencies for $PLATFORM -" \
      "see uv's message above. The install uses --no-deps, so every dependency" \
      "has to come from uv.lock or from a local package wheel."
  endgroup

  local report="$BUILD_DIR/report.json"

  group "[9/9] packaging"
  uvx "package-python-function@$PACKAGER_VERSION" \
    "$BUILD_DIR/venv" \
    --project "$INPUT/pyproject.toml" \
    --output-dir "$OUTPUT" \
    --report "$report"
  endgroup

  report_outputs "$report"
}

# Every intermediate lives under the build directory, so cleanup has one
# predictable target and never reaches a path outside it. It takes the
# directory itself, though, not just its contents: two builds sharing one
# --build-dir would delete each other's work in progress. Keeping it
# exclusive is the caller's job - see usage().
clean_build_dir() {
  rm -rf "$BUILD_DIR"
}

# Turn the packager's report into the action's outputs. Nothing here works out
# the zip's filename again or globs the output directory - the packager already
# knows what it wrote, and says so.
report_outputs() {
  local report="$1"

  # The packager writes the report only after packaging has succeeded, so a
  # missing report means something went wrong that set -e did not catch.
  [[ -f "$report" ]] || fail "packaging reported success but wrote no report at $report"

  local zip_path distribution_name output_bytes uncompressed_bytes nested_zip zip_sha256
  zip_path="$(jq -er '.output_file' "$report")"
  distribution_name="$(jq -er '.distribution_name' "$report")"
  output_bytes="$(jq -er '.output_bytes' "$report")"
  uncompressed_bytes="$(jq -er '.uncompressed_bytes' "$report")"
  # compressed_bytes is left unread on purpose: it is measured on the temporary
  # dependencies zip, and only matches output_bytes when the nested strategy
  # did not run.
  nested_zip="$(jq -er 'if .nested_zip then "true" else "false" end' "$report")"

  zip_sha256="$(file_sha256 "$zip_path")"

  log "packaged $distribution_name -> $zip_path"
  log "zip $(format_bytes "$output_bytes"), $(format_bytes "$uncompressed_bytes") unzipped"
  if [[ "$nested_zip" == "true" ]]; then
    # The packager nests the dependencies in an inner zip and writes a loader,
    # so the unzipped size AWS measures is the outer zip's, not this figure.
    log "nested-zip fallback kicked in: unzipped size is over AWS's 250 MiB limit"
  else
    log "$(format_bytes $((AWS_LAMBDA_MAX_UNZIP_SIZE - uncompressed_bytes))) of headroom under AWS's 250 MiB limit"
  fi

  # Unset on a local run, where there is no step to report to.
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0

  {
    echo "zip-path=$zip_path"
    echo "zip-sha256=$zip_sha256"
    echo "package-size-bytes=$output_bytes"
    echo "uncompressed-bytes=$uncompressed_bytes"
    echo "nested-zip=$nested_zip"
    # Not a declared action output. action.yml uses it to build the default
    # artifact name from the same place the zip's filename comes from.
    echo "distribution-name=$distribution_name"
  } >>"$GITHUB_OUTPUT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
