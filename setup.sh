#!/usr/bin/env bash
set -euo pipefail

# Defaults (override via env or flags)
NVIM_VERSION="${NVIM_VERSION:-v0.10.4}"
NVIM_ARCH="${NVIM_ARCH:-auto}"
INSTALL_DIR="${INSTALL_DIR:-/opt}"
ADD_TO_SHELL_RC="${ADD_TO_SHELL_RC:-1}"
INSTALL_PYRIGHT="${INSTALL_PYRIGHT:-1}"
FORCE_INSTALL="${FORCE_INSTALL:-0}"

NVIM_CONFIG_REPO="${NVIM_CONFIG_REPO:-https://github.com/LazyVim/starter.git}"
NVIM_CONFIG_BRANCH="${NVIM_CONFIG_BRANCH:-main}"
NVIM_CONFIG_DEST="${NVIM_CONFIG_DEST:-${HOME}/.config/nvim}"

usage() {
  cat <<EOF
Usage: $0 [--nvim-version vX.Y.Z] [--arch auto|x86_64|arm64] [--install-dir /opt]
          [--config-repo URL] [--config-branch BRANCH] [--config-dest PATH]
          [--no-rc] [--no-pyright] [--force]

Options:
  --nvim-version    Neovim release tag (default: ${NVIM_VERSION})
  --arch            Target architecture: auto|x86_64|arm64 (default: ${NVIM_ARCH})
  --install-dir     Base install dir for Neovim (default: ${INSTALL_DIR})
  --config-repo     Git URL to your nvim config (default: ${NVIM_CONFIG_REPO})
  --config-branch   Branch to use (default: ${NVIM_CONFIG_BRANCH})
  --config-dest     Destination dir for config (default: ${NVIM_CONFIG_DEST})
  --no-rc           Do not modify shell RC files to add PATH
  --no-pyright      Skip installing pyright via pip
  --force           Reinstall Neovim even if already present
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nvim-version) NVIM_VERSION="$2"; shift 2;;
    --arch) NVIM_ARCH="$2"; shift 2;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --config-repo) NVIM_CONFIG_REPO="$2"; shift 2;;
    --config-branch) NVIM_CONFIG_BRANCH="$2"; shift 2;;
    --config-dest) NVIM_CONFIG_DEST="$2"; shift 2;;
    --no-rc) ADD_TO_SHELL_RC=0; shift;;
    --no-pyright) INSTALL_PYRIGHT=0; shift;;
    --force) FORCE_INSTALL=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script requires root privileges for package installs and writing to ${INSTALL_DIR}."
    exit 1
  fi
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  if need_cmd apt-get; then
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y \
      curl tar ripgrep xclip clangd unzip python3-pip git openssh-client
  else
    echo "apt-get not found. Please install: curl tar ripgrep xclip clangd unzip python3-pip git openssh-client"
  fi
}

ensure_nvim() {
  local target_dir="${INSTALL_DIR}/nvim-linux64"
  local target_bin="${target_dir}/bin/nvim"
  if [[ -x "${target_bin}" && "${FORCE_INSTALL}" -ne 1 ]]; then
    echo "Neovim already present at ${target_bin}. Skipping install. Use --force to reinstall."
    return 0
  fi
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  # Resolve architecture
  local arch="${NVIM_ARCH}"
  if [[ "${arch}" == "auto" || -z "${arch}" ]]; then
    local m
    m="$(uname -m || true)"
    case "${m}" in
      x86_64|amd64) arch="x86_64";;
      aarch64|arm64) arch="arm64";;
      *) echo "Unsupported architecture detected: ${m}. Use --arch x86_64 or --arch arm64."; exit 1;;
    esac
  else
    case "${arch}" in
      x86_64|amd64) arch="x86_64";;
      arm64|aarch64) arch="arm64";;
      *) echo "Invalid --arch '${arch}'. Use auto|x86_64|arm64."; exit 1;;
    esac
  fi

  echo "Downloading Neovim ${NVIM_VERSION} for ${arch}..."
  local url primary_fallback
  if [[ "${arch}" == "x86_64" ]]; then
    url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux64.tar.gz"
    primary_fallback="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz"
    if ! curl -fL -o "${tmp}/nvim.tar.gz" "${url}"; then
      curl -fL -o "${tmp}/nvim.tar.gz" "${primary_fallback}"
    fi
  else
    url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-arm64.tar.gz"
    curl -fL -o "${tmp}/nvim.tar.gz" "${url}"
  fi

  echo "Installing Neovim to ${INSTALL_DIR}..."
  ${SUDO} rm -rf "${INSTALL_DIR}/nvim-linux64" "${INSTALL_DIR}/nvim-linux-x86_64" "${INSTALL_DIR}/nvim-linux-arm64" 2>/dev/null || true
  ${SUDO} tar -C "${INSTALL_DIR}" -xzf "${tmp}/nvim.tar.gz"
  if [[ -d "${INSTALL_DIR}/nvim-linux-x86_64" && ! -d "${INSTALL_DIR}/nvim-linux64" ]]; then
    ${SUDO} mv "${INSTALL_DIR}/nvim-linux-x86_64" "${INSTALL_DIR}/nvim-linux64"
  fi
  if [[ -d "${INSTALL_DIR}/nvim-linux-arm64" && ! -d "${INSTALL_DIR}/nvim-linux64" ]]; then
    ${SUDO} mv "${INSTALL_DIR}/nvim-linux-arm64" "${INSTALL_DIR}/nvim-linux64"
  fi
  [[ -x "${target_bin}" ]] || { echo "Neovim binary not found after extraction."; exit 1; }
}

