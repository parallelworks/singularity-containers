#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/sif_parts.sh split --input /path/to/file.sif [options]
  scripts/sif_parts.sh join --prefix vllm [options]
  scripts/sif_parts.sh install-lfs

Commands:
  split   Split a SIF into numeric parts like vllm/vllm.00001.sif
  join    Reassemble parts into a single .sif file
  install-lfs  Install Git LFS locally to ~/bin if missing

Split options:
  --input PATH        Input .sif file (required)
  --prefix NAME       Output prefix (default: input basename without .sif)
  --out-dir DIR       Output base directory (default: .; parts go under <out-dir>/<prefix>/)
  --chunk-size SIZE   Chunk size for split (default: 2G)
  --digits N          Number of digits (default: 5)
  --start N           Starting index (default: 1)

Join options:
  --prefix NAME       Prefix to match (required)
  --in-dir DIR        Input base directory (default: .; parts under <in-dir>/<prefix>/)
  --output PATH       Output .sif file (default: <prefix>.sif)

Examples:
  scripts/sif_parts.sh split --input /path/to/vllm.sif --prefix vllm
  scripts/sif_parts.sh join --prefix vllm --output vllm.sif
  scripts/sif_parts.sh install-lfs
USAGE
}

cmd="${1:-}"
shift || true

if [[ -z "$cmd" ]]; then
  usage
  exit 1
fi

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

install_git_lfs() {
  if git lfs version >/dev/null 2>&1; then
    echo "git-lfs already available."
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git not found." >&2
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download git-lfs." >&2
    return 1
  fi

  if ! command -v tar >/dev/null 2>&1; then
    echo "ERROR: tar is required to extract git-lfs." >&2
    return 1
  fi

  local git_version install_if_lt
  git_version="$(git --version | awk '{print $3}')"
  git_version="${git_version%%[^0-9.]*}"
  git_version="${git_version%.}"
  if [[ -z "$git_version" ]]; then
    echo "ERROR: Unable to determine git version." >&2
    return 1
  fi

  install_if_lt="${SIF_LFS_INSTALL_IF_GIT_LT:-2.13.0}"
  if ! version_lt "$git_version" "$install_if_lt"; then
    echo "git $git_version is new enough; skipping local git-lfs install."
    echo "Install git-lfs via your package manager or set SIF_LFS_INSTALL_IF_GIT_LT higher."
    return 1
  fi

  mkdir -p "$HOME/bin"

  local tmp_dir
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
    return 1
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
    return 1
  fi

  (
    cd "$install_dir"
    ./install.sh --local
  )

  echo "git-lfs installed to $HOME/bin. Ensure $HOME/bin is on PATH."
}

split_sif() {
  local input="" prefix="" out_dir="." chunk_size="2G" digits="5" start="1"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input) input="$2"; shift 2 ;;
      --prefix) prefix="$2"; shift 2 ;;
      --out-dir) out_dir="$2"; shift 2 ;;
      --chunk-size) chunk_size="$2"; shift 2 ;;
      --digits) digits="$2"; shift 2 ;;
      --start) start="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$input" ]]; then
    echo "ERROR: --input is required." >&2
    exit 1
  fi

  if [[ ! -f "$input" ]]; then
    echo "ERROR: Input file not found: $input" >&2
    exit 1
  fi

  if [[ -z "$prefix" ]]; then
    prefix="$(basename "$input")"
    prefix="${prefix%.sif}"
  fi

  local parts_dir="${out_dir}/${prefix}"
  mkdir -p "$parts_dir"

  if split --help 2>/dev/null | grep -q -- '--numeric-suffixes'; then
    split -b "$chunk_size" -d -a "$digits" \
      --numeric-suffixes="$start" \
      --additional-suffix=".sif" \
      "$input" "${parts_dir}/${prefix}."
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: GNU split not available and python3 not found." >&2
    exit 1
  fi

  export SIF_INPUT="$input"
  export SIF_PREFIX="$prefix"
  export SIF_PARTS_DIR="$parts_dir"
  export SIF_CHUNK_SIZE="$chunk_size"
  export SIF_DIGITS="$digits"
  export SIF_START="$start"

  python3 - <<'PY'
import os
import sys

def parse_size(value: str) -> int:
    units = {"k": 1024, "m": 1024**2, "g": 1024**3, "t": 1024**4}
    if value[-1].isalpha():
        return int(float(value[:-1]) * units[value[-1].lower()])
    return int(value)

input_path = os.environ["SIF_INPUT"]
prefix = os.environ["SIF_PREFIX"]
out_dir = os.environ["SIF_PARTS_DIR"]
chunk_size = parse_size(os.environ["SIF_CHUNK_SIZE"])
digits = int(os.environ["SIF_DIGITS"])
start = int(os.environ["SIF_START"])

os.makedirs(out_dir, exist_ok=True)

index = start
with open(input_path, "rb") as src:
    while True:
        chunk = src.read(chunk_size)
        if not chunk:
            break
        name = f"{prefix}.{index:0{digits}d}.sif"
        out_path = os.path.join(out_dir, name)
        with open(out_path, "wb") as out:
            out.write(chunk)
        index += 1
PY
}

join_sif() {
  local prefix="" in_dir="." output=""
  local parts_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix) prefix="$2"; shift 2 ;;
      --in-dir) in_dir="$2"; shift 2 ;;
      --output) output="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$prefix" ]]; then
    echo "ERROR: --prefix is required." >&2
    exit 1
  fi

  if [[ -z "$output" ]]; then
    output="${prefix}.sif"
  fi

  if [[ ! -d "$in_dir" ]]; then
    echo "ERROR: Input directory not found: $in_dir" >&2
    exit 1
  fi

  if [[ -d "${in_dir}/${prefix}" ]]; then
    parts_dir="${in_dir}/${prefix}"
  else
    parts_dir="${in_dir}"
  fi

  shopt -s nullglob
  mapfile -t parts < <(ls -1 "${parts_dir}/${prefix}."[0-9][0-9][0-9][0-9][0-9].sif 2>/dev/null | LC_ALL=C sort)
  shopt -u nullglob

  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "ERROR: No parts found for prefix '${prefix}' in ${parts_dir}" >&2
    exit 1
  fi

  cat "${parts[@]}" > "$output"
}

case "$cmd" in
  split)
    split_sif "$@"
    ;;
  join)
    join_sif "$@"
    ;;
  install-lfs)
    install_git_lfs
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "ERROR: Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
