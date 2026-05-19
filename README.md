# Slinky on DOKS — Multi-Node GPU Training

Automated deployment of [Slinky](https://github.com/SlinkyProject/slurm-operator) (Slurm on Kubernetes) on DigitalOcean DOKS, from infrastructure provisioning through running multi-node GPU collective benchmarks over an RDMA fabric.

Supports both **NVIDIA** (NCCL / CUDA) and **AMD** (RCCL / ROCm) GPU nodes.

> **Prefer manual steps?** See the [Manual Install Guide](MANUAL-INSTALL-GUIDE.md) for step-by-step kubectl/helm commands with explanations.

> **Support disclaimer**: DigitalOcean does not provide direct support for Slinky or Slurm. These instructions are offered as guidance only. While the underlying DigitalOcean services (DOKS, Managed NFS, DBaaS) are fully supported, issues related to Slinky, Slurm, or their configuration are outside the scope of DigitalOcean support.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    DOKS Cluster (VPC)                       │
│                                                             │
│  ┌─────────────────────┐    ┌────────────────────────────┐  │
│  │    mgmt pool (CPU)  │    │     gpu pool (GPU)         │  │
│  │                     │    │  (auto-tainted by DOKS)    │  │
│  │  slurmctld          │    │                            │  │
│  │  slurmdbd           │    │  slurm-worker-slinky-0     │  │
│  │  slurmrestd         │    │  slurm-worker-slinky-1     │  │
│  │  login node         │    │  ...                       │  │
│  │  slurm-operator     │    │                            │  │
│  │  cert-manager       │    │                            │  │
│  │  prometheus/grafana │    │                            │  │
│  └─────────┬───────────┘    └────────────────────────────┘  │
│            │                                                │
│  ┌─────────┴───────────┐    ┌────────────────────────────┐  │
│  │   Managed MySQL     │    │     Managed NFS            │  │
│  │   (accounting)      │    │     (/shared)              │  │
│  └─────────────────────┘    └────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

DOKS automatically applies taints to GPU node pools, so non-GPU workloads (operator, monitoring, Slurm control plane) naturally schedule on the mgmt nodes without explicit `nodeSelector` rules.

## Prerequisites

### CLI Tools

- [doctl](https://docs.digitalocean.com/reference/doctl/) configured with your API token
- [Terraform](https://www.terraform.io/) >= 1.5
- [Helm](https://helm.sh/) >= 3.12
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/) (only if building the custom slurmd image locally)

### DigitalOcean Account

- GPU Droplet access enabled (request via support if needed)
- `doctl` authenticated (`doctl auth init`)

### Container Registry

GPU workers run a custom slurmd image that includes the GPU communication libraries and benchmark binaries. Push this image to a registry accessible by DOKS (e.g., `ghcr.io`).

> **DOKS image size limits**: Layers > 5GB or total image size > 20GB are not supported until Q2 2026. Both `slurmd-cuda` and `slurmd-rocm` images are designed to stay within these limits.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DIGITALOCEAN_TOKEN` | Yes | DigitalOcean API token (used by Terraform) |
| `SLURMD_IMAGE` | Yes | Full image reference, e.g. `ghcr.io/your-org/slurmd-cuda:25.11-cuda12.6` |
| `REGISTRY_USER` | Yes | Registry username for image pull secret |
| `REGISTRY_PASSWORD` | Yes | Registry password/token for image pull secret |

## Configuration

### Terraform Variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set region, GPU vendor, node size/count
```

### GPU Vendor

Set `gpu_vendor` in `terraform.tfvars` to match your GPU hardware:

| GPU Family | `gpu_vendor` | `gpu_node_size` | Region |
|------------|-------------|-----------------|--------|
| NVIDIA B300 (8x) | `nvidia` | `gpu-b300x8-2304gb-fabric-contracted` | `ric1` |
| NVIDIA H100 (8x) | `nvidia` | `gpu-h100x8-640gb` | `atl1` |
| AMD MI300X (8x) | `amd` | `gpu-mi300x8-1920gb` | `atl1` |

The Makefile derives the correct taint key (`nvidia.com/gpu` or `amd.com/gpu`) and node selector label automatically from this value.

## Bring Your Own Cluster

If you already have a DOKS cluster provisioned via the DO console or API, you can skip cluster creation and let Terraform provision only the Managed MySQL and Managed NFS dependencies.

### Get your Cluster ID and VPC ID

Run this one command — it prints both IDs at once:

```bash
doctl kubernetes cluster get <your-cluster-name> -o json | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
if isinstance(d,list): d=d[0]
print('cluster_id:', d['id'])
print('vpc_id:', d['vpc_uuid'])
"
```

Example output:
```
cluster_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
vpc_id:     yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
```

> Don't know your cluster name? Run `doctl kubernetes cluster list`.

### Setup

**1. Configure tfvars with your existing IDs**

```hcl
# terraform/terraform.tfvars
region       = "ric1"          # must match your cluster's region
project_name = "slinky-poc"
gpu_vendor   = "nvidia"

existing_cluster_id = "abc-1234-..."   # your cluster ID
existing_vpc_id     = "def-5678-..."   # your VPC ID
```

**2. Provision MySQL and NFS**

```bash
make infra/init
make infra/apply   # creates only MySQL + NFS, cluster is untouched
```

**3. Get kubeconfig**

```bash
make infra/kubeconfig   # auto-detects external cluster and uses doctl
```

**4. Deploy Slinky**

```bash
export SLURMD_IMAGE=ghcr.io/your-org/slurmd-cuda:25.11-cuda12.6
export REGISTRY_USER=your-registry-user
export REGISTRY_PASSWORD=your-registry-token
make up-from-existing
```

`make up-from-existing` is identical to `make up` but skips the infrastructure provisioning step — it assumes your cluster is already running and kubeconfig is configured.

> **Note**: `DO_API_TOKEN` is accepted as an alias for `DIGITALOCEAN_TOKEN` — either env var works.

## Custom slurmd Image

GPU workers require a custom slurmd image because the upstream Slinky image does not include GPU communication libraries or benchmark binaries.

### NVIDIA (CUDA / NCCL)

The `slurmd-cuda` image includes:
- NCCL runtime libraries (from `nvidia/cuda:12.6.3-devel-ubuntu24.04`)
- Compiled `all_reduce_perf`, `reduce_scatter_perf`, `all_gather_perf` binaries
- RDMA userspace tools (`libibverbs`, `rdma-core`, `perftest`)
- OpenMPI

**Build via GitHub Actions** (recommended):

Trigger the `Build slurmd-cuda` workflow from your repository's Actions tab, or push to a branch that matches the workflow trigger. The image is pushed to `ghcr.io/<your-org>/slurmd-cuda:25.11-cuda12.6`.

**Build locally**:

```bash
export SLURMD_IMAGE=ghcr.io/your-org/slurmd-cuda:25.11-cuda12.6
make docker/build-slurmd-cuda
make docker/push-slurmd
```

See [docker/slurmd-cuda/Dockerfile](docker/slurmd-cuda/Dockerfile) for build details.

### AMD (ROCm / RCCL)

The `slurmd-rocm` image includes ROCm runtime libraries, RCCL, and compiled benchmark binaries.

```bash
export SLURMD_IMAGE=ghcr.io/your-org/slurmd-rocm:25.11
make docker/build-slurmd
make docker/push-slurmd
```

See [docker/slurmd-rocm/README.md](docker/slurmd-rocm/README.md) for build details.

## Quick Start

```bash
# 1. Set your slurmd image
export SLURMD_IMAGE=ghcr.io/your-org/slurmd-cuda:25.11-cuda12.6   # NVIDIA
# export SLURMD_IMAGE=ghcr.io/your-org/slurmd-rocm:25.11           # AMD

# 2. Deploy everything (infra, kubeconfig, prereqs, NFS, fabric, operator, Slurm)
make up

# 3. Discover GPUs and update Slurm config
make gpu/discover-gres
make slinky/update-slurm

# 4. Verify
make status
make slurm/shell   # interactive login node shell
```

## Step-by-Step Guide

### 1. Infrastructure

Provision DOKS cluster, managed MySQL, managed NFS, and VPC:

```bash
make infra/apply
```

> **Already have a cluster?** See the [Bring Your Own Cluster](#bring-your-own-cluster) section — set `existing_cluster_id` and `existing_vpc_id` in `terraform.tfvars` and `terraform apply` will only create MySQL and NFS.

### 2. Kubeconfig

Save the cluster kubeconfig so `kubectl` and `helm` can reach the new cluster:

```bash
make infra/kubeconfig
```

> **Note**: `make up` runs this automatically after `infra/apply`.

### 3. Prerequisites

Install cert-manager (required by Slinky operator) and Prometheus/Grafana:

```bash
make prereqs/install
```

### 4. Storage

Create NFS PV/PVC from Terraform outputs, used as shared storage (`/shared`) across login and worker pods:

```bash
make nfs/configure
```

### 5. RDMA Fabric

Install Multus CNI and fabric NetworkAttachmentDefinitions for RoCE (RDMA over Converged Ethernet):

```bash
make fabric/install
```

Each B300 GPU node has 16 fabric NICs (`fabric0`–`fabric15`, two per GPU). Multus attaches these into worker pods for GPU-to-GPU communication across nodes.

### 6. Slurm Operator

Install the Slinky operator with CRDs:

```bash
make slinky/install-operator
```

### 7. Slurm Cluster

Creates the DB secret, image pull secret, generates Helm values, and deploys the Slurm cluster:

```bash
export SLURMD_IMAGE=ghcr.io/your-org/slurmd-cuda:25.11-cuda12.6   # or your AMD image
export REGISTRY_USER=your-registry-user
export REGISTRY_PASSWORD=your-registry-token
make slinky/install-slurm
```

### 8. GPU Discovery

Discover GPU device paths on the GPU nodes and update the Slurm GRes configuration:

```bash
make gpu/discover-gres
make slinky/update-slurm
```

This deploys a probe pod to detect device paths on the GPU node (e.g., `/dev/nvidia[0-7]` for NVIDIA, `/dev/dri/renderD[128,136,...]` for AMD) and saves the result to `gres.conf`.

### 9. Validation

```bash
make slurm/info            # sinfo, squeue, partitions
make slurm/test-fabric     # verify fabric NICs and RDMA devices
make status                # full component status
```

## Running GPU Collective Benchmarks

These benchmarks confirm GPU-to-GPU communication is working correctly over the RDMA fabric.

**Prerequisites**: fabric deployed (`make fabric/install`), workers running, compute nodes idle (`sinfo` shows `idle`).

### NVIDIA — NCCL Tests

#### Single-Node (8 GPUs, intra-node)

```bash
make slurm/submit-nccl-1node
```

Expected: `all_reduce_perf` bandwidth table with **~300–450 GB/s bus bandwidth** across message sizes.

#### Multi-Node (16 GPUs, 2 nodes over RoCE)

```bash
make slurm/submit-nccl-2node
```

Expected: bandwidth table with inter-node throughput and `NCCL_DEBUG` output showing `NET/IB` RoCE transport selected.

### AMD — RCCL Tests

#### Single-Node (8 GPUs, intra-node)

```bash
make slurm/submit-rccl-1node
```

Expected: `all_reduce_perf` bandwidth table with **~110 GB/s average bus bandwidth**.

#### Multi-Node (16 GPUs, 2 nodes over RoCE)

```bash
make slurm/submit-rccl-2node
```

Expected: bandwidth table with **~350 GB/s average bus bandwidth** and RoCE transport confirmation.

### Reading Output

Job output is written to NFS at `/shared/output/`:

```
/shared/output/allreduce-1node-<jobid>.out
/shared/output/allreduce-2node-<jobid>.out
```

To read results from the login pod:

```bash
make slurm/shell
ls /shared/output/
cat /shared/output/allreduce-1node-*.out
```

## Teardown

```bash
make down
```

Tears down in reverse order: Slurm cluster, fabric, prerequisites, infrastructure.

## Make Targets Reference

```
make help
```

| Target | Description |
|--------|-------------|
| **Lifecycle** | |
| `up` | Full deploy: infra, prereqs, NFS, fabric, operator, Slurm |
| `up-from-existing` | Deploy Slinky on existing DOKS cluster (run `make infra/import-cluster` first) |
| `down` | Full teardown |
| `status` | Show status of all components |
| **Infrastructure** | |
| `infra/init` | Initialize Terraform providers and backend |
| `infra/plan` | Preview Terraform changes |
| `infra/apply` | Provision DOKS, MySQL, NFS, VPC |
| `infra/kubeconfig` | Save kubeconfig from Terraform to ~/.kube/config |
| `infra/import-cluster` | Import existing DOKS cluster into Terraform state (set `CLUSTER_NAME`) |
| `infra/destroy` | Destroy all infrastructure |
| `infra/output` | Print all Terraform outputs |
| **Prerequisites** | |
| `prereqs/install` | Install cert-manager and Prometheus |
| `prereqs/status` | Check pod status across prerequisite namespaces |
| `prereqs/uninstall` | Uninstall all prerequisites |
| **NFS** | |
| `nfs/configure` | Generate NFS PV/PVC from Terraform outputs |
| `nfs/test` | Deploy busybox pod to verify NFS read/write |
| `nfs/status` | Check PV/PVC binding status |
| **Docker** | |
| `docker/build-slurmd` | Build custom slurmd image with ROCm/RCCL (AMD) |
| `docker/build-slurmd-cuda` | Build custom slurmd image with CUDA/NCCL (NVIDIA) |
| `docker/push-slurmd` | Push slurmd image to registry |
| **Fabric** | |
| `fabric/install` | Install Multus + fabric NADs |
| `fabric/install-multus` | Install Multus CNI plugin |
| `fabric/install-nads` | Create fabric NetworkAttachmentDefinitions |
| `fabric/status` | Check Multus and NAD status |
| `fabric/uninstall` | Remove fabric NADs and Multus |
| **GPU** | |
| `gpu/discover-gres` | Discover GPU device paths and save gres.conf |
| **Slinky / Slurm** | |
| `slinky/install-operator` | Install Slinky operator with CRDs |
| `slinky/configure` | Generate values-slurm.yaml from template |
| `slinky/install-slurm` | Install Slurm cluster (creates secrets, configures, deploys) |
| `slinky/update-slurm` | Helm upgrade Slurm with updated values |
| `slinky/create-db-secret` | Create Slurm DB password secret |
| `slinky/create-pull-secret` | Create image pull secret |
| `slinky/status` | Show pods across slinky + slurm namespaces |
| `slinky/uninstall` | Uninstall Slurm cluster, operator, CRDs |
| `slinky/logs` | Tail operator and controller logs |
| **Slurm Operations** | |
| `slurm/shell` | Interactive shell on the login pod |
| `slurm/info` | Show sinfo, squeue, partitions |
| `slurm/test-fabric` | Verify fabric NICs and RDMA devices on workers |
| `slurm/submit-nccl-1node` | Submit single-node NCCL all-reduce test (NVIDIA) |
| `slurm/submit-nccl-2node` | Submit multi-node NCCL all-reduce test (NVIDIA) |
| `slurm/submit-rccl-1node` | Submit single-node RCCL all-reduce test (AMD) |
| `slurm/submit-rccl-2node` | Submit multi-node RCCL all-reduce test (AMD) |
| `slurm/submit-test` | Copy job scripts to NFS and submit basic test jobs |
| `slurm/run-validation` | Run the full validation suite |
| `slurm/test-restapi` | Test slurmrestd API endpoints |
| **Observability** | |
| `obs/dashboard` | Deploy Slurm Grafana dashboard |
| `obs/grafana` | Port-forward Grafana to localhost:3000 |
| `obs/prometheus` | Port-forward Prometheus to localhost:9090 |

## Related Documentation

- [docker/slurmd-cuda/Dockerfile](docker/slurmd-cuda/Dockerfile) — NVIDIA CUDA/NCCL image build
- [docker/slurmd-rocm/README.md](docker/slurmd-rocm/README.md) — AMD ROCm/RCCL image build details