ensure_path_rc() {
  local bin_dir="${INSTALL_DIR}/nvim-linux64/bin"
  local line="export PATH=\"\$PATH:${bin_dir}\""
  if [[ "${ADD_TO_SHELL_RC}" -eq 0 ]]; then
    export PATH="${PATH}:${bin_dir}"
    return 0
  fi
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if ! grep -Fq "${bin_dir}" "$rc"; then
      echo "${line}" >> "$rc"
      echo "Appended PATH to ${rc}"
    fi
  done
  export PATH="${PATH}:${bin_dir}"
}

backup_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  mv "$d" "${d}.bak-${ts}"
  echo "Backed up ${d} to ${d}.bak-${ts}"
}

setup_nvim_config_from_repo() {
  mkdir -p "$(dirname "${NVIM_CONFIG_DEST}")"
  if [[ -d "${NVIM_CONFIG_DEST}/.git" ]]; then
    local remote
    remote="$(git -C "${NVIM_CONFIG_DEST}" remote get-url origin || true)"
    if [[ "${remote}" == "${NVIM_CONFIG_REPO}" ]]; then
      echo "Updating existing config at ${NVIM_CONFIG_DEST}..."
      git -C "${NVIM_CONFIG_DEST}" fetch --all --tags
      git -C "${NVIM_CONFIG_DEST}" checkout "${NVIM_CONFIG_BRANCH}"
      git -C "${NVIM_CONFIG_DEST}" pull --ff-only origin "${NVIM_CONFIG_BRANCH}" || git -C "${NVIM_CONFIG_DEST}" pull --rebase
      git -C "${NVIM_CONFIG_DEST}" submodule update --init --recursive || true
      rm -rf "${NVIM_CONFIG_DEST}/.git" || true
      return 0
    else
      echo "Config at ${NVIM_CONFIG_DEST} has different remote (${remote})."
      backup_dir "${NVIM_CONFIG_DEST}"
    fi
  elif [[ -d "${NVIM_CONFIG_DEST}" && ! -z "$(ls -A "${NVIM_CONFIG_DEST}" 2>/dev/null || true)" ]]; then
    backup_dir "${NVIM_CONFIG_DEST}"
  fi
  echo "Cloning ${NVIM_CONFIG_REPO} into ${NVIM_CONFIG_DEST} (branch: ${NVIM_CONFIG_BRANCH})..."
  git clone --branch "${NVIM_CONFIG_BRANCH}" --depth 1 "${NVIM_CONFIG_REPO}" "${NVIM_CONFIG_DEST}"
  git -C "${NVIM_CONFIG_DEST}" submodule update --init --recursive || true
  rm -rf "${NVIM_CONFIG_DEST}/.git" || true
}

install_pyright() {
  if [[ "${INSTALL_PYRIGHT}" -eq 0 ]]; then
    return 0
  fi
  if command -v pipx >/dev/null 2>&1; then
    pipx install pyright || pipx upgrade pyright || true
  else
    pip3 install --user --upgrade pyright || true
  fi
}

main() {
  apt_install
  ensure_nvim
  ensure_path_rc
  setup_nvim_config_from_repo
  install_pyright

  echo "Neovim version:"
  if command -v nvim >/dev/null 2>&1; then
    nvim --version | head -n1
  else
    "${INSTALL_DIR}/nvim-linux64/bin/nvim" --version | head -n1 || true
  fi
  echo "Done."
}

main "$@"