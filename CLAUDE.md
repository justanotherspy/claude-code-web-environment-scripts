# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo is the **source of truth** for the Bash setup script that provisions
[Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)
cloud environments. The deliverable is a single file, `default/setup.sh`; the
`README.md` is extensive documentation of how setup scripts work and how to
configure the environment. There is no application code, build system, or test
suite here.

Editing `default/setup.sh` does **not** change any live environment. The script
runs only after a human pastes its contents into the **Setup script** field of
the cloud environment UI (and configures the matching network allowlist). Treat
commits here as proposals that someone applies manually.

## Validating changes

The only checks that apply are shell-syntax and lint:

```bash
bash -n default/setup.sh          # syntax check
shellcheck default/setup.sh       # lint
```

Run both before committing any change to the script.

## How the setup script must behave (non-obvious constraints)

`default/setup.sh` runs **once as root on Ubuntu 24.04 before Claude Code
launches**; the resulting filesystem is snapshotted and reused. These rules
shape every edit — they are easy to violate and break session startup:

- **A non-zero exit fails session start.** This is why the script uses
  `set -uo pipefail` but deliberately **omits `set -e`**. Every install step
  must be non-fatal: wrap it so failure logs a `warn` and continues (see the
  `install_*` functions and the `|| warn ...` pattern). Do not add a top-level
  `set -e`.
- **Only install what the base image lacks.** The cloud image already ships
  Python, Node, Ruby, Go, Rust, Java, PHP, Docker, Postgres, Redis, git, jq,
  ripgrep, and the common test runners. Don't reinstall those. Exceptions the
  script makes on purpose: it adds `uv`, `bun`, and `cargo-binstall` (absent
  from the base) and **upgrades** Go to the pinned `GO_VERSION` because the base
  Go lags the latest release.
- **Keep total runtime under ~5 minutes** so the cache can build. `apt` runs
  first and to completion (it holds the dpkg lock), then independent downloads
  fan out with `&` and a single `wait`.
- **The snapshot captures files, not processes.** Don't expect to start
  long-running services here; they won't survive into sessions.
- **Make steps idempotent**, typically guarded with `command -v <tool>`.

## Network allowlist coupling

The script and the environment's network configuration are tightly coupled, and
the coupling is invisible from the code alone:

- Under the default **Trusted** level these work (apt / PyPI / GitHub /
  githubusercontent / Go module proxy hosts): `gh`, `shellcheck`, `unzip`,
  `semgrep`, `sproot`, `shuck`, `cargo-binstall`, `golangci-lint`, and the
  `go install` tools (`goimports`, `staticcheck`).
- `uv` (`astral.sh`), `bun` (`bun.sh`), the Go toolchain tarball
  (`go.dev/dl` redirects to `dl.google.com`), `sprite`, and `flyctl` download
  from hosts **not** on the Trusted list, so the environment must use **Custom**
  access (with default package managers still enabled) plus the allowlist
  documented in the README's "Network access" section. Without those domains,
  the matching step logs a warning and skips.

If you add a step that fetches from a new host, you must also update the
README's recommended allowlist — otherwise it will silently fail in the cloud.

## Versions

`sproot` and `shuck` track **latest** by default. Their installers read
`SPROOT_VERSION` / `SHUCK_VERSION` env vars (e.g. `v0.3.5`) for pinned,
reproducible caches — set those in the environment, not in the script.

The Go toolchain is pinned by the `GO_VERSION` variable at the top of the script
(default `1.26.3`, overridable from the environment). `uv`, `bun`,
`golangci-lint`, and the `go install` tools track latest.

## Debugging

Set `SETUP_DEBUG=1` in the environment to run the script under `set -x`. A step
that works locally but fails in the cloud is almost always a network-allowlist
miss or a path that doesn't exist in a fresh clone.
