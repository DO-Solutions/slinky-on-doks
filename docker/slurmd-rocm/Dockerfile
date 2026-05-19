# Custom slurmd image with ROCm userspace, RCCL, rccl-tests, and ANP plugin
# for RDMA fabric validation on DOKS MI325X nodes.
FROM ghcr.io/slinkyproject/slurmd:25.11.5-ubuntu24.04

USER root

# ROCm version — must match the host ROCm version on DOKS GPU nodes.
# Host has ROCm 7.0.2 (checked via kubectl debug node)
ARG ROCM_VERSION=7.0.2
ARG ROCM_APT_VERSION=7.0.2

# RDMA userspace + networking diagnostics
RUN apt-get update && apt-get install -y --no-install-recommends \
        libibverbs-dev \
        rdma-core \
        ibverbs-utils \
        iproute2 \
        wget \
        gnupg2 \
        ca-certificates \
        git \
        build-essential \
        cmake \
        libopenmpi-dev \
    && rm -rf /var/lib/apt/lists/*

# ROCm + AMDGPU repositories (AMDGPU repo provides libdrm-amdgpu deps)
RUN mkdir -p /etc/apt/keyrings && \
    wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_APT_VERSION} noble main" \
        > /etc/apt/sources.list.d/rocm.list && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${ROCM_APT_VERSION}/ubuntu noble main" \
        > /etc/apt/sources.list.d/amdgpu.list && \
    printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' \
        > /etc/apt/preferences.d/rocm-pin-600

# ROCm userspace libraries + HIP compiler + hipify + device libs (driver is on the host)
RUN apt-get update && apt-get install -y --no-install-recommends \
        hip-runtime-amd \
        hip-dev \
        hipify-clang \
        rocm-device-libs \
        rocm-smi-lib \
        rocm-cmake \
        rocminfo \
    && rm -rf /var/lib/apt/lists/*

# RCCL from ROCm packages (rccl-dev provides headers for building rccl-tests)
RUN apt-get update && apt-get install -y --no-install-recommends \
        rccl-dev \
    && rm -rf /var/lib/apt/lists/*

# Build rccl-tests (provides all_reduce_perf)
RUN git clone --depth 1 https://github.com/ROCm/rccl-tests.git /home/rccl/rccl-tests && \
    cd /home/rccl/rccl-tests && \
    make MPI=1 HIP_HOME=/opt/rocm RCCL_HOME=/opt/rocm && \
    rm -rf /home/rccl/rccl-tests/.git

# ANP plugin placeholder — copy from host or external source
# The actual librccl-anp.so must be provided at build time or mounted at runtime.
RUN mkdir -p /opt/lib
# COPY librccl-anp.so /opt/lib/librccl-anp.so

# Default library paths
ENV LD_LIBRARY_PATH="/opt/rocm/lib:/opt/lib:${LD_LIBRARY_PATH}"
ENV PATH="/opt/rocm/bin:${PATH}"
