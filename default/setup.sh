#!/usr/bin/env bash
#
# Claude Code on the web — environment setup script.
#
# This runs once as root on Ubuntu 24.04 BEFORE Claude Code launches. After it
# finishes, Anthropic snapshots the filesystem and reuses that snapshot for
# later sessions, so installs here are paid for once. The cache is rebuilt when
# this script changes, when the allowed network domains change, or after the
# cache expires (~7 days). Resuming an existing session never re-runs this.
#
# Guidelines this script follows (see README.md and the docs):
#   - Keep total runtime under ~5 minutes so the cache can build. Independent
#     installs are fanned out with `&` / `wait`.
#   - Never block session start on a flaky download: each step logs a warning
#     and continues instead of aborting (that's why `set -e` is NOT used).
#   - Only install things the cloud image lacks. Language runtimes, build tools,
#     pytest/jest/cargo, postgres, redis and docker are already present.
#
# Docs: https://code.claude.com/docs/en/claude-code-on-the-web#setup-scripts
#
# ---------------------------------------------------------------------------
# NETWORK ACCESS REQUIRED
# ---------------------------------------------------------------------------
# The default "Trusted" level only allows the bundled package registries
# (apt, PyPI, GitHub, crates.io, the Go module proxy, ...). These steps come
# from Trusted hosts and work out of the box: gh, shellcheck, unzip (apt),
# semgrep (PyPI), sproot, shuck (raw.githubusercontent.com + GitHub release
# assets), cargo-binstall (GitHub), golangci-lint (golangci-lint.run + GitHub),
# and the `go install` tools (goimports, staticcheck via proxy.golang.org).
#
# These steps fetch from hosts that are NOT on the Trusted list, so the
# environment must use "Custom" network access with the default package
# managers enabled PLUS at minimum these domains added:
#     uv          -> astral.sh / *.astral.sh
#     bun         -> bun.sh / *.bun.sh
#     Go tarball  -> dl.google.com   (go.dev/dl redirects here)
#     sprite CLI  -> sprites.dev / *.sprites.dev / sprites-binaries.t3.storage.dev
#     flyctl      -> fly.io / *.fly.io / *.fly.dev / api.machines.dev
# Without them, the matching steps below log a warning and are skipped.
# See the "Network access" section of README.md for the full recommended
# allowlist used by this environment.
# ---------------------------------------------------------------------------

set -uo pipefail

# Optional: set SETUP_DEBUG=1 in the environment variables to trace commands.
[ "${SETUP_DEBUG:-0}" = "1" ] && set -x

export DEBIAN_FRONTEND=noninteractive

# Versions track latest by default. To pin for fully reproducible caches, set
# SPROOT_VERSION / SHUCK_VERSION (e.g. v0.3.5) in the environment variables;
# both installers read them automatically. The Go toolchain is pinned here and
# overridable with GO_VERSION (the base image ships an older Go).
GO_VERSION="${GO_VERSION:-1.26.3}"

log()  { printf '\n=== setup: %s ===\n' "$*"; }
warn() { printf 'setup: WARNING: %s\n' "$*" >&2; }

install_apt() {
  log "apt packages (gh, shellcheck, unzip)"
  apt-get update || warn "apt-get update failed; continuing with cached lists"
  # unzip is required by the bun installer (it ships a .zip).
  apt-get install -y --no-install-recommends gh shellcheck unzip \
    || warn "apt install failed (gh / shellcheck / unzip)"
}

install_uv() {
  command -v uv >/dev/null 2>&1 && { log "uv already present"; return; }
  log "uv (Astral Python package/project manager)"
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
    || warn "uv install failed (is astral.sh on the allowlist?)"
}

install_bun() {
  command -v bun >/dev/null 2>&1 && { log "bun already present"; return; }
  log "bun (JS runtime / package manager)"
  curl -fsSL https://bun.sh/install \
    | env BUN_INSTALL=/usr/local bash \
    || warn "bun install failed (is bun.sh on the allowlist, and is unzip present?)"
}

