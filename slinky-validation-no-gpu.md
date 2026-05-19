# Slinky-on-DOKS: Control Plane Validation (No GPU)

Pre-POC validation checklist for the `slinky-on-doks` repo. Covers everything that can be verified **without GPU hardware**. GPU-dependent steps (fabric, GPU discovery, worker pods, NCCL benchmarks) are marked as optional/deferred.

**Repo:** https://github.com/DO-Solutions/slinky-on-doks  
**Goal:** Validate the full control plane → login pod → NFS → accounting before B300 hardware is available.

---

## Repo Analysis

### What's Already Good

- **GPU vendor abstraction is built in.** `terraform.tfvars` has `gpu_vendor = "amd" | "nvidia"`, Makefile derives taint keys and resource keys automatically. No code changes needed for NVIDIA — just set the variable.
- **`make up` chains everything** in the right order: `infra/apply → kubeconfig → gpu-tuner → prereqs → nfs → fabric → operator → slurm`. You can run the sub-targets individually.
- **Terraform creates all infra** (VPC, DOKS, MySQL, NFS) in one `apply`. Outputs feed directly into Helm values via `sed` templates.
- **Validation targets exist:** `make status`, `make nfs/test`, `make slurm/info`, `make slurm/test-restapi`.

### What Needs Attention for No-GPU Run

| Item | Issue | Fix |
|---|---|---|
| `make up` includes `nfs/gpu-tuner` | DaemonSet targets GPU nodes only — will find 0 nodes and complete, but worth knowing | Non-blocking. DaemonSet just won't schedule any pods |
| `make up` includes `fabric/install` | Multus installs fine on CPU nodes. NADs create but can't be tested without fabric NICs | Non-blocking. NADs will exist but won't attach to anything |
| `slinky/install-slurm` deploys worker pods | Workers request `nvidia.com/gpu` (or `amd.com/gpu`) resource — will stay **Pending** without GPU nodes | **Expected.** Control plane + login pod will still be Running |
| `gpu/discover-gres` needs a GPU node | Probe pod can't schedule | **Skip this step.** Use a placeholder gres.conf line |
| Slurm nodes show `down` in `sinfo` | Workers are Pending so slurmctld marks nodes as down | **Expected.** Control plane and login are still testable |

---

## Pre-Flight Setup

### 1. Clone and Configure

```bash
git clone https://github.com/DO-Solutions/slinky-on-doks.git
cd slinky-on-doks

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
# Set to nvidia for B300 POC prep
gpu_vendor    = "nvidia"
gpu_node_size = "gpu-h100x1-80gb"   # placeholder — will be replaced for actual POC
gpu_node_count = 0                   # ← KEY CHANGE: 0 GPU nodes for control plane validation
region        = "atl1"               # or your preferred region with NFS support
```

> **Critical:** Set `gpu_node_count = 0` so Terraform doesn't try to provision GPU droplets you don't have access to. If the Terraform variable doesn't support 0, set count to 2 and comment out the GPU node pool resource temporarily.

### 2. Environment Variables

```bash
export DIGITALOCEAN_TOKEN="your-api-token"
export SLURMD_IMAGE="ghcr.io/yourorg/slurmd-cuda:25.11"  # or placeholder for now
export REGISTRY_USER="your-github-username"
export REGISTRY_PASSWORD="your-ghcr-token"
```

---

## Validation Steps

Run these **in order**. Each step has a ✅ verification check.

### Step 1: Infrastructure

```bash
make infra/init
make infra/apply
make infra/kubeconfig
```

**✅ Verify:**
```bash
kubectl get nodes
# Should show 3 mgmt nodes (CPU), Ready
# No GPU nodes (gpu_node_count = 0)

make infra/output
# Should show: cluster_name, db_host, db_password, nfs_host, nfs_mount_path, etc.
```

---

### Step 2: Prerequisites (cert-manager + Prometheus)

```bash
make prereqs/install
```

**✅ Verify:**
```bash
make prereqs/status

# cert-manager: 3 pods Running (controller, cainjector, webhook)
# prometheus: multiple pods Running (prometheus, grafana, alertmanager, etc.)
```

**Test Grafana access:**
```bash
make obs/grafana
# Open http://localhost:3000 — should load Grafana login
# Default creds: admin / prom-operator
```

---

### Step 3: NFS Storage

```bash
make nfs/configure
```

**✅ Verify:**
```bash
make nfs/status
# PV should be Available or Bound
# PVC should be Bound

make nfs/test
# Should print: "NFS test <timestamp>"
# This deploys a busybox pod, writes a file, reads it back, cleans up
```

**⚠️ Check mount options in the generated PV:**
```bash
cat manifests/nfs-pv.yaml
# Verify mountOptions include vers=4.1 and nconnect=8
# For Mirelo POC, we'll want nconnect=16 — see "Modifications" section below
```

