#!/usr/bin/env bash
#
# Claude Code on the web — setup script for the ACME simulation environment.
#
# A dedicated cloud environment for the ACME incident-response demo
# (justanotherspy/acme-sim, acme-bot, oncall-kit). It keeps AWS access out of
# the default environment. It is deliberately leaner than default/setup.sh:
# the Go toolchain (the app is Go), shell/CI/container linters, and the
# AWS / Kubernetes / Terraform / Argo CD CLIs, for writing and checking IaC and
# manifests offline. The environment holds no AWS or cluster credentials:
# Claude reads AWS through the AWS MCP connector, and humans run Terraform and
# kubectl against the account (see acme/credentials.example).
#
# Same rules as default/setup.sh (see README.md and CLAUDE.md): runs once as
# root on Ubuntu 24.04 before Claude Code launches; every step is non-fatal
# (no `set -e`); downloads go through the curl() wrapper; versions never come
# from api.github.com; always ends with `exit 0`. Shared install functions are
# copied from default/setup.sh, so fix a bug in one, fix it in both.
#
# Docs: https://code.claude.com/docs/en/claude-code-on-the-web#setup-scripts
#
# ---------------------------------------------------------------------------
# NETWORK ACCESS
# ---------------------------------------------------------------------------
# Use "Full" network access, or "Custom" with default package managers enabled
# plus these hosts (the rest come from GitHub / the Go module proxy):
#     Go tarball  -> dl.google.com   (go.dev/dl redirects here)
#     aws CLI     -> awscli.amazonaws.com
#     kubectl     -> dl.k8s.io / cdn.dl.k8s.io
#     helm        -> get.helm.sh
#     terraform   -> checkpoint-api.hashicorp.com / releases.hashicorp.com
#     golangci    -> golangci-lint.run (fallback installer only)
# Sessions also need the AWS API hosts at runtime: *.amazonaws.com
# (sts.eu-west-1, eks.eu-west-1 and the cluster's *.eks.amazonaws.com endpoint).
# ---------------------------------------------------------------------------

set -uo pipefail

# Optional: set SETUP_DEBUG=1 in the environment variables to trace commands.
[ "${SETUP_DEBUG:-0}" = "1" ] && set -x

export DEBIAN_FRONTEND=noninteractive

# Go toolchain, kept in step with default/setup.sh by Renovate; overridable
# with GO_VERSION.
GO_VERSION="${GO_VERSION:-1.27.3}"

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