install_cargo_binstall() {
  command -v cargo >/dev/null 2>&1 || { warn "cargo not found; skipping cargo-binstall"; return; }
  command -v cargo-binstall >/dev/null 2>&1 && { log "cargo-binstall already present"; return; }
  log "cargo-binstall (prebuilt-binary installer for cargo tools)"
  curl -fsSL https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
    | bash \
    || { warn "cargo-binstall install failed"; return; }
  # Surface it on the system PATH (it installs into $CARGO_HOME/bin by default).
  [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo-binstall" ] \
    && ln -sf "${CARGO_HOME:-$HOME/.cargo}/bin/cargo-binstall" /usr/local/bin/cargo-binstall
}

# Replace the base image's Go with the pinned latest. go.dev/dl redirects the
# tarball to dl.google.com, so that host must be allowlisted. We extract to a
# temp dir and only swap /usr/local/go in once the download verifies, so a
# failed/blocked download leaves the existing toolchain intact.
install_go() {
  if command -v go >/dev/null 2>&1 && go version 2>/dev/null | grep -q "go${GO_VERSION} "; then
    log "Go ${GO_VERSION} already present"; return
  fi
  log "Go ${GO_VERSION} toolchain"
  local tarball="go${GO_VERSION}.linux-amd64.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/${tarball}" "https://go.dev/dl/${tarball}" \
     && tar -C "${tmp}" -xzf "${tmp}/${tarball}" \
     && [ -x "${tmp}/go/bin/go" ]; then
    rm -rf /usr/local/go
    mv "${tmp}/go" /usr/local/go
    ln -sf /usr/local/go/bin/go    /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  else
    warn "Go ${GO_VERSION} install failed (is dl.google.com on the allowlist?)"
  fi
  rm -rf "${tmp}"
}

# Run AFTER install_go so the tools build with the upgraded toolchain. The
# `go install` steps fetch through the Go module proxy (proxy.golang.org),
# which the Trusted list already permits.
install_go_tools() {
  command -v go >/dev/null 2>&1 || { warn "go not found; skipping Go tools"; return; }
  log "Go tools (golangci-lint, goimports, staticcheck)"
  curl -fsSL https://golangci-lint.run/install.sh \
    | sh -s -- -b /usr/local/bin \
    || warn "golangci-lint install failed"
  GOBIN=/usr/local/bin go install golang.org/x/tools/cmd/goimports@latest \
    || warn "goimports install failed"
  GOBIN=/usr/local/bin go install honnef.co/go/tools/cmd/staticcheck@latest \
    || warn "staticcheck install failed"
}

install_semgrep() {
  log "semgrep (PyPI)"
  python3 -m pip install --quiet --ignore-installed semgrep \
    || warn "semgrep install failed"
}

install_fly() {
  command -v fly >/dev/null 2>&1 && { log "flyctl already present"; return; }
  log "flyctl"
  curl -fsSL https://fly.io/install.sh | FLYCTL_INSTALL=/usr/local sh \
    || warn "flyctl install failed (is fly.io on the allowlist?)"
}

install_sprite() {
  command -v sprite >/dev/null 2>&1 && { log "sprite CLI already present"; return; }
  log "sprite CLI"
  curl -fsSL https://sprites.dev/install.sh | sh \
    || warn "sprite CLI install failed (are sprites.dev + sprites-binaries.t3.storage.dev allowlisted?)"
}

install_sproot() {
  log "sproot (justanotherspy/sproot)"
  curl -fsSL https://raw.githubusercontent.com/justanotherspy/sproot/main/install.sh | sh \
    || warn "sproot install failed"
}

install_shuck() {
  log "shuck (justanotherspy/shuck)"
  curl -fsSL https://raw.githubusercontent.com/justanotherspy/shuck/main/install.sh | bash \
    || warn "shuck install failed"
}

# apt holds the dpkg lock, so run it to completion first, then fan out the
# independent downloads in parallel and wait for all of them.
install_apt

install_semgrep &
install_fly &
install_sprite &
install_sproot &
install_shuck &
install_uv &
install_bun &
install_cargo_binstall &
# Go toolchain upgrade and the Go tools must run in sequence (the tools build
# against the new toolchain, and we must not swap /usr/local/go while a build
# is reading it); the pair runs in parallel with everything else.
( install_go; install_go_tools ) &
wait

log "done"