---

### Step 4: Slinky Operator

```bash
make slinky/install-operator
```

**✅ Verify:**
```bash
kubectl get pods -n slinky
# Operator pod and webhook pod should be Running

kubectl get crd | grep slinky
# Should show: clusters.slinky.slurm.net, nodesets.slinky.slurm.net
```

---

### Step 5: Slurm Cluster (Control Plane Only)

Before running this, create a placeholder gres.conf so the template doesn't break:

```bash
echo "Name=gpu File=/dev/nvidia[0,1,2,3,4,5,6,7]" > helm/slinky/.gres-conf-line
```

Now deploy:

```bash
make slinky/install-slurm
```

**✅ Verify:**
```bash
kubectl get pods -n slurm

# EXPECTED STATUS:
# slurm-controller-slinky-0       Running    ← slurmctld
# slurm-accounting-slinky-0       Running    ← slurmdbd (if accounting enabled)
# slurm-restapi-slinky-xxx        Running    ← slurmrestd
# slurm-login-slinky-xxx          Running    ← login node
# slurm-exporter-slinky-xxx       Running    ← metrics exporter
# slurm-worker-slinky-0           Pending    ← EXPECTED: no GPU nodes
# slurm-worker-slinky-1           Pending    ← EXPECTED: no GPU nodes
```

**Test login pod:**
```bash
make slurm/shell
# Should drop you into a bash shell inside the login pod

# Inside the login pod:
sinfo
# Nodes will show "down" — expected without GPU workers

scontrol show partitions
# Should show the slinky partition configured

sacctmgr show cluster
# Should show your cluster name — confirms accounting DB connection

ls /shared/
# Should be accessible — confirms NFS mount in login pod

exit
```

---

### Step 6: REST API

```bash
make slurm/test-restapi
# Or manually:
kubectl exec -n slurm deploy/slurm-login-slinky -- scontrol token lifespan=600
# Should return a JWT token — confirms slurmrestd is working
```

---

### Step 7: Observability

```bash
make obs/dashboard
make obs/grafana
# Open http://localhost:3000
# Search for metrics prefixed with "slurm_"
# Controller metrics should be flowing even without workers
```

---

## Skipped Steps (Require GPU)

These will be validated when B300 hardware is available:

| Step | Make Target | Why Skipped |
|---|---|---|
| GPU network tuner | `make nfs/gpu-tuner` | DaemonSet needs GPU nodes for MTU 9000 tuning |
| RDMA fabric attach | `make fabric/install` | Multus installs fine, but NADs can't attach without fabric NICs |
| GPU discovery | `make gpu/discover-gres` | Probe pod needs GPU resource to schedule |
| Worker pods Running | — | Workers stay Pending without GPU resources |
| NCCL all-reduce | `make slurm/submit-rccl-*` | Needs running GPU workers |

---

## Modifications for Mirelo POC

Changes to make before the actual B300 POC. These can be prepared now and committed to a branch.

### 1. NFS Mount Options (nconnect=16)

The repo's `manifests/nfs-pv.yaml.tpl` currently uses default mount options. For Mirelo's IOPS-heavy workload (1 MB tensor files), add tuned mount options:

**File:** `manifests/nfs-pv.yaml.tpl`

```yaml
# Add under spec:
  mountOptions:
    - vers=4.1
    - nconnect=16
    - rsize=1048576
    - wsize=1048576
```

### 2. Shared Memory Volume (64 GiB)

Verify the Helm values template includes the `/dev/shm` volume for NCCL. Check:

**File:** `helm/slinky/values-slurm.yaml.tpl`

```yaml
# Under nodesets.slinky.podSpec.volumes, ensure this exists:
- name: shm
  emptyDir:
    medium: Memory
    sizeLimit: 64Gi

# Under nodesets.slinky.slurmd.volumeMounts:
- name: shm
  mountPath: /dev/shm
```

### 3. NVIDIA slurmd Image (slurmd-cuda)

The repo only has `docker/slurmd-rocm/`. You need to create `docker/slurmd-cuda/`:

```
docker/slurmd-cuda/
├── Dockerfile          # Based on nvidia/cuda + upstream slinky slurmd
└── README.md
```

