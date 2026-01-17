#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/sif_parts.sh split --input /path/to/file.sif [options]
  scripts/sif_parts.sh join --prefix vllm [options]

Commands:
  split   Split a SIF into numeric parts like vllm.00001.sif
  join    Reassemble parts into a single .sif file

Split options:
  --input PATH        Input .sif file (required)
  --prefix NAME       Output prefix (default: input basename without .sif)
  --out-dir DIR       Output directory (default: .)
  --chunk-size SIZE   Chunk size for split (default: 2G)
  --digits N          Number of digits (default: 5)
  --start N           Starting index (default: 1)

Join options:
  --prefix NAME       Prefix to match (required)
  --in-dir DIR        Input directory (default: .)
  --output PATH       Output .sif file (default: <prefix>.sif)

Examples:
  scripts/sif_parts.sh split --input /path/to/vllm.sif --prefix vllm
  scripts/sif_parts.sh join --prefix vllm --output vllm.sif
USAGE
}

cmd="${1:-}"
shift || true

if [[ -z "$cmd" ]]; then
  usage
  exit 1
fi

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

  mkdir -p "$out_dir"

  if split --help 2>/dev/null | grep -q -- '--numeric-suffixes'; then
    split -b "$chunk_size" -d -a "$digits" \
      --numeric-suffixes="$start" \
      --additional-suffix=".sif" \
      "$input" "${out_dir}/${prefix}."
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: GNU split not available and python3 not found." >&2
    exit 1
  fi

  export SIF_INPUT="$input"
  export SIF_PREFIX="$prefix"
  export SIF_OUT_DIR="$out_dir"
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
out_dir = os.environ["SIF_OUT_DIR"]
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

  shopt -s nullglob
  mapfile -t parts < <(ls -1 "${in_dir}/${prefix}."[0-9][0-9][0-9][0-9][0-9].sif 2>/dev/null | LC_ALL=C sort)
  shopt -u nullglob

  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "ERROR: No parts found for prefix '${prefix}' in ${in_dir}" >&2
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
  -h|--help)
    usage
    ;;
  *)
    echo "ERROR: Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
