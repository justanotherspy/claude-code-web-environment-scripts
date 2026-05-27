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
# (apt, PyPI, GitHub, crates.io, ...). These tools come from Trusted hosts and
# work out of the box: gh, shellcheck (apt), semgrep (PyPI), sproot, shuck
# (raw.githubusercontent.com + GitHub release assets).
#
# The sprite CLI and flyctl are fetched from hosts that are NOT on the Trusted
# list, so the environment must use "Custom" network access with the default
# package managers enabled PLUS at minimum these domains added:
#     sprites.dev / *.sprites.dev
#     sprites-binaries.t3.storage.dev
#     fly.io / *.fly.io / *.fly.dev / api.machines.dev
# Without them, the sprite/fly steps below log a warning and are skipped.
# See the "Network access" section of README.md for the full recommended
# allowlist used by this environment.
# ---------------------------------------------------------------------------

set -uo pipefail

# Optional: set SETUP_DEBUG=1 in the environment variables to trace commands.
[ "${SETUP_DEBUG:-0}" = "1" ] && set -x

export DEBIAN_FRONTEND=noninteractive

# Versions track latest by default. To pin for fully reproducible caches, set
# SPROOT_VERSION / SHUCK_VERSION (e.g. v0.3.5) in the environment variables;
# both installers read them automatically.

log()  { printf '\n=== setup: %s ===\n' "$*"; }
warn() { printf 'setup: WARNING: %s\n' "$*" >&2; }

install_apt() {
  log "apt packages (gh, shellcheck)"
  apt-get update || warn "apt-get update failed; continuing with cached lists"
  apt-get install -y --no-install-recommends gh shellcheck \
    || warn "apt install failed (gh / shellcheck)"
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
wait

log "done"