# unzip is needed by the AWS CLI and terraform zips; gh ships in the image but
# is listed in case it drops out.
install_apt() {
  local want=(gh:gh unzip:unzip)
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

# --- Go toolchain -----------------------------------------------------------

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
#
# The image ships an older golangci-lint, so compare versions rather than
# skipping whenever one is on PATH.
install_golangci_lint() {
  local ver tmp have
  ver="$(curl -fsSL https://proxy.golang.org/github.com/golangci/golangci-lint/v2/@latest \
    | sed -nE 's#.*"Version":"v([^"]+)".*#\1#p')"
  have="$(golangci-lint --version 2>/dev/null | sed -nE 's#.* version ([0-9][^ ]*).*#\1#p')"
  if [ -n "${have}" ] && { [ -z "${ver}" ] || [ "${have}" = "${ver}" ]; }; then
    log "golangci-lint ${have} already present"
    return
  fi
  log "golangci-lint ${ver:-latest} (Go linter)"
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

# --- Linters ----------------------------------------------------------------

# ShellCheck: the latest release, which upstream also publishes under the
# fixed `stable` tag, so no version lookup is needed. Installed to
# /usr/local/bin, ahead of the image's older apt copy in /usr/bin.
install_shellcheck() {
  log "shellcheck (latest stable release)"
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/shellcheck.tar.xz" \
       https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz \
     && tar -C "${tmp}" -xJf "${tmp}/shellcheck.tar.xz" shellcheck-stable/shellcheck \
     && [ -x "${tmp}/shellcheck-stable/shellcheck" ]; then
    install -m 0755 "${tmp}/shellcheck-stable/shellcheck" /usr/local/bin/shellcheck
  else
    warn "shellcheck install failed"
  fi
  rm -rf "${tmp}"
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

# trivy: scan images, filesystems and Dockerfiles for vulnerabilities and
# misconfigurations. Its installer pulls the matching release binary from GitHub.
install_trivy() {
  command -v trivy >/dev/null 2>&1 && { log "trivy already present"; return; }
  log "trivy (image / Dockerfile security scanner)"
  curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b /usr/local/bin \
    || warn "trivy install failed"
}

# --- Cloud / Kubernetes tooling ---------------------------------------------
# For the ACME simulation: read-only AWS and kubectl access to its EKS cluster.
# None of these ship in the image. Each version comes from the vendor's own
# "latest" endpoint, never api.github.com.

# AWS CLI v2: the official installer bundle (version-independent URL). Needs
# unzip, which install_apt provides. --update makes a rebuild upgrade in place.
install_awscli() {
  log "aws (AWS CLI v2)"
  local tmp
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/awscliv2.zip" https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
     && unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"; then
    "${tmp}/aws/install" --update -i /usr/local/aws-cli -b /usr/local/bin >/dev/null \
      || warn "aws CLI install failed"
  else
    warn "aws CLI download failed (is awscli.amazonaws.com on the allowlist?)"
  fi
  rm -rf "${tmp}"
}

# kubectl: latest stable from dl.k8s.io, checked against its published sha256.
# kubectl has kustomize built in (`kubectl kustomize`, `kubectl apply -k`).
install_kubectl() {
  local ver tmp
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  case "${ver}" in
    v1.*) ;;
    *) warn "kubectl install failed (could not resolve stable version)"; return ;;
  esac
  if kubectl version --client 2>/dev/null | grep -q "Client Version: ${ver}$"; then
    log "kubectl ${ver} already present"; return
  fi
  log "kubectl ${ver}"
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/kubectl" "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl" \
     && curl -fsSL -o "${tmp}/kubectl.sha256" "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl.sha256" \
     && echo "$(cat "${tmp}/kubectl.sha256")  ${tmp}/kubectl" | sha256sum -c --status; then
    install -m 0755 "${tmp}/kubectl" /usr/local/bin/kubectl
  else
    warn "kubectl ${ver} install failed (is dl.k8s.io on the allowlist?)"
  fi
  rm -rf "${tmp}"
}

# helm: get.helm.sh publishes the latest tag at a fixed URL, so no GitHub
# lookup is needed. Checked against the published sha256.
install_helm() {
  local ver tmp asset
  ver="$(curl -fsSL https://get.helm.sh/helm-latest-version)"
  case "${ver}" in
    v[0-9]*) ;;
    *) warn "helm install failed (could not resolve latest version)"; return ;;
  esac
  if helm version --short 2>/dev/null | grep -q "^${ver}+"; then
    log "helm ${ver} already present"; return
  fi
  log "helm ${ver}"
  asset="helm-${ver}-linux-amd64.tar.gz"
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/${asset}" "https://get.helm.sh/${asset}" \
     && curl -fsSL -o "${tmp}/${asset}.sha256sum" "https://get.helm.sh/${asset}.sha256sum" \
     && (cd "${tmp}" && sha256sum -c --status "${asset}.sha256sum") \
     && tar -C "${tmp}" -xzf "${tmp}/${asset}" linux-amd64/helm; then
    install -m 0755 "${tmp}/linux-amd64/helm" /usr/local/bin/helm
  else
    warn "helm ${ver} install failed (is get.helm.sh on the allowlist?)"
  fi
  rm -rf "${tmp}"
}

# terraform: the latest version comes from HashiCorp's checkpoint API, the zip
# from releases.hashicorp.com, checked against the release's SHA256SUMS.
install_terraform() {
  local ver tmp zip
  ver="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform \
    | jq -r '.current_version // empty' 2>/dev/null)"
  case "${ver}" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) warn "terraform install failed (could not resolve latest version)"; return ;;
  esac
  if terraform version 2>/dev/null | head -n 1 | grep -q "^Terraform v${ver}$"; then
    log "terraform ${ver} already present"; return
  fi
  log "terraform ${ver}"
  zip="terraform_${ver}_linux_amd64.zip"
  tmp="$(mktemp -d)"
  if curl -fsSL -o "${tmp}/${zip}" "https://releases.hashicorp.com/terraform/${ver}/${zip}" \
     && curl -fsSL -o "${tmp}/SHA256SUMS" "https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_SHA256SUMS" \
     && (cd "${tmp}" && grep " ${zip}$" SHA256SUMS | sha256sum -c --status) \
     && unzip -q -o "${tmp}/${zip}" terraform -d "${tmp}"; then
    install -m 0755 "${tmp}/terraform" /usr/local/bin/terraform
  else
    warn "terraform ${ver} install failed (are releases.hashicorp.com and checkpoint-api.hashicorp.com on the allowlist?)"
  fi
  rm -rf "${tmp}"
}

# argocd CLI: version-independent release asset, so latest/download works.
install_argocd() {
  command -v argocd >/dev/null 2>&1 && { log "argocd already present"; return; }
  log "argocd (Argo CD CLI)"
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL -o "${tmp}" \
       https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 \
     && [ -s "${tmp}" ]; then
    install -m 0755 "${tmp}" /usr/local/bin/argocd
  else
    warn "argocd install failed"
  fi
  rm -f "${tmp}"
}

# apt holds the dpkg lock, so run it to completion first, then fan out the
# independent downloads in parallel and wait for all of them.
install_apt

install_awscli &
install_kubectl &
install_helm &
install_terraform &
install_argocd &
install_shellcheck &
install_actionlint &
install_hadolint &
install_trivy &
install_golangci_lint &
# The Go tools build against the new toolchain, so they run after it.
( install_go; install_go_tools; configure_go_path ) &
wait

# One line listing anything that didn't make it into the snapshot.
# Informational only: it never fails the script.
missing=()
for tool in aws kubectl helm terraform argocd go golangci-lint goimports \
            staticcheck gopls shellcheck actionlint hadolint trivy gh unzip; do
  command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
go version 2>/dev/null | grep -q "go${GO_VERSION} " || missing+=("go${GO_VERSION}")
[ -x /usr/local/bin/shellcheck ] || missing+=("/usr/local/bin/shellcheck")
if [ "${#missing[@]}" -gt 0 ]; then
  warn "missing after setup: ${missing[*]}"
fi

log "done in ${SECONDS}s"
# A non-zero exit fails session start; failures above are already warnings.
exit 0
