#!/usr/bin/env bash
# Update apt, install git plus common terminal tools, and configure git to save credentials automatically.
set -euo pipefail

sudo apt update
sudo apt install -y \
  git \
  curl \
  wget \
  ca-certificates \
  tree \
  neovim \
  tmux \
  htop \
  jq \
  ripgrep \
  fd-find \
  bat \
  fzf \
  ncdu \
  rsync \
  zip \
  unzip \
  less \
  man-db \
  build-essential

# Save credentials to ~/.git-credentials after first successful auth
git config --global credential.helper store

echo "git $(git --version | awk '{print $3}') installed; credentials will be saved on next login."

curl -fsSL https://claude.ai/install.sh | bash
