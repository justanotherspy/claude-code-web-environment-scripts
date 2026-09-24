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
# NETWORK ACCESS
# ---------------------------------------------------------------------------
# This environment uses "Full" network access, so every step below can reach
# its download host. Changing the access level (or the allowed hosts) rebuilds
# the cache, so switching to Full already re-runs this script.
#
# If you move the environment back to "Trusted", these steps still work
# (apt, PyPI, GitHub, githubusercontent, crates.io, the Go module proxy):
# gh, shellcheck, unzip, skopeo, semgrep, pre-commit, zizmor, cargo-binstall,
# golangci-lint, goimports, staticcheck, gopls, hadolint, dive, trivy, crane,
# cosign, syft, goreleaser, trufflehog and actionlint. These fetch from hosts
# NOT on the Trusted list and need "Custom" access (default package managers
# enabled) plus the README's allowlist:
#     uv          -> astral.sh / *.astral.sh
#     bun         -> bun.sh / *.bun.sh
#     Go tarball  -> dl.google.com   (go.dev/dl redirects here)
#     flyctl      -> fly.io / *.fly.io / *.fly.dev / api.machines.dev
# Without them, the matching step logs a warning and is skipped.
# ---------------------------------------------------------------------------

set -uo pipefail

# Optional: set SETUP_DEBUG=1 in the environment variables to trace commands.
[ "${SETUP_DEBUG:-0}" = "1" ] && set -x

export DEBIAN_FRONTEND=noninteractive

# The image keeps rustup/cargo in ~/.cargo/bin and uv in ~/.local/bin. Make
# sure both are on PATH for this script however it was launched, so the
# `command -v` guards below find them.
for _dir in "${HOME}/.cargo/bin" "${HOME}/.local/bin"; do
  case ":${PATH}:" in
    *":${_dir}:"*) ;;
    *) [ -d "${_dir}" ] && PATH="${_dir}:${PATH}" ;;
  esac
done
unset _dir
export PATH

# Versions track latest by default. To pin zizmor for a reproducible cache, set
# ZIZMOR_VERSION (e.g. v1.25.2) in the environment variables. The Go toolchain
# is pinned here and overridable with GO_VERSION (the base image ships an older
# Go).
GO_VERSION="${GO_VERSION:-1.27.1}"

log()  { printf '\n=== setup: %s ===\n' "$*"; }
warn() { printf 'setup: WARNING: %s\n' "$*" >&2; }

# Every download in this script goes through this wrapper, so a stalled host
# can't hang a step past the ~5 minute cache budget: connections time out,
# transfers are capped, and transient failures (including timeouts) retry.
# Third-party installers piped to `sh` below use their own curl calls and are
# not covered.
curl() {
  command curl --connect-timeout 15 --max-time 180 \
    --retry 2 --retry-delay 2 "$@"
}

