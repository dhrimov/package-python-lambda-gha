# Contributing

Issues and pull requests are welcome. This is a small repo with a small
surface: one composite action (`action.yml`) wrapping one bash script
(`build.sh`).

Found a security problem? Do not open an issue - see [SECURITY.md](SECURITY.md).

## Opening an issue

For a packaging bug, the details worth having are:

- the `uses:` step, with `python-version` and `platform`
- the `::error::` or `error:` line the run printed
- the log of the failing step, or which `[N/9]` group it died in
- whether it also fails when you run `build.sh` directly (see below)

A link to a public run beats a description of one.

## Running the tests

`shellcheck` and `bats` are the only tools the unit tests need:

```bash
# macOS
brew install shellcheck bats-core

# Ubuntu
sudo apt-get install --no-install-recommends shellcheck bats
```

```bash
shellcheck build.sh cache-glob.sh
bats tests
```

Both run on every pull request through `.github/workflows/ci.yml`. They take
seconds and need no network.

`tests/build.bats` covers the pure helpers at the top of `build.sh`, plus one
check that the uv floor is the same everywhere it appears. It sources the
script, which defines its functions without running the pipeline - that is what
the `BASH_SOURCE`/`$0` guard at the bottom of the file is for. Keep new helpers
pure and they stay testable the same way.

`tests/cache-glob.bats` covers `cache-glob.sh`. `action.yml` runs that script
before setup-uv to find the `uv.lock` the cache is keyed on. It lives in its
own file because uv is not installed yet at that point.

## Running the action locally

`build.sh` runs outside Actions. It needs `uv`, `uvx` and `jq` on PATH, and it
falls back to `shasum` where there is no `sha256sum`, so a macOS machine works:

```bash
./build.sh \
  --input tests/fixtures/single \
  --output dist \
  --python 3.13 \
  --platform aarch64-manylinux2014
```

Two differences from a CI run. The Linux guard is skipped, because it keys off
`RUNNER_OS` and only Actions sets that. And no step outputs are written,
because `GITHUB_OUTPUT` is unset - the paths and sizes are printed instead.

It builds in `<input>/build` and removes that directory before and after the
run. Removed, not emptied: never point `--build-dir` at anything you want to
keep.

## The end-to-end suite

`.github/workflows/e2e.yml` runs the action against the fixtures in `tests/`:
four Python versions across both `manylinux2014` platforms, the four
`manylinux_2_28` and `manylinux_2_34` platforms on Python 3.13, plus the
nested-zip fallback, the multi-lambda pattern, a uv workspace, the uv floor,
hash stability, a custom `build-dir`, the guard rails, and artifact naming. It is
the only suite that proves the action works, and it costs a lot more than
`ci.yml`.

Workflows on a pull request from a fork wait for a maintainer to approve the
run. That is GitHub's setting for outside contributors, not something your PR
did wrong.

The fixtures pin `orjson` at an exact version on purpose: the matrix asserts
the exact filename of the compiled extension module it ships
(`orjson.cpython-313-aarch64-linux-gnu.so` and friends). Without a compiled
dependency, both platforms would resolve the same `py3-none-any` wheels and the
matrix would prove nothing. Bumping that pin means updating the assertion with
it, so it is a hand edit rather than a Dependabot PR.

The `large` fixture is what proves the nested-zip fallback. It pins `numpy`,
`pandas`, `pyarrow` and `scipy` exactly, which takes the package over AWS's
250 MiB unzipped limit while it stays well under it zipped - the only case
where the fallback kicks in. A bump has to keep both sides of that true, so it
is a hand edit too. It runs on Python 3.13 only: these packages ship no cp314
`manylinux2014` wheels.

The `workspace` fixture is a uv workspace: a virtual root with one `uv.lock`, a
shared `common` library in `libs/`, and two lambda members in `lambdas/` that
both depend on it. `common` depends on `vendor/textutil` by path, and
`textutil` is not a workspace member. So the job also covers a local package
that is not a member, and a local package the lambda only gets through another
one.

`orders` also pins `markupsafe` exactly. It is a compiled dependency no other
member uses, so the job can check that it is missing from the `payments` zip.

The `uv-floor` job packages the same fixture with `uv-version: 0.10.0`, the
oldest uv the action supports. If you raise that floor, update these together:
`MIN_UV_VERSION` in `build.sh`, that job's matrix, and the `uv-version` text in
`action.yml` and `README.md`. `tests/build.bats` fails if they don't match.

## Adding a Python runtime

AWS has no API for the supported runtime set, so the list is kept by hand and
lives in more than one place. All of these need the edit:

- `SUPPORTED_PYTHON_VERSIONS` in `build.sh`
- the `python-version` description in `action.yml`
- the inputs table and the "Supported runtimes" section in `README.md`
- the `python-version` matrix in `.github/workflows/e2e.yml`
- `tests/build.bats`, where the rejected-version cases name the versions either
  side of the supported set

`tests/build.bats` fails if `action.yml`, `README.md` or the e2e matrix don't
match `SUPPORTED_PYTHON_VERSIONS`.

A newly deprecated runtime also needs a date in
`python_version_deprecation_date`, which is what turns its build-time
`::warning::` on. Those dates are hand-written too, from AWS docs.

## Adding a platform

The platform list lives in more than one place too. All of these need the
edit:

- `SUPPORTED_PLATFORMS` in `build.sh`, `platform_architecture` if the
  platform has a new CPU architecture, and `platform_supports_python` if the
  platform's glibc level is newer than some supported runtime can load
- `usage()` in `build.sh`
- the `platform` description in `action.yml`
- the inputs table and the "`platform` and the Lambda runtime" section in
  `README.md`
- the `newer-glibc` matrix in `.github/workflows/e2e.yml`
- `tests/build.bats`

`tests/build.bats` fails if `usage()`, `action.yml`, the `README.md` inputs
table or the e2e matrices don't match `SUPPORTED_PLATFORMS`.

## House rules

- Pin every action to a full commit SHA with a trailing `# vX.Y.Z` comment.
  Dependabot rewrites the SHA and the comment together, so the form matters.
- `.editorconfig` covers indentation and line endings.

## Known gaps

These are already known, so there is no need to open an issue for them. A PR
is welcome:

- Local dependencies with an environment marker are refused. To support them,
  each local wheel has to go to the install step together with its marker.
- An empty `uv-version` reads the pin only from `GITHUB_WORKSPACE`, not from
  `input-path`.
- Matrix jobs for different platforms share one cache key, so only the first
  job's cache is saved. setup-uv's `cache-suffix` would split it.
- A stray `uv.lock` inside a workspace member wins the cache key over the root
  lock. This can happen when separate projects are moved into one workspace
  and their old locks are left behind. `cache-glob.sh` takes the first
  `uv.lock` it finds walking up from `input-path`. uv itself ignores a lock
  inside a member: `uv lock --check` and the build both use the root lock, so
  the zip is still right. Only the cache is wrong. Its key comes from the stray
  file, so a change to the root lock never refreshes it. Options to look into:
  - Stop the walk at the first directory whose `pyproject.toml` has a
    `[tool.uv.workspace]` table, and take the `uv.lock` there. This needs a
    TOML check in bash, before uv is installed.
  - `uv workspace dir` gives the right root, but setup-uv computes the cache
    key while it installs uv, so the action can't call uv before it.
  - A cheap first step: warn in the `action.yml` step when a `uv.lock` is
    found below a directory that has `[tool.uv.workspace]`.
