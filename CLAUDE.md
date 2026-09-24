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
  Python, Node, Ruby, Go, Rust, Java, PHP, Docker, Postgres, Redis, git, gh, jq,
  ripgrep, `uv`, `bun`, and the common test runners (see
  [Installed tools](https://code.claude.com/docs/en/cloud-environments#installed-tools)).
  Don't reinstall those — the `uv`, `bun` and `gh` steps are kept only as
  guarded no-ops in case the image drops them. Exceptions the script makes on
  purpose: it **upgrades** Go to the pinned `GO_VERSION` because the base Go
  lags the latest release, and it adds `cargo-binstall`, the Rust **nightly**
  toolchain and `cargo-nextest`, none of which the base image has.
- **Toolchains, not just CLIs.** Two repos here pin a toolchain the base image
  doesn't carry: garnish's `rust-toolchain.toml` pins `channel = "nightly"`
  with rustfmt/clippy/rust-analyzer/rust-src, and the Go repos' `go.mod` sits
  on the current release. Both belong in the snapshot, not in a per-session
  download. `stable` stays rustup's default toolchain — a `rust-toolchain.toml`
  selects nightly per-directory.
- **Never resolve a version through `api.github.com`**, even under Full
  access. Unauthenticated calls are rate-limited per IP and shared build IPs
  hit the limit, so the step 403s intermittently and that tool silently misses
  the snapshot (this is what happened to `dive`). Use a stable
  `/releases/latest/download/<asset>` URL, read the tag from the redirect
  `github.com/<owner>/<repo>/releases/latest` issues, or, for Go projects, read
  it from `proxy.golang.org/<module>/@latest`, which isn't rate-limited.
- **Download with the `curl` wrapper.** The script defines `curl()` with
  timeouts and retries so one stalled host can't blow the 5-minute budget;
  don't call `command curl` directly.
- **Python CLIs go through `install_python_tool`** (`uv tool install` into
  `/opt/uv-tools`, with pip as the fallback). Don't `pip install
  --ignore-installed` into the shared site-packages.
- **Always end with `exit 0`**, after the missing-tools summary.
- **Keep total runtime under ~5 minutes** so the cache can build. `apt` runs
  first and to completion (it holds the dpkg lock), then independent downloads
  fan out with `&` and a single `wait`.
- **The snapshot captures files, not processes.** Don't expect to start
  long-running services here; they won't survive into sessions.
- **Make steps idempotent**, typically guarded with `command -v <tool>`.

## Network allowlist coupling

The environment now runs with **Full** network access, so every step can reach
its host. The coupling below matters again only if the environment moves back
to Trusted or Custom, so keep the README allowlist accurate anyway:

- Under the default **Trusted** level these work (apt / PyPI / GitHub /
  githubusercontent / Go module proxy hosts): `gh`, `shellcheck`, `unzip`,
  `semgrep`, `sproot`, `shuck`, `garlic` (prebuilt GitHub release binary),
  `cargo-binstall`, `golangci-lint`, the `go install` tools (`goimports`,
  `staticcheck`, `gopls`), and the Rust `nightly` toolchain (`rustup.rs` /
  `static.rust-lang.org`).
- `uv` (`astral.sh`), `bun` (`bun.sh`), the Go toolchain tarball
  (`go.dev/dl` redirects to `dl.google.com`), `cargo-nextest`
  (`get.nexte.st`), `sprite`, and `flyctl` download
  from hosts **not** on the Trusted list, so the environment must use **Custom**
  access (with default package managers still enabled) plus the allowlist
  documented in the README's "Network access" section. Without those domains,
  the matching step logs a warning and skips.

If you add a step that fetches from a new host, you must also update the
README's recommended allowlist — otherwise it will silently fail in the cloud.

## Versions

`sproot`, `shuck`, `garlic`, and `zizmor` track **latest** by default. The
`sproot`/`shuck` installers and the `garlic`/`zizmor` steps read `SPROOT_VERSION`
/ `SHUCK_VERSION` / `GARLIC_VERSION` / `ZIZMOR_VERSION` env vars (e.g. `v0.3.5`)
for pinned, reproducible caches — set those in the environment, not in the script.
`default/.env.example` lists every env var the script reads, and
`default/credentials.example` lists the tokens the installed CLIs use. If you add
a variable the script reads, or install a CLI that authenticates with a token,
add it to the matching example file.

The Go toolchain is pinned by the `GO_VERSION` variable at the top of the script
(default `1.27.1`, overridable from the environment). `uv`, `bun`,
`golangci-lint`, the `go install` tools, the Rust `nightly` toolchain and
`cargo-nextest` all track latest. Nightly moves daily and the snapshot lives
about a week, so a session's nightly can be a few days old; `rustup update
nightly` refreshes it in place.

`GO_VERSION` is the only hardcoded tool version in the repo. `renovate.json`
(Renovate App) keeps it current via a regex custom manager on `default/setup.sh`
(`golang-version` datasource) and keeps the workflow action versions current via
the built-in `github-actions` manager. If you add or rename a hardcoded version,
update the custom manager's `matchStrings` to match, or Renovate won't see it.

## Debugging

Set `SETUP_DEBUG=1` in the environment to run the script under `set -x`. A step
that works locally but fails in the cloud is almost always a network-allowlist
miss or a path that doesn't exist in a fresh clone.
