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

The cloud image already ships common runtimes and tools — Python 3 (with `pip`,
`poetry`, `uv`, `black`, `mypy`, `pytest`, `ruff`), Node 20/21/22 (with `npm`,
`yarn`, `pnpm`, `bun`, `eslint`, `prettier`), Ruby, Go, Rust (stable `rustc` and
`cargo` via `rustup`), Java, PHP, C/C++, Docker, Postgres 16, Redis 7, and
`git`, `gh`, `jq`, `yq`, `ripgrep`, `tmux`. **Defer to the image** for all of
it, except that this script upgrades the Go, Rust, Python and Node toolchains
and `uv` / `bun` to their latest releases, and replaces `ripgrep` and
`shellcheck` with their latest releases, because the image's copies lag.
Beyond that, only install what the image lacks. Run `check-tools` in a cloud session for the exact list, and see
[Installed tools](https://code.claude.com/docs/en/cloud-environments#installed-tools)
for the current inventory.

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
   Upgrade a pre-installed toolchain only when you need a newer version (this
   script does so for Go, Rust, Python, Node, uv, bun, ripgrep and ShellCheck).
4. **Make steps idempotent** — guard with `command -v <tool>` (or, for an
   upgrade, a version check) so re-runs and SessionStart parity are cheap.
5. **Match installs to your network level.** Installs fetch over the wire; a host
   that isn't allowlisted will fail (see [Network access](#network-access)).
6. **Non-interactive apt:** `export DEBIAN_FRONTEND=noninteractive` and pass
   `-y`.
7. **Secrets:** never hardcode credentials in the script. Env vars and the
   script are visible to anyone who uses the environment. On Pro/Max plans, add
   API keys as **API credentials**: the agent proxy attaches them as headers to
   requests for the hosts you list, so the key never enters the VM, but they
   aren't available to the setup script. See
   [`default/credentials.example`](default/credentials.example). GitHub needs
   nothing: the GitHub proxy authenticates `git` and `gh` itself.
8. **Big/slow downloads:** if a single download won't fit in ~5 minutes, move it
   to a SessionStart hook that backgrounds it, or pre-pull Docker images in the
   script so the layers land in the cache.

## What `default/setup.sh` installs

On top of the pre-installed image, in parallel:

| Tool             | Source                                   | Notes                                                |
| ---------------- | ---------------------------------------- | ---------------------------------------------------- |
| `gh`             | apt                                      | GitHub CLI; pre-installed, so only fetched if the image drops it |
| `shellcheck`     | GitHub releases (`stable` tag)           | Latest ShellCheck in `/usr/local/bin`, ahead of the image's older apt copy |
| `rg` (ripgrep)   | GitHub releases (version from crates.io) | Latest ripgrep in `/usr/local/bin`, ahead of the image's older apt copy; Claude Code searches with it |
| `unzip`          | apt                                      | Required by the `bun` installer                      |
| `skopeo`         | apt                                      | Inspect/copy container images between registries     |
| `semgrep`        | PyPI (`uv tool install`)                 | Static analysis, in its own virtualenv               |
| `uv`             | `astral.sh/uv/install.sh`                | Upgraded in place to the latest release — **needs non-default domains** |
| `bun`            | `bun.sh/install`                         | Upgraded in place to the latest release; use `bun add -g` for global JS CLIs — **needs non-default domains** |
| Python           | `uv python install` (`releases.astral.sh`) | Latest stable CPython (or `PYTHON_VERSION`), made the default `python`/`python3` |
| Node.js          | `nodejs.org/dist`                        | Latest Current release (or `NODE_VERSION`) in `/opt/node-v<version>` (the image's `/opt/node20-22` are left alone), made the default `node`/`npm` |
| `corepack`       | `bun add -g` (npm registry)              | pnpm/yarn version manager; Node 25+ no longer bundles it. Falls back to `npm i -g` |
| Rust `nightly`   | `rustup` (`static.rust-lang.org`)        | Latest nightly with rustfmt/clippy/rust-analyzer/rust-src, set as rustup's **default** toolchain |
| `go`             | `go.dev/dl` (→ `dl.google.com`)          | Upgrades the base Go to `GO_VERSION` — **needs non-default domains** |
| `golangci-lint`  | GitHub releases (tag via `proxy.golang.org`) | Go linter (prebuilt binary), upgraded over the image's older copy; falls back to `golangci-lint.run/install.sh` |
| `goimports`      | `go install` (proxy.golang.org)          | Go import formatter                                  |
| `staticcheck`    | `go install` (proxy.golang.org)          | Go static analysis                                   |
| `gopls`          | `go install` (proxy.golang.org)          | Go language server                                   |
| `cargo-binstall` | `raw.githubusercontent.com/.../cargo-binstall` | Installs cargo tools as prebuilt binaries      |
| `flyctl`         | `fly.io/install.sh`                      | Fly.io CLI — **needs non-default domains**           |
| `hadolint`       | GitHub releases (`hadolint/hadolint`)    | Dockerfile linter (static binary)                    |
| `dive`           | GitHub releases (`wagoodman/dive`)       | Inspect image layers / find wasted space             |
| `trivy`          | GitHub (`aquasecurity/trivy` install.sh) | Scan images, filesystems & Dockerfiles for vulns/misconfigs |
| `crane`          | GitHub releases (`google/go-containerregistry`) | Copy/inspect images, resolve tags to digests  |
| `cosign`         | GitHub releases (tag via `proxy.golang.org`) | Sign / verify images & artifacts (static binary)     |
| `syft`           | GitHub (`anchore/syft` install.sh)       | Generate SBOMs from images & filesystems             |
| `goreleaser`     | GitHub releases (`goreleaser/goreleaser`) | Build & publish release artifacts                   |
| `trufflehog`     | GitHub (`trufflesecurity/trufflehog` install.sh) | Scan for verified secrets                    |
| `actionlint`     | GitHub releases (`rhysd/actionlint`)     | Lint GitHub Actions workflow files                   |
| `zizmor`         | GitHub releases (`zizmorcore/zizmor`)    | Static security analysis of GitHub Actions (prebuilt binary) |
| `pre-commit`     | PyPI (`uv tool install`)                 | Git hook framework (drives `make hooks`), in its own virtualenv |

The upgraded Python and Node become the defaults through links in `~/.local/bin`,
which the script puts first on the session PATH via `/etc/profile.d/zz-local-bin.sh`
(also hooked into `/etc/bash.bashrc`); without it the image's
`/etc/profile.d/nodejs.sh` puts `/opt/node22/bin` first and `node` stays on v22. The image's own interpreters stay in place:
`/usr/bin/python3` and `/usr/local/bin/python3` are still 3.11, so `apt` keeps
working, and the image's Python CLIs (`pytest`, `black`, `mypy`, `ruff`, which
are uv tools with their own interpreters) are unaffected. What changes for bare
`python3`:

- It sees none of the image's site-packages, so `python3 -m pytest` or
  `import yaml` fail where `pytest` or `/usr/bin/python3` work.
- `pip` is still the image's 3.11 `pip`, so `pip install foo` doesn't make
  `foo` importable from `python3`.
- uv marks its Pythons externally managed, so `python3 -m pip install` refuses.

Use `uv run`, `uv pip` or `uvx` in projects, or `/usr/bin/python3` for the image's
interpreter. Likewise `npm i -g` lands in `/opt/node-v<version>/bin`, which isn't
on PATH, so install global JS CLIs with
`bun add -g` (`~/.bun/bin` is on PATH, though after the image's
`/opt/node22/bin`, which is why the script links `corepack` into `~/.local/bin`
as well).

`uv` and `bun` are upgraded by re-running their installers rather than
`uv self update` / `bun upgrade`, which both ask `api.github.com` for the latest
version (see below).

All Go tools the script installs (`golangci-lint`, `goimports`, `staticcheck`,
`gopls`) land in `/usr/local/bin`, which is on PATH for every kind of session
shell. The script also writes `/etc/profile.d/go-path.sh` (and hooks it into
`/etc/bash.bashrc`) so that anything `go install`ed *during* a session — which
lands in `$GOBIN`, or `$GOPATH/bin` when unset — is on PATH too.

The base image ships only a **stable** `cargo`/`rustc` through `rustup`. The
script installs the latest **nightly** (with `rustfmt`, `clippy`,
`rust-analyzer` and `rust-src`) and makes it rustup's default, so `cargo` and
`rustc` are nightly everywhere; a repo's `rust-toolchain.toml` still overrides
it. The image's stable stays installed (`cargo +stable ...`) but isn't updated.
Nightly moves daily and the snapshot is rebuilt roughly weekly, so the baked
nightly can be a few days old; run `rustup update nightly` in-session for the
newest. The script also adds `cargo-binstall`, which installs further cargo tools as prebuilt
binaries in seconds (e.g. `cargo binstall cargo-edit cargo-watch`) instead of
compiling them.

Versions track **latest** by default. To hold one back, set an environment
variable: `ZIZMOR_VERSION` (e.g. `v1.25.2`), `PYTHON_VERSION` (e.g. `3.13`) or
`NODE_VERSION` (`current`, the default; `lts`; or a major such as `24`). The Go
toolchain is pinned via `GO_VERSION` (default `1.27.1`, the current release);
set it to upgrade or roll back the installed Go. See
[`default/.env.example`](default/.env.example).

### Keeping pinned versions current

`GO_VERSION` is the only tool version hardcoded in the repo (everything else
resolves to latest at build time, so it refreshes whenever the cache rebuilds).
A [Renovate](https://docs.renovatebot.com) config (`renovate.json`) keeps it
fresh: a custom manager watches the `GO_VERSION` line in `default/setup.sh` and
opens a PR (via the `golang-version` datasource) whenever a new Go release ships,
and Renovate's built-in `github-actions` manager keeps the action versions in
`.github/workflows/` up to date. Updates require the free
[Mend Renovate GitHub App](https://github.com/apps/renovate) to be installed on
the repository; Renovate then runs on its own schedule and surfaces everything
on a "Dependency Dashboard" issue. (Dependabot can't read a version out of a
shell script, which is why this uses Renovate.)

Failures are non-fatal: each step logs a `setup: WARNING: …` to stderr (visible
in the setup logs) and the session still starts. At the end, the script logs one
`setup: WARNING: missing after setup: …` line listing any tool that didn't land
in the snapshot, then how long the run took. It always exits 0.

Every download in the script goes through a `curl` wrapper with a connect
timeout, a 180-second transfer cap and two retries, so one stalled host can't
push the run past the ~5-minute cache budget. Third-party installers piped to
`sh` (trivy, syft, trufflehog, actionlint, bun, uv, flyctl) make their own
curl calls and aren't covered.

`semgrep` and `pre-commit` install with `uv tool install`, which gives each one
its own virtualenv under `/opt/uv-tools` and links it into `/usr/local/bin`.
Their pinned dependencies stay out of the shared `site-packages`, where
`pip install --ignore-installed` could quietly downgrade packages a project
uses. If `uv` is missing, the script falls back to pip.

## Network access

**This environment uses Full network access**, so every step can reach its
download host and no allowlist needs maintaining. Changing the access level or
the allowed hosts rebuilds the cache, so the next session after the switch
re-runs the script. The rest of this section applies only if you move the
environment back to **Trusted** or **Custom**.

The environment's **Network access** level governs which hosts the script can
reach. The default **Trusted** level allows the bundled package registries
(apt, PyPI, GitHub, crates.io, the Go module proxy, …). Under Trusted, these
steps work out of the box: `gh`, `unzip`, `skopeo` (all apt), `shellcheck` and
`ripgrep` (GitHub release assets),
`semgrep` and `pre-commit` (PyPI), `zizmor` and `cargo-binstall` (GitHub
release assets), `golangci-lint` (`golangci-lint.run`
is already listed below), the `go install` tools `goimports`/`staticcheck`/`gopls`
(`proxy.golang.org`), the Docker image tools `hadolint`, `dive` and `trivy`, and
the registry/supply-chain/CI tools `crane`, `cosign`, `syft`, `goreleaser`,
`trufflehog` and `actionlint` (all from GitHub release assets), and the
toolchain upgrades for Rust nightly (`static.rust-lang.org`) and Node
(`nodejs.org`), plus `corepack` (npm registry). The Python upgrade is not: `uv`
downloads it from `releases.astral.sh` (see the allowlist below).

> **Avoid `api.github.com` in the script, even under Full access.** It *is* on
> the Trusted list, but unauthenticated calls are rate-limited per IP and shared
> build IPs hit the limit, so a step that resolves a version through the API
> 403s intermittently and drops that tool from the snapshot — which is exactly
> what happened to `dive`. Prefer a stable `/releases/latest/download/<asset>`
> URL. When the asset name embeds the version, read the tag from the redirect
> that `github.com/<owner>/<repo>/releases/latest` issues, or, for Go projects,
> from the Go module proxy (`proxy.golang.org/<module>/@latest`), which isn't
> rate-limited. `dive` tries the redirect and falls back to the proxy;
> `golangci-lint` goes straight to the proxy. From inside a session the
> `/releases/latest` page returns 403 for repos not attached to the session
> (release asset downloads still work), so prefer a registry that knows the
> version (`ripgrep` reads it from the crates.io index) or a fixed tag
> (`shellcheck` downloads its `stable` release).

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

- `uv` and Python → `astral.sh` / `*.astral.sh` (uv downloads Python from `releases.astral.sh`)
- `bun` → `bun.sh` / `*.bun.sh`
- `go` toolchain → `dl.google.com` (the `go.dev/dl` tarball redirects there)
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
3. Set **Network access** to **Full** (what this environment uses). To lock
   it down instead, pick **Custom** and add the
   [allowlist above](#network-access), keeping default package managers enabled.
4. Optionally add environment variables (`.env` format, one `KEY=value` per
   line; quote a value that contains `#`). [`default/.env.example`](default/.env.example) lists every
   variable the script reads (`SETUP_DEBUG` and the version pins), recommended
   settings for the installed CLIs, and the variables to leave alone.
5. Optionally add API keys under **API credentials** (Pro/Max, existing
   environments only), one form per block in
   [`default/credentials.example`](default/credentials.example).

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
