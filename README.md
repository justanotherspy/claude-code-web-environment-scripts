# claude-code-web-environment-scripts

Environment setup scripts for [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web).

A **setup script** is a Bash script that runs once, as root on Ubuntu 24.04,
*before* Claude Code launches in a cloud session. Anthropic then snapshots the
filesystem and reuses that snapshot for later sessions, so anything the script
installs is available at the start of every session without reinstalling.

This repo holds the setup script ([`default/setup.sh`](default/setup.sh)) plus
guidance on how to write good ones.

## Contents

- [How setup scripts work](#how-setup-scripts-work)
- [Setup scripts vs. SessionStart hooks](#setup-scripts-vs-sessionstart-hooks)
- [Best practices](#best-practices)
- [What `default/setup.sh` installs](#what-defaultsetupsh-installs)
- [Network access](#network-access)
- [Configuring the environment](#configuring-the-environment)
- [Debugging](#debugging)
- [References](#references)

## How setup scripts work

- Runs **once per environment** as `root` on **Ubuntu 24.04**, before Claude
  Code starts. `apt install` and language package managers work.
- The resulting filesystem is **cached** and reused. The script re-runs only
  when you change the script, change the allowed network domains, or after the
  cache expires (~7 days). Resuming a session never re-runs it.
- The cache captures **files, not processes**. Services (Postgres, Redis,
  `docker compose`) are *not* started by the snapshot — start those per session
  (ask Claude, or use a SessionStart hook).
- **If the script exits non-zero, the session fails to start.** Keep
  non-critical steps from aborting the whole script (this repo's script logs a
  warning and continues instead).

The cloud image already ships common runtimes and tools (Python, Node 20–22,
Ruby, Go, Rust, Java, PHP, Docker, Postgres 16, Redis 7, `git`, `jq`, `ripgrep`,
`pytest`/`jest`/`cargo`, …). **Only install what the image lacks.** Run
`check-tools` in a cloud session for the exact list.

## Setup scripts vs. SessionStart hooks

|                | Setup script                                  | SessionStart hook                              |
| -------------- | --------------------------------------------- | ---------------------------------------------- |
| Attached to    | The cloud environment                         | Your repository (`.claude/settings.json`)      |
| Configured in  | Cloud environment UI (not the repo)           | Committed to the repo                          |
| Runs           | Before Claude launches, only when uncached    | After Claude launches, every session/resume    |
| Scope          | Cloud sessions only                           | Local **and** cloud                            |
| Cached?        | Yes (snapshotted)                             | No (runs every time)                           |

Rule of thumb: use a **setup script** for things the cloud needs but your laptop
already has (CLI tools, runtimes). Use a **SessionStart hook** for project setup
that should run everywhere, like `npm install` — and gate it on
`CLAUDE_CODE_REMOTE=true` if it should only run in the cloud.

## Best practices

1. **Don't block session start on flaky downloads.** A non-zero exit fails the
   whole session. Append `|| true` (or log-and-continue, as this script does) to
   non-critical steps. Avoid a top-level `set -e` that aborts on the first
   hiccup.
2. **Stay under ~5 minutes** so the cache can build. Run independent installs in
   parallel with `&` and `wait`.
3. **Only install what's missing.** The base image is rich; check before adding.
4. **Make steps idempotent** — guard with `command -v <tool>` so re-runs and
   SessionStart parity are cheap.
5. **Match installs to your network level.** Installs fetch over the wire; a host
   that isn't allowlisted will fail (see [Network access](#network-access)).
6. **Non-interactive apt:** `export DEBIAN_FRONTEND=noninteractive` and pass
   `-y`.
7. **Secrets:** there is no secrets store. Env vars and the script are visible to
   anyone who can edit the environment — don't hardcode credentials. For private
   `gh` operations, add a `GH_TOKEN` env var.
8. **Big/slow downloads:** if a single download won't fit in ~5 minutes, move it
   to a SessionStart hook that backgrounds it, or pre-pull Docker images in the
   script so the layers land in the cache.

## What `default/setup.sh` installs

On top of the pre-installed image, in parallel:

| Tool             | Source                                   | Notes                                                |
| ---------------- | ---------------------------------------- | ---------------------------------------------------- |
| `gh`             | apt                                      | GitHub CLI (not pre-installed)                       |
| `shellcheck`     | apt                                      | Shell linting                                        |
| `unzip`          | apt                                      | Required by the `bun` installer                      |
| `skopeo`         | apt                                      | Inspect/copy container images between registries     |
| `semgrep`        | PyPI                                     | Static analysis                                      |
| `uv`             | `astral.sh/uv/install.sh`                | Python package/project manager — **needs non-default domains** |
| `bun`            | `bun.sh/install`                         | JS runtime / package manager — **needs non-default domains**   |
| `go`             | `go.dev/dl` (→ `dl.google.com`)          | Upgrades the base Go to `GO_VERSION` — **needs non-default domains** |
| `golangci-lint`  | `golangci-lint.run/install.sh`           | Go linter (prebuilt binary)                          |
| `goimports`      | `go install` (proxy.golang.org)          | Go import formatter                                  |
| `staticcheck`    | `go install` (proxy.golang.org)          | Go static analysis                                   |
| `gopls`          | `go install` (proxy.golang.org)          | Go language server                                   |
| `cargo-binstall` | `raw.githubusercontent.com/.../cargo-binstall` | Installs cargo tools as prebuilt binaries      |
| `garlic`         | GitHub releases (`justanotherspy/garlic`) | Tracks coding time and nudges breaks (prebuilt binary)       |
| `flyctl`         | `fly.io/install.sh`                      | Fly.io CLI — **needs non-default domains**           |
| `sprite`         | `sprites.dev/install.sh`                 | sprite.dev CLI — **needs non-default domains**       |
| `sproot`         | `raw.githubusercontent.com/.../sproot`   | Bootstraps sprite.dev sprites from a config repo     |
| `shuck`          | `raw.githubusercontent.com/.../shuck`    | Returns the exact failing CI step logs for a PR      |
| `hadolint`       | GitHub releases (`hadolint/hadolint`)    | Dockerfile linter (static binary)                    |
| `dive`           | GitHub releases (`wagoodman/dive`)       | Inspect image layers / find wasted space             |
| `trivy`          | GitHub (`aquasecurity/trivy` install.sh) | Scan images, filesystems & Dockerfiles for vulns/misconfigs |
| `crane`          | GitHub releases (`google/go-containerregistry`) | Copy/inspect images, resolve tags to digests  |
| `cosign`         | GitHub releases (`sigstore/cosign`)      | Sign / verify images & artifacts (static binary)     |
| `syft`           | GitHub (`anchore/syft` install.sh)       | Generate SBOMs from images & filesystems             |
| `goreleaser`     | GitHub releases (`goreleaser/goreleaser`) | Build & publish release artifacts                   |
| `trufflehog`     | GitHub (`trufflesecurity/trufflehog` install.sh) | Scan for verified secrets                    |
| `actionlint`     | GitHub releases (`rhysd/actionlint`)     | Lint GitHub Actions workflow files                   |
| `zizmor`         | GitHub releases (`zizmorcore/zizmor`)    | Static security analysis of GitHub Actions (prebuilt binary) |
| `pre-commit`     | PyPI                                     | Git hook framework (drives `make hooks`)             |

All Go tools the script installs (`golangci-lint`, `goimports`, `staticcheck`,
`gopls`) land in `/usr/local/bin`, which is on PATH for every kind of session
shell. The script also writes `/etc/profile.d/go-path.sh` (and hooks it into
`/etc/bash.bashrc`) so that anything `go install`ed *during* a session — which
lands in `$GOBIN`, or `$GOPATH/bin` when unset — is on PATH too.

The base image already ships `cargo`/`rustc`, so the Rust step just adds
`cargo-binstall`, which then installs any further cargo tools as prebuilt
binaries in seconds (e.g. `cargo binstall cargo-edit cargo-watch`) instead of
compiling them.

Versions track **latest** by default. To pin for fully reproducible caches, set
`SPROOT_VERSION` / `SHUCK_VERSION` / `GARLIC_VERSION` / `ZIZMOR_VERSION` (e.g.
`v0.3.5`) as environment variables — the `sproot`/`shuck` installers and the
`garlic`/`zizmor` steps read them automatically. The Go toolchain is pinned via
`GO_VERSION` (default `1.26.3`); set it to upgrade or roll back the installed
Go.

Failures are non-fatal: each step logs a `setup: WARNING: …` to stderr (visible
in the setup logs) and the session still starts.

## Network access

The environment's **Network access** level governs which hosts the script can
reach. The default **Trusted** level allows the bundled package registries
(apt, PyPI, GitHub, crates.io, the Go module proxy, …). Under Trusted, these
steps work out of the box: `gh`, `shellcheck`, `unzip`, `skopeo` (all apt),
`semgrep` and `pre-commit` (PyPI), `sproot`, `shuck`, `garlic`, `zizmor` and
`cargo-binstall` (all GitHub release assets), `golangci-lint` (`golangci-lint.run`
is already listed below), the `go install` tools `goimports`/`staticcheck`/`gopls`
(`proxy.golang.org`), the Docker image tools `hadolint`, `dive` and `trivy`, and
the registry/supply-chain/CI tools `crane`, `cosign`, `syft`, `goreleaser`,
`trufflehog` and `actionlint` (all from GitHub release assets).

> **Container registries (`cgr.dev` and friends).** The tools above can pull,
> inspect and pin images at session time, but the Chainguard registry `cgr.dev`
> is **not** on the Trusted list — anonymous pulls return `403 Forbidden` until
> you add it to the Custom allowlist below. Add the registry host for whatever
> registry you pull base images from (Docker Hub, GHCR and the like are covered
> by the default package-manager list).

Some steps download from hosts that are **not** on the Trusted list, so this
environment uses **Custom** network access — *with the default package managers
enabled* — plus the allowlist below. Without these domains the matching step
logs a warning and is skipped:

- `uv` → `astral.sh` / `*.astral.sh`
- `bun` → `bun.sh` / `*.bun.sh`
- `go` toolchain → `dl.google.com` (the `go.dev/dl` tarball redirects there)
- `sprite` → `sprites.dev` / `*.sprites.dev` / `sprites-binaries.t3.storage.dev`
- `flyctl` → `fly.io` / `*.fly.io` / `*.fly.dev` / `api.machines.dev`
- `zizmor` docs → `zizmor.sh` / `*.zizmor.sh` (the `docs.zizmor.sh` audit
  reference pages linked from each finding; the tool itself installs under
  Trusted via crates.io + GitHub)

Recommended **Custom** allowlist for this environment (one domain per line):

```text
semgrep.dev
anthropic.com
code.claude.com
ppa.launchpadcontent.net
github.com
*.github.com
linear.app
*.linear.app
justanotherspy.com
*.justanotherspy.com
*.fly.io
fly.io
*.fly.dev
api.machines.dev
sprites.dev
*.sprites.dev
sprites-binaries.t3.storage.dev
astral.sh
*.astral.sh
bun.sh
*.bun.sh
dl.google.com
golangci-lint.run
*.blob.core.windows.net
*.githubusercontent.com
*.go.dev
go.dev
crates.io
*.crates.io
cgr.dev
*.cgr.dev
zizmor.sh
*.zizmor.sh
```

Use `*.` for wildcard subdomains, and keep **“Also include default list of
common package managers”** checked so apt/PyPI/GitHub keep working alongside
these custom entries.

## Configuring the environment

Setup scripts are configured in the **cloud environment UI**, not in this repo —
this repo is the source of truth for the script's contents. To apply it:

1. In a cloud session, open the environment selector (the cloud icon) →
   **Add environment** or edit an existing one.
2. Paste the contents of [`default/setup.sh`](default/setup.sh) into the
   **Setup script** field.
3. Set **Network access** to **Custom** and add the
   [allowlist above](#network-access) (keep default package managers enabled).
4. Optionally add environment variables (`.env` format, one `KEY=value` per
   line, no quotes), e.g. `GH_TOKEN`, `SPROOT_VERSION`, `SETUP_DEBUG=1`.

## Debugging

- Set `SETUP_DEBUG=1` as an environment variable to run the script under
  `set -x` and see exactly which command ran.
- Watch for `setup: WARNING: …` lines in the setup logs — those mark steps that
  failed but didn't block startup.
- A step that works locally but fails in the cloud is usually a **network
  allowlist** miss (host not in your access level) or a path that doesn't exist
  in a fresh clone.
- Validate locally before pushing: `bash -n default/setup.sh` (syntax) and
  `shellcheck default/setup.sh` (lint).

## References

- [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)
  — setup scripts, environment caching, network access, default allowlist.
- [Hooks](https://code.claude.com/docs/en/hooks#sessionstart) — SessionStart hooks.
- [sproot](https://github.com/justanotherspy/sproot) ·
  [shuck](https://github.com/justanotherspy/shuck)
