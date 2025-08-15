#!/usr/bin/env bash
set -euo pipefail

# Defaults (override via env or flags)
NVIM_VERSION="${NVIM_VERSION:-v0.10.4}"
NVIM_ARCH="${NVIM_ARCH:-auto}"
NVIM_INSTALL_METHOD="${NVIM_INSTALL_METHOD:-appimage}"
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
          [--method appimage|tarball|apt] [--no-rc] [--no-pyright] [--force]

Options:
  --nvim-version    Neovim release tag (default: ${NVIM_VERSION})
  --arch            Target architecture: auto|x86_64|arm64 (default: ${NVIM_ARCH})
  --install-dir     Base install dir for Neovim (default: ${INSTALL_DIR})
  --config-repo     Git URL to your nvim config (default: ${NVIM_CONFIG_REPO})
  --config-branch   Branch to use (default: ${NVIM_CONFIG_BRANCH})
  --config-dest     Destination dir for config (default: ${NVIM_CONFIG_DEST})
  --method          Install method: appimage|tarball|apt (default: ${NVIM_INSTALL_METHOD})
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
    --method) NVIM_INSTALL_METHOD="$2"; shift 2;;
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
      curl tar ripgrep xclip clangd unzip python3-pip git openssh-client \
      software-properties-common fuse3
    # AppImage needs FUSE v2 runtime (libfuse.so.2). Try both names safely.
    ${SUDO} apt-get install -y libfuse2 || ${SUDO} apt-get install -y libfuse2t64 || true
  else
    echo "apt-get not found. Please install: curl tar ripgrep xclip clangd unzip python3-pip git openssh-client software-properties-common fuse3"
  fi
}

install_nvim_via_apt() {
  echo "Installing Neovim via APT (fallback for unsupported GLIBC)..."
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y software-properties-common
  if ! need_cmd add-apt-repository; then
    echo "add-apt-repository not found after installing software-properties-common"
    exit 1
  fi
  ${SUDO} add-apt-repository -y ppa:neovim-ppa/stable
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y neovim
}

install_nvim_appimage() {
  local arch="${NVIM_ARCH}"
  if [[ "${arch}" == "auto" || -z "${arch}" ]]; then
    local m
    m="$(uname -m || true)"
    case "${m}" in
      x86_64|amd64) arch="x86_64";;
      aarch64|arm64) arch="arm64";;
      *) echo "Unsupported architecture detected: ${m}. Use --arch x86_64 or --arch arm64."; return 1;;
    esac
  else
    case "${arch}" in
      x86_64|amd64) arch="x86_64";;
      arm64|aarch64) arch="arm64";;
      *) echo "Invalid --arch '${arch}'. Use auto|x86_64|arm64."; return 1;;
    esac
  fi

  local appimage_name url tmp target_dir target_bin
  if [[ "${arch}" == "x86_64" ]]; then
    appimage_name="nvim-linux-x86_64.appimage"
  else
    appimage_name="nvim-linux-arm64.appimage"
  fi
  url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/${appimage_name}"

  echo "Downloading Neovim AppImage ${NVIM_VERSION} for ${arch}..."
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  if ! curl -fL -o "${tmp}/nvim.appimage" "${url}"; then
    if [[ "${arch}" == "x86_64" ]]; then
      # Fallback older name
      curl -fL -o "${tmp}/nvim.appimage" "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim.appimage" || return 1
    else
      return 1
    fi
  fi

  target_dir="${INSTALL_DIR}/nvim-appimage"
  target_bin="${target_dir}/nvim"
  ${SUDO} mkdir -p "${target_dir}"
  ${SUDO} rm -f "${target_bin}"
  ${SUDO} mv "${tmp}/nvim.appimage" "${target_bin}"
  ${SUDO} chmod 0755 "${target_bin}"
  echo "Installed Neovim AppImage to ${target_bin}"
  # If FUSE v2 (libfuse.so.2) is missing, extract and use the embedded nvim instead
  if ! "${target_bin}" --version >/dev/null 2>&1; then
    echo "AppImage cannot run (likely missing libfuse.so.2). Extracting contents..."
    (cd "${target_dir}" && ${SUDO} "${target_bin}" --appimage-extract >/dev/null 2>&1 || true)
    if [[ -x "${target_dir}/squashfs-root/usr/bin/nvim" ]]; then
      echo "Using extracted Neovim at ${target_dir}/squashfs-root/usr/bin/nvim"
    else
      echo "Extraction failed; consider installing libfuse2. See FUSE docs."
      return 1
    fi
  fi
  return 0
}


