# singularity-containers

This repo stores Apptainer/Singularity SIF images using Git LFS.

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