# Install the apt packages the image lacks. gh and shellcheck ship in the
# current image, so normally only skopeo is fetched; each is still listed in
# case the image drops it. unzip is required by the bun installer (it ships a
# .zip). skopeo inspects and copies container images between registries.
install_apt() {
  local want=(gh:gh shellcheck:shellcheck unzip:unzip skopeo:skopeo)
  local pkgs=() entry
  for entry in "${want[@]}"; do
    command -v "${entry%%:*}" >/dev/null 2>&1 || pkgs+=("${entry#*:}")
  done
  if [ "${#pkgs[@]}" -eq 0 ]; then
    log "apt packages already present"; return
  fi
  log "apt packages (${pkgs[*]})"
  apt-get update || warn "apt-get update failed; continuing with cached lists"
  apt-get install -y --no-install-recommends "${pkgs[@]}" \
    || warn "apt install failed (${pkgs[*]})"
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

# zizmor (zizmorcore/zizmor): static analysis for GitHub Actions workflows.
# Pulls the prebuilt binary straight from the GitHub release (a cargo-dist
# tarball; github.com release assets are on the Trusted list) -- faster and more
# reliable than `cargo binstall`, which can fall back to a slow from-source
# build. The asset name is version-independent, so latest/download resolves
# without an api.github.com lookup; set ZIZMOR_VERSION (e.g. v1.25.2) to pin.
install_zizmor() {
  command -v zizmor >/dev/null 2>&1 && { log "zizmor already present"; return; }
  log "zizmor (GitHub Actions security auditor)"
  local base="https://github.com/zizmorcore/zizmor/releases"
  local url="${base}/latest/download/zizmor-x86_64-unknown-linux-gnu.tar.gz"
  [ -n "${ZIZMOR_VERSION:-}" ] \
    && url="${base}/download/${ZIZMOR_VERSION}/zizmor-x86_64-unknown-linux-gnu.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/zizmor.tar.gz" "${url}" \
     && tar -C "${tmp}" -xzf "${tmp}/zizmor.tar.gz" zizmor \
     && [ -x "${tmp}/zizmor" ]; then
    install -m 0755 "${tmp}/zizmor" /usr/local/bin/zizmor
  else
    warn "zizmor install failed"
  fi
  rm -rf "${tmp}"
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

# golangci-lint: prebuilt release binary. Its official installer scrapes
# GitHub's releases pages to resolve a tag, and those pages 403 on shared build
# IPs the same way api.github.com does. So the tag comes from the Go module
# proxy (Trusted, not rate-limited) and the tarball straight from the release
# asset URL. If either step fails, fall back to the official installer.
install_golangci_lint() {
  command -v golangci-lint >/dev/null 2>&1 && { log "golangci-lint already present"; return; }
  log "golangci-lint (Go linter)"
  local ver tmp
  ver="$(curl -fsSL https://proxy.golang.org/github.com/golangci/golangci-lint/v2/@latest          | sed -nE 's#.*"Version":"v([^"]+)".*#\1#p')"
  tmp="$(mktemp -d)"
  local name="golangci-lint-${ver}-linux-amd64"
  if [ -n "${ver}" ] \
     && curl -fsSL -o "${tmp}/gl.tar.gz" \
          "https://github.com/golangci/golangci-lint/releases/download/v${ver}/${name}.tar.gz" \
     && tar -C "${tmp}" -xzf "${tmp}/gl.tar.gz" "${name}/golangci-lint" \
     && [ -x "${tmp}/${name}/golangci-lint" ]; then
    install -m 0755 "${tmp}/${name}/golangci-lint" /usr/local/bin/golangci-lint
  else
    curl -fsSL https://golangci-lint.run/install.sh \
      | sh -s -- -b /usr/local/bin \
      || warn "golangci-lint install failed"
  fi
  rm -rf "${tmp}"
}

# Run AFTER install_go so the tools build with the upgraded toolchain. The
# `go install` steps fetch through the Go module proxy (proxy.golang.org),
# which the Trusted list already permits. Everything installs with
# GOBIN=/usr/local/bin so the binaries are on PATH for every kind of session
# shell (login, interactive, and plain `bash -c`).
install_go_tools() {
  command -v go >/dev/null 2>&1 || { warn "go not found; skipping Go tools"; return; }
  log "Go tools (goimports, staticcheck, gopls)"
  # The three `go install`s run concurrently: gopls is a large build and,
  # queued behind the other two, it has run past the ~5 minute budget before
  # (it was missing from the snapshot while goimports and staticcheck landed).
  # Go's build and module caches are concurrency-safe, so they can share them.
  GOBIN=/usr/local/bin go install golang.org/x/tools/cmd/goimports@latest \
    || warn "goimports install failed" &
  GOBIN=/usr/local/bin go install honnef.co/go/tools/cmd/staticcheck@latest \
    || warn "staticcheck install failed" &
  GOBIN=/usr/local/bin go install golang.org/x/tools/gopls@latest \
    || warn "gopls install failed" &
  wait
}

# The Go tools this script installs land in /usr/local/bin (already on PATH),
# but anything a user `go install`s in a later session goes to GOBIN, or
# $GOPATH/bin when GOBIN is unset (default $HOME/go/bin) -- which is NOT on
# PATH, so the freshly installed tool isn't found. Drop a /etc/profile.d
# snippet (captured in the snapshot) that resolves the effective Go bin dir at
# shell start and prepends it. Resolving at login (rather than baking an
# absolute path here) keeps it correct whatever user/$HOME the session runs as.
#
# /etc/profile.d only covers *login* shells, but session shells are usually
# non-login interactive bash (which reads /etc/bash.bashrc instead), so the
# snippet is hooked into /etc/bash.bashrc too. Finally, any Go binaries already
# sitting in the snapshot's GOBIN/GOPATH bin are symlinked into /usr/local/bin
# so they resolve even from shells that read neither file (plain `bash -c`).
configure_go_path() {
  log "Go PATH (surface GOBIN / GOPATH bin on PATH)"
  cat > /etc/profile.d/go-path.sh <<'EOF'
# Ensure `go install`ed tools (GOBIN, or $GOPATH/bin when GOBIN is unset) are
# on PATH. Managed by the Claude Code on the web setup script.
if command -v go >/dev/null 2>&1; then
  _go_bin="$(go env GOBIN 2>/dev/null)"
  [ -n "${_go_bin}" ] || _go_bin="$(go env GOPATH 2>/dev/null)/bin"
  if [ -n "${_go_bin}" ]; then
    case ":${PATH}:" in
      *":${_go_bin}:"*) ;;
      *) export PATH="${_go_bin}:${PATH}" ;;
    esac
  fi
  unset _go_bin
fi
EOF
  chmod 0644 /etc/profile.d/go-path.sh \
    || warn "could not write /etc/profile.d/go-path.sh"

  # Non-login interactive shells skip /etc/profile.d, so source the snippet
  # from /etc/bash.bashrc as well. Prepend it ahead of Ubuntu's interactivity
  # guard ([ -z "$PS1" ] && return) so even sourced non-interactive shells run
  # it. Guarded by grep for idempotency across cache rebuilds.
  if ! grep -q 'profile\.d/go-path\.sh' /etc/bash.bashrc 2>/dev/null; then
    {
      printf '%s\n' '[ -f /etc/profile.d/go-path.sh ] && . /etc/profile.d/go-path.sh' \
        | cat - /etc/bash.bashrc > /etc/bash.bashrc.go-path \
        && mv /etc/bash.bashrc.go-path /etc/bash.bashrc
    } || warn "could not hook go-path.sh into /etc/bash.bashrc"
  fi

  # Symlink whatever is already in the effective Go bin dir (e.g. tools the
  # base image pre-installed under ~/go/bin) into /usr/local/bin so they are
  # found regardless of how the session shell was started. Existing names in
  # /usr/local/bin are left alone.
  command -v go >/dev/null 2>&1 || return 0
  local go_bin
  go_bin="$(go env GOBIN 2>/dev/null)"
  [ -n "${go_bin}" ] || go_bin="$(go env GOPATH 2>/dev/null)/bin"
  if [ -n "${go_bin}" ] && [ "${go_bin}" != "/bin" ] && [ -d "${go_bin}" ]; then
    local tool
    for tool in "${go_bin}"/*; do
      [ -x "${tool}" ] && [ ! -e "/usr/local/bin/$(basename "${tool}")" ] \
        && ln -s "${tool}" "/usr/local/bin/$(basename "${tool}")"
    done
  fi
  return 0
}

# Python CLI tools install with `uv tool install`, which gives each tool its
# own virtualenv under /opt/uv-tools and links the entry point into
# /usr/local/bin. That keeps their pinned dependencies (semgrep pins many) out
# of the shared site-packages, where `pip install --ignore-installed` could
# silently downgrade packages a project relies on. pip is the fallback if the
# image ever drops uv. Both fetch from PyPI (Trusted).
install_python_tool() {
  local tool="$1"
  if command -v uv >/dev/null 2>&1; then
    UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin \
      uv tool install --quiet --force "${tool}" \
      || warn "${tool} install failed"
  else
    python3 -m pip install --quiet --ignore-installed "${tool}" \
      || warn "${tool} install failed"
  fi
}

install_semgrep() {
  log "semgrep (PyPI)"
  install_python_tool semgrep
}

install_fly() {
  command -v fly >/dev/null 2>&1 && { log "flyctl already present"; return; }
  log "flyctl"
  curl -fsSL https://fly.io/install.sh | FLYCTL_INSTALL=/usr/local sh \
    || warn "flyctl install failed (is fly.io on the allowlist?)"
}

# --- Docker image development tooling -------------------------------------
# Docker itself ships in the base image; these add the tools for *authoring*
# and inspecting images. All three pull prebuilt binaries from GitHub release
# assets (github.com + *.githubusercontent.com), which the
# Trusted network level already permits — no extra allowlist domains needed.

# hadolint: Dockerfile linter. Ships as a single static binary whose asset name
# is stable under /releases/latest/download, so no version lookup is needed.
install_hadolint() {
  command -v hadolint >/dev/null 2>&1 && { log "hadolint already present"; return; }
  log "hadolint (Dockerfile linter)"
  if curl -fsSL -o /usr/local/bin/hadolint \
       "https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64"; then
    chmod +x /usr/local/bin/hadolint
  else
    warn "hadolint install failed"
  fi
}

# dive: explore image layers and find wasted space. Release assets embed the
# version in their filename, so the latest tag has to be resolved first. We read
# it from the redirect github.com/<repo>/releases/latest issues to the tag page,
# NOT from api.github.com: the API is rate-limited per IP for unauthenticated
# callers and 403s mid-build (which is why dive was the one tool missing from
# the snapshot while every /releases/latest/download step succeeded).
install_dive() {
  command -v dive >/dev/null 2>&1 && { log "dive already present"; return; }
  log "dive (image layer explorer)"
  local ver
  ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
         https://github.com/wagoodman/dive/releases/latest \
         | sed -nE 's#.*/releases/tag/v?([^/]+)$#\1#p')"
  # Fallback: dive is a Go module, so the Go module proxy (Trusted, not
  # rate-limited) also knows its latest tag.
  [ -n "${ver}" ] || ver="$(curl -fsSL \
         https://proxy.golang.org/github.com/wagoodman/dive/@latest \
         | sed -nE 's#.*"Version":"v?([^"]+)".*#\1#p')"
  if [ -z "${ver}" ]; then
    warn "dive install failed (could not resolve latest version)"; return
  fi
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/dive.tar.gz" \
       "https://github.com/wagoodman/dive/releases/download/v${ver}/dive_${ver}_linux_amd64.tar.gz" \
     && tar -C "${tmp}" -xzf "${tmp}/dive.tar.gz" dive \
     && [ -x "${tmp}/dive" ]; then
    install -m 0755 "${tmp}/dive" /usr/local/bin/dive
  else
    warn "dive install failed"
  fi
  rm -rf "${tmp}"
}

# trivy: scan images, filesystems and Dockerfiles for vulnerabilities and
# misconfigurations. Its installer pulls the matching release binary from GitHub.
install_trivy() {
  command -v trivy >/dev/null 2>&1 && { log "trivy already present"; return; }
  log "trivy (image / Dockerfile security scanner)"
  curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b /usr/local/bin \
    || warn "trivy install failed"
}

# --- Registry, supply-chain & CI workflow tooling -------------------------
# Tools for inspecting/signing container images, generating SBOMs, cutting
# releases, and linting/auditing CI. Every step here pulls from GitHub release
# assets or githubusercontent (Trusted) or PyPI/crates.io — no extra allowlist
# domains are needed beyond what the base steps already require. All use stable
# /releases/latest/download asset names, so none of them hit api.github.com
# (which is easily rate-limited and would 403 mid-build).

# crane: copy/inspect images and resolve tags to digests, from Google's
# go-containerregistry. The release tarball bundles crane/gcrane/krane; we
# extract just crane. Asset name is version-independent, so latest/download works.
install_crane() {
  command -v crane >/dev/null 2>&1 && { log "crane already present"; return; }
  log "crane (container registry client, go-containerregistry)"
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/gcr.tar.gz" \
       "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz" \
     && tar -C "${tmp}" -xzf "${tmp}/gcr.tar.gz" crane \
     && [ -x "${tmp}/crane" ]; then
    install -m 0755 "${tmp}/crane" /usr/local/bin/crane
  else
    warn "crane install failed"
  fi
  rm -rf "${tmp}"
}

# cosign: sign/verify container images and other artifacts (sigstore). Ships as
# a single static binary under the stable latest/download path, like hadolint.
install_cosign() {
  command -v cosign >/dev/null 2>&1 && { log "cosign already present"; return; }
  log "cosign (artifact signing, sigstore)"
  if curl -fsSL -o /usr/local/bin/cosign \
       "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"; then
    chmod +x /usr/local/bin/cosign
  else
    warn "cosign install failed"
  fi
}

# syft: generate SBOMs from images and filesystems (anchore). Its installer
# pulls the matching release binary from GitHub, like trivy's.
install_syft() {
  command -v syft >/dev/null 2>&1 && { log "syft already present"; return; }
  log "syft (SBOM generator, anchore)"
  curl -fsSL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
    | sh -s -- -b /usr/local/bin \
    || warn "syft install failed"
}

# goreleaser: build and publish release artifacts. The release tarball's asset
# name is version-independent, so latest/download works (no API lookup).
install_goreleaser() {
  command -v goreleaser >/dev/null 2>&1 && { log "goreleaser already present"; return; }
  log "goreleaser (release automation)"
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/goreleaser.tar.gz" \
       "https://github.com/goreleaser/goreleaser/releases/latest/download/goreleaser_Linux_x86_64.tar.gz" \
     && tar -C "${tmp}" -xzf "${tmp}/goreleaser.tar.gz" goreleaser \
     && [ -x "${tmp}/goreleaser" ]; then
    install -m 0755 "${tmp}/goreleaser" /usr/local/bin/goreleaser
  else
    warn "goreleaser install failed"
  fi
  rm -rf "${tmp}"
}

# trufflehog: scan repos/filesystems for verified secrets. Installer pulls the
# matching release binary from GitHub.
install_trufflehog() {
  command -v trufflehog >/dev/null 2>&1 && { log "trufflehog already present"; return; }
  log "trufflehog (secret scanner)"
  curl -fsSL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
    | sh -s -- -b /usr/local/bin \
    || warn "trufflehog install failed"
}

# actionlint: lint GitHub Actions workflow files. Its download script grabs a
# prebuilt binary (no Go build); args are [version] [target-dir].
install_actionlint() {
  command -v actionlint >/dev/null 2>&1 && { log "actionlint already present"; return; }
  log "actionlint (GitHub Actions workflow linter)"
  curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash \
    | bash -s -- latest /usr/local/bin \
    || warn "actionlint install failed"
}

# pre-commit: the git-hook framework many repos drive their lint/format checks
# through (`make hooks`). Installed from PyPI, mirroring the semgrep step.
install_precommit() {
  command -v pre-commit >/dev/null 2>&1 && { log "pre-commit already present"; return; }
  log "pre-commit (git hook framework, PyPI)"
  install_python_tool pre-commit
}

# apt holds the dpkg lock, so run it to completion first, then fan out the
# independent downloads in parallel and wait for all of them.
install_apt

install_semgrep &
install_fly &
install_uv &
install_bun &
# Docker image development tools (all from GitHub, independent downloads).
install_hadolint &
install_dive &
install_trivy &
# Registry / supply-chain / CI tooling (all from GitHub, PyPI, independent).
install_crane &
install_cosign &
install_syft &
install_goreleaser &
install_trufflehog &
install_actionlint &
install_golangci_lint &
install_zizmor &
install_precommit &
# cargo-binstall has no in-script consumers; it is installed so sessions can
# `cargo binstall` further cargo tools as prebuilt binaries.
install_cargo_binstall &
# Go toolchain upgrade and the Go tools must run in sequence (the tools build
# against the new toolchain, and we must not swap /usr/local/go while a build
# is reading it); the pair runs in parallel with everything else.
( install_go; install_go_tools; configure_go_path ) &
wait

# One line listing anything that didn't make it into the snapshot, so a
# failed step is easy to spot in the setup logs without scrolling for its
# warning. Informational only: it never fails the script.
missing=()
for tool in gh shellcheck skopeo semgrep pre-commit uv bun go golangci-lint \
            goimports staticcheck gopls cargo-binstall fly hadolint dive \
            trivy crane cosign syft \
            goreleaser trufflehog actionlint zizmor; do
  command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if [ "${#missing[@]}" -gt 0 ]; then
  warn "missing after setup: ${missing[*]}"
fi

log "done in ${SECONDS}s"
# A non-zero exit fails session start; failures above are already warnings.
exit 0
