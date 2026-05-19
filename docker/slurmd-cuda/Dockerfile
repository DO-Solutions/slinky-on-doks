# Custom slurmd image with CUDA, NCCL, nccl-tests, and RDMA userspace
# for GPU training validation on DOKS B300/H100 nodes.
#
# Multi-stage build:
#   Stage 1 (builder): compile nccl-tests using official nvidia/cuda devel image
#   Stage 2 (final):   slinky slurmd base + RDMA tools + compiled binaries
#
# CUDA_IMAGE controls the CUDA version used for compilation.
# The runtime CUDA driver comes from the host node — not baked into the image.
ARG CUDA_IMAGE=nvidia/cuda:12.6.3-devel-ubuntu24.04

# ── Stage 1: Build nccl-tests ────────────────────────────────────────────────
FROM --platform=linux/amd64 ${CUDA_IMAGE} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        build-essential \
        libopenmpi-dev \
        openmpi-bin \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git /tmp/nccl-tests && \
    cd /tmp/nccl-tests && \
    make MPI=1 \
         MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
         CUDA_HOME=/usr/local/cuda \
         NCCL_HOME=/usr && \
    cp build/all_reduce_perf \
       build/reduce_scatter_perf \
       build/all_gather_perf \
       /usr/local/bin/ && \
    rm -rf /tmp/nccl-tests

# ── Stage 2: Slinky slurmd base ──────────────────────────────────────────────
FROM --platform=linux/amd64 ghcr.io/slinkyproject/slurmd:25.11.5-ubuntu24.04

USER root

# RDMA userspace + networking diagnostics
RUN apt-get update && apt-get install -y --no-install-recommends \
        libibverbs-dev \
        rdma-core \
        ibverbs-utils \
        perftest \
        iproute2 \
        libopenmpi-dev \
        openmpi-bin \
    && rm -rf /var/lib/apt/lists/*

# Copy NCCL runtime libraries from builder
COPY --from=builder /usr/lib/x86_64-linux-gnu/libnccl.so* \
                    /usr/lib/x86_64-linux-gnu/
# Copy CUDA runtime libraries needed at slurm job runtime
COPY --from=builder /usr/local/cuda/lib64/libcudart.so* \
                    /usr/local/cuda/lib64/

# Copy compiled benchmark binaries
COPY --from=builder /usr/local/bin/all_reduce_perf \
                    /usr/local/bin/reduce_scatter_perf \
                    /usr/local/bin/all_gather_perf \
                    /usr/local/bin/

ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
