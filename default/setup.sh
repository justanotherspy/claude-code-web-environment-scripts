#!/bin/bash
set -euo pipefail

apt update || true
apt install -y gh shellcheck
python3 -m pip install semgrep --ignore-installed

if ! command -v fly &>/dev/null; then
  curl -L https://fly.io/install.sh | FLYCTL_INSTALL=/usr/local sh
fi

curl -fsSL https://sprites.dev/install.sh | sh
curl -fsSL https://raw.githubusercontent.com/justanotherspy/shuck/main/install.sh | SHUCK_VERSION=v0.3.5 bash