install_nvim_tarball() {
  local arch="${NVIM_ARCH}"
  if [[ "${arch}" == "auto" || -z "${arch}" ]]; then
    local m
    m="$(uname -m || true)"
    case "${m}" in
      x86_64|amd64) arch="x86_64";;
      aarch64|arm64) arch="arm64";;
      *) echo "Unsupported architecture detected: ${m}. Use --arch x86_64 or --arch arm64."; return 1;;
    esac
  else
    case "${arch}" in
      x86_64|amd64) arch="x86_64";;
      arm64|aarch64) arch="arm64";;
      *) echo "Invalid --arch '${arch}'. Use auto|x86_64|arm64."; return 1;;
    esac
  fi

  local glibc_ver
  glibc_ver="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')" || true
  if [[ -z "${glibc_ver}" ]]; then
    glibc_ver="$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
  fi
  if [[ -z "${glibc_ver}" ]] || ! dpkg --compare-versions "${glibc_ver}" ge "2.38"; then
    echo "Detected GLIBC ${glibc_ver:-unknown} (< 2.38). Falling back to APT install."
    install_nvim_via_apt
    return $?
  fi

  local tmp url primary_fallback
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  echo "Downloading Neovim ${NVIM_VERSION} tarball for ${arch}..."
  if [[ "${arch}" == "x86_64" ]]; then
    url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux64.tar.gz"
    primary_fallback="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz"
    if ! curl -fL -o "${tmp}/nvim.tar.gz" "${url}"; then
      curl -fL -o "${tmp}/nvim.tar.gz" "${primary_fallback}" || return 1
    fi
  else
    url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-arm64.tar.gz"
    curl -fL -o "${tmp}/nvim.tar.gz" "${url}" || return 1
  fi

  echo "Installing Neovim tarball to ${INSTALL_DIR}..."
  ${SUDO} rm -rf "${INSTALL_DIR}/nvim-linux64" "${INSTALL_DIR}/nvim-linux-x86_64" "${INSTALL_DIR}/nvim-linux-arm64" 2>/dev/null || true
  ${SUDO} tar -C "${INSTALL_DIR}" -xzf "${tmp}/nvim.tar.gz"
  if [[ -d "${INSTALL_DIR}/nvim-linux-x86_64" && ! -d "${INSTALL_DIR}/nvim-linux64" ]]; then
    ${SUDO} mv "${INSTALL_DIR}/nvim-linux-x86_64" "${INSTALL_DIR}/nvim-linux64"
  fi
  if [[ -d "${INSTALL_DIR}/nvim-linux-arm64" && ! -d "${INSTALL_DIR}/nvim-linux64" ]]; then
    ${SUDO} mv "${INSTALL_DIR}/nvim-linux-arm64" "${INSTALL_DIR}/nvim-linux64"
  fi
  [[ -x "${INSTALL_DIR}/nvim-linux64/bin/nvim" ]] || { echo "Neovim binary not found after extraction."; return 1; }
  return 0
}

