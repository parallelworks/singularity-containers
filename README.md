# singularity-containers

This repo stores Apptainer/Singularity SIF images using Git LFS.

## Git LFS Setup

If `git lfs` is not available (common on older Git installs), run:

```bash
scripts/sif_parts.sh install-lfs
```

This installs git-lfs locally to `~/bin` using the latest Linux amd64 release
only when `git --version` is older than `2.13.0` (adjust with
`SIF_LFS_INSTALL_IF_GIT_LT`). Alternatively, run `scripts/install_git_lfs.sh`.

## Naming Convention

Split large images into fixed-size parts named like:

- `vllm.00001.sif`, `vllm.00002.sif`, ...
- `rag.00001.sif`, `rag.00002.sif`, ...

These are tracked by Git LFS via `.gitattributes` patterns.

## Helper Script

Split and reassemble images with `scripts/sif_parts.sh`:

```bash
# Split into 2GiB parts (default) in the current directory
scripts/sif_parts.sh split --input /path/to/vllm.sif --prefix vllm

# Reassemble
scripts/sif_parts.sh join --prefix vllm --output vllm.sif
```

If your environment lacks GNU `split`, the script falls back to Python.