**Minimum Dockerfile contents:**
```dockerfile
# Base: NVIDIA CUDA runtime with NCCL
FROM nvidia/cuda:12.8-devel-ubuntu24.04 AS build

# Install NCCL tests
RUN apt-get update && apt-get install -y git build-essential libopenmpi-dev && \
    git clone https://github.com/NVIDIA/nccl-tests.git /tmp/nccl-tests && \
    cd /tmp/nccl-tests && make MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi && \
    cp /tmp/nccl-tests/build/* /usr/local/bin/

# Final image: extend upstream slinky slurmd
FROM ghcr.io/slinkyproject/slurm:slurmd-25.11-ubuntu-24.04

# Copy CUDA + NCCL from build stage
COPY --from=build /usr/local/cuda /usr/local/cuda
COPY --from=build /usr/local/bin/all_reduce_perf /usr/local/bin/
COPY --from=build /usr/lib/x86_64-linux-gnu/libnccl* /usr/lib/x86_64-linux-gnu/
# ... (RDMA userspace, OpenMPI, etc.)

ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
ENV PATH=/usr/local/cuda/bin:${PATH}
```

> **NOTE:** This Dockerfile is a starting point. The actual build will need careful CUDA/driver version matching with the B300 host driver. Test on any available NVIDIA GPU first.

### 4. Benchmark Scripts

Add to the repo under `jobs/` (alongside existing RCCL scripts):

```
jobs/
├── rccl-allreduce-1node.sh      # existing (AMD)
├── rccl-allreduce-2node.sh      # existing (AMD)
├── nccl-allreduce-1node.sh      # NEW (NVIDIA)
├── nccl-allreduce-2node.sh      # NEW (NVIDIA)
├── fio-storage-benchmark.sh     # NEW
├── network-ingress.sh           # NEW
├── torch-benchmark.sh           # NEW
└── collect-results.sh           # NEW
```

Add corresponding Makefile targets:

```makefile
slurm/submit-nccl-1node: ## Submit single-node NCCL all-reduce test (NVIDIA)
	kubectl exec -i -n slurm deploy/slurm-login-slinky -c login -- \
	  tee /shared/jobs/nccl-allreduce-1node.sh < jobs/nccl-allreduce-1node.sh > /dev/null
	kubectl exec -n slurm deploy/slurm-login-slinky -c login -- \
	  chmod +x /shared/jobs/nccl-allreduce-1node.sh
	kubectl exec -n slurm deploy/slurm-login-slinky -- sbatch /shared/jobs/nccl-allreduce-1node.sh

slurm/submit-fio: ## Submit storage I/O benchmark
	# same pattern as above with jobs/fio-storage-benchmark.sh

slurm/collect-results: ## Collect all benchmark results into summary
	# same pattern with jobs/collect-results.sh
```

### 5. Terraform: gpu_node_count = 0 Support

Check if `terraform/main.tf` handles `gpu_node_count = 0` gracefully (i.e., conditionally creates the GPU node pool). If not, add:

```hcl
# In the DOKS cluster resource:
dynamic "node_pool" {
  for_each = var.gpu_node_count > 0 ? [1] : []
  content {
    name       = "gpu"
    size       = var.gpu_node_size
    node_count = var.gpu_node_count
    # ...
  }
}
```

This lets you run `make infra/apply` without GPU access.

---

## Summary: What Gets Validated Today

| Component | Status | Notes |
|---|---|---|
| VPC + DOKS cluster | ✅ Fully validated | 3 CPU mgmt nodes |
| Managed MySQL | ✅ Fully validated | slurm_acct DB + user created |
| Managed NFS | ✅ Fully validated | PV/PVC bound, read/write tested |
| cert-manager | ✅ Fully validated | Webhook TLS working |
| Prometheus + Grafana | ✅ Fully validated | Metrics flowing, dashboards accessible |
| Slinky Operator | ✅ Fully validated | CRDs registered, operator Running |
| slurmctld | ✅ Fully validated | Controller pod Running |
| slurmdbd | ✅ Fully validated | Connected to managed MySQL |
| slurmrestd | ✅ Fully validated | JWT token generation works |
| Login pod | ✅ Fully validated | Shell access, NFS mounted at /shared |
| Worker pods | ⏳ Pending | Expected — needs GPU nodes |
| RDMA fabric | ⏳ Deferred | Multus installed, NADs created, can't test attach |
| GPU discovery | ⏳ Deferred | Needs GPU node for probe pod |
| NCCL benchmarks | ⏳ Deferred | Needs running workers |

**Estimated time:** ~30-45 minutes to run through all steps (excluding Terraform apply wait time).

---

## When B300 Hardware is Available

1. Update `terraform.tfvars`: set `gpu_node_count = 2`, set correct `gpu_node_size` for B300
2. `make infra/apply` — adds GPU node pool to existing cluster
3. `make nfs/gpu-tuner` — tunes MTU 9000 on GPU nodes
4. `make gpu/discover-gres` — discovers B300 device paths
5. `make slinky/update-slurm` — re-deploys with real gres.conf
6. Workers go from Pending → Running
7. `make slurm/info` — nodes should show `idle`
8. Run benchmarks: NCCL, fio, ingress, training