ensure_nvim() {
  local target_app="${INSTALL_DIR}/nvim-appimage/nvim"
  local target_tar="${INSTALL_DIR}/nvim-linux64/bin/nvim"
  if [[ ( -x "${target_app}" || -x "${target_tar}" ) && "${FORCE_INSTALL}" -ne 1 ]]; then
    echo "Neovim already present. Skipping install. Use --force to reinstall."
    return 0
  fi

  local method="${NVIM_INSTALL_METHOD}"
  case "${method}" in
    appimage|AppImage)
      install_nvim_appimage || {
        echo "AppImage install failed. Falling back to tarball..."
        install_nvim_tarball || {
          echo "Tarball install failed. Falling back to APT..."
          install_nvim_via_apt
        }
      }
      ;;
    tarball)
      install_nvim_tarball || install_nvim_via_apt
      ;;
    apt|APT)
      install_nvim_via_apt
      ;;
    *)
      echo "Unknown install method '${method}'. Use appimage|tarball|apt."
      return 1
      ;;
  esac
}

 
link_nvim_bin() {
  local target=""
  if [[ -x "${INSTALL_DIR}/nvim-appimage/squashfs-root/usr/bin/nvim" ]]; then
    target="${INSTALL_DIR}/nvim-appimage/squashfs-root/usr/bin/nvim"
  elif [[ -x "${INSTALL_DIR}/nvim-appimage/nvim" ]]; then
    target="${INSTALL_DIR}/nvim-appimage/nvim"
  elif [[ -x "${INSTALL_DIR}/nvim-linux64/bin/nvim" ]]; then
    target="${INSTALL_DIR}/nvim-linux64/bin/nvim"
  elif command -v nvim >/dev/null 2>&1; then
    return 0
  else
    echo "No Neovim binary found to link."
    return 1
  fi
  local link="/usr/local/bin/nvim"
  ${SUDO} mkdir -p "$(dirname "${link}")"
  ${SUDO} rm -f "${link}"
  ${SUDO} ln -s "${target}" "${link}"
  echo "Symlinked ${link} -> ${target}"
}
 

ensure_path_rc() {
  local bin_tar="${INSTALL_DIR}/nvim-linux64/bin"
  local bin_app="${INSTALL_DIR}/nvim-appimage"

  # Only add PATH if any layout exists
  if [[ ! -d "${bin_tar}" && ! -d "${bin_app}" ]]; then
    return 0
  fi

  if [[ "${ADD_TO_SHELL_RC}" -eq 0 ]]; then
    [[ -d "${bin_tar}" ]] && export PATH="${PATH}:${bin_tar}"
    [[ -d "${bin_app}" ]] && export PATH="${PATH}:${bin_app}"
    return 0
  fi

  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if [[ -d "${bin_tar}" ]] && ! grep -Fq "${bin_tar}" "$rc"; then
      echo "export PATH=\"\$PATH:${bin_tar}\"" >> "$rc"
      echo "Appended PATH to ${rc} (tarball bin)"
    fi
    if [[ -d "${bin_app}" ]] && ! grep -Fq "${bin_app}" "$rc"; then
      echo "export PATH=\"\$PATH:${bin_app}\"" >> "$rc"
      echo "Appended PATH to ${rc} (appimage bin)"
    fi
  done

  [[ -d "${bin_tar}" ]] && export PATH="${PATH}:${bin_tar}"
  [[ -d "${bin_app}" ]] && export PATH="${PATH}:${bin_app}"
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
  link_nvim_bin
  ensure_path_rc
  setup_nvim_config_from_repo
  install_pyright

  echo "Neovim version:"
  if command -v nvim >/dev/null 2>&1; then
    nvim --version | head -n1
  elif [[ -x "${INSTALL_DIR}/nvim-appimage/nvim" ]]; then
    "${INSTALL_DIR}/nvim-appimage/nvim" --version | head -n1 || true
  elif [[ -x "${INSTALL_DIR}/nvim-linux64/bin/nvim" ]]; then
    "${INSTALL_DIR}/nvim-linux64/bin/nvim" --version | head -n1 || true
  fi
  echo "Done."
}

main "$@"