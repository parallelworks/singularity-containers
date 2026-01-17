#!/usr/bin/env bash
set -euo pipefail

# Standalone reference installer; primary entrypoint is scripts/sif_parts.sh install-lfs.

version_lt() {
  local left="$1" right="$2"
  local -a left_parts right_parts
  local i max

  IFS=. read -r -a left_parts <<< "$left"
  IFS=. read -r -a right_parts <<< "$right"
  max="${#left_parts[@]}"
  if (( ${#right_parts[@]} > max )); then
    max="${#right_parts[@]}"
  fi

  for ((i = 0; i < max; i++)); do
    local left_val="${left_parts[i]:-0}"
    local right_val="${right_parts[i]:-0}"
    if ((10#$left_val < 10#$right_val)); then
      return 0
    fi
    if ((10#$left_val > 10#$right_val)); then
      return 1
    fi
  done
  return 1
}

if git lfs version >/dev/null 2>&1; then
  echo "git-lfs already available."
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git not found." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required to download git-lfs." >&2
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "ERROR: tar is required to extract git-lfs." >&2
  exit 1
fi

git_version="$(git --version | awk '{print $3}')"
git_version="${git_version%%[^0-9.]*}"
git_version="${git_version%.}"
if [[ -z "$git_version" ]]; then
  echo "ERROR: Unable to determine git version." >&2
  exit 1
fi

install_if_lt="${SIF_LFS_INSTALL_IF_GIT_LT:-2.13.0}"
if ! version_lt "$git_version" "$install_if_lt"; then
  echo "git $git_version is new enough; skipping local git-lfs install."
  echo "Install git-lfs via your package manager or set SIF_LFS_INSTALL_IF_GIT_LT higher."
  exit 1
fi

mkdir -p "$HOME/bin"

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

release_url="$(
  curl -s https://api.github.com/repos/git-lfs/git-lfs/releases/latest \
    | grep browser_download_url \
    | grep linux-amd64 \
    | grep -E '\.tar\.gz"$' \
    | cut -d '"' -f 4 \
    | head -n 1
)"

if [[ -z "$release_url" ]]; then
  echo "ERROR: Unable to find linux-amd64 git-lfs release URL." >&2
  exit 1
fi

archive_path="${tmp_dir}/git-lfs.tar.gz"
if command -v wget >/dev/null 2>&1; then
  wget -qO "$archive_path" "$release_url"
else
  curl -sL -o "$archive_path" "$release_url"
fi

tar -xzf "$archive_path" -C "$tmp_dir"

install_dir="$(echo "$tmp_dir"/git-lfs-*)"
if [[ ! -d "$install_dir" ]]; then
  echo "ERROR: git-lfs archive did not contain expected directory." >&2
  exit 1
fi

(
  cd "$install_dir"
  ./install.sh --local
)

echo "git-lfs installed to $HOME/bin. Ensure $HOME/bin is on PATH."
