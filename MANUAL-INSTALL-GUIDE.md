# Deploying Slinky on DOKS — From Zero to Multi-Node NCCL

This guide walks through deploying [Slinky](https://github.com/SlinkyProject/slurm-operator) (Slurm on Kubernetes) on DigitalOcean DOKS and running a multi-node NCCL all-reduce benchmark over an RDMA fabric on NVIDIA B300 GPU nodes. It covers infrastructure provisioning, GPU discovery, fabric setup, and Slurm cluster configuration — everything the [official Slinky installation guide](https://github.com/SlinkyProject/slurm-operator) does not address for a DOKS environment. RCCL (AMD) workloads follow the same pattern; swap the GPU vendor, container image, and device paths.

> **Want automated deployment?** The [slinky-on-doks](https://github.com/DO-Solutions/slinky-on-doks) repo contains Terraform configs and Kubernetes manifests to deploy a full PoC environment with a single `make up` command.

---

## 1. Infrastructure Prerequisites

Create the following DigitalOcean resources before installing any Helm charts.

### VPC

[Create a VPC](https://docs.digitalocean.com/products/networking/vpc/how-to/create/) in a region that supports managed NFS such as **atl1**.

### DOKS Cluster

[Create a Kubernetes cluster](https://docs.digitalocean.com/products/kubernetes/how-to/create-clusters/) in the same VPC with two node pools:

| Pool | Purpose | Suggested size | Count |
|------|---------|---------------|-------|
| **mgmt** | Slurm control plane, operator, monitoring, login nodes | CPU Optimized 4 vCPU / 8 GiB | 3 |
| **gpu** | Slurm worker nodes (training jobs) | NVIDIA B300 GPU Droplets (8× GPU, 16× fabric NICs) | 2+ |

### GPU Node Taints and Labels (DOKS-managed)

DOKS automatically applies taints and labels to GPU node pools:

| GPU vendor | Auto-applied taint | Auto-applied labels |
|---|---|---|
| NVIDIA | `nvidia.com/gpu:NoSchedule` | `doks.digitalocean.com/gpu-brand: nvidia`, `doks.digitalocean.com/gpu-model: <model>` |
| AMD | `amd.com/gpu:NoSchedule` | `doks.digitalocean.com/gpu-brand: amd`, `doks.digitalocean.com/gpu-model: <model>` |

These taints prevent non-GPU workloads from landing on expensive GPU nodes. Your Slurm worker pods must carry matching tolerations (shown in Section 8).

> **Deployment assumption:** This guide assumes a two-tier layout — one **mgmt** pool of CPU nodes and one or more **GPU** node pools. Since GPU pools carry automatic taints, all non-GPU workloads (Slurm control plane, monitoring, cert-manager, etc.) will naturally schedule on the mgmt nodes without requiring explicit `nodeSelector` rules. If you add untainted CPU-only worker pools, you may need `nodeSelector` or affinity rules to keep infrastructure pods off those nodes.

### Accounting Database (optional — skip for a minimal install)

This guide's default Slurm deployment runs **without** accounting. The scheduler, GPU resources, fabric, login pods, and shared NFS all work without `slurmdbd`. **Skip the rest of this subsection unless you specifically want accounting features.**

If you do need job accounting (`sacct`, `sreport`, fair-share scheduling, multi-cluster federation), you have two options:

**Option A — In-cluster MariaDB (dev/test only):**
The Slinky Helm chart can deploy a MariaDB instance automatically inside the cluster. Simply enable accounting without providing a `storageConfig` block and the chart handles the rest. This is convenient for quick experiments but is **not recommended for production** because the database lifecycle is tied to the Helm release and does not offer managed backups or high availability.

**Option B — Managed MySQL (recommended for production):**
[Create a managed MySQL database](https://docs.digitalocean.com/products/databases/mysql/how-to/create/) in the same VPC. The accounting DB is lightweight — it stores job records, association/QOS metadata, and periodic usage rollups. Write volume is low (roughly one insert per job start and end), so a **single-node, smallest-size instance** (1 vCPU / 1 GB RAM) is sufficient to start with for most clusters. The main benefit of a managed DB is durability, automated backups, and high-availability options as you scale.

- **Engine:** MySQL 8
- **Size:** db-s-1vcpu-1gb (smallest; scale up only if needed)
- **Storage:** 10 GB (sufficient for millions of job records)
- **Connection:** Use the **private host** (VPC network), default managed port `25060`

The managed instance ships with a default `doadmin` user and `defaultdb` database. You need to [add a database and user](https://docs.digitalocean.com/products/databases/mysql/how-to/manage-users-and-databases/) for Slurm:

- **Database name:** `slurm_acct`
- **User:** `slurm`

After creating the user, store its password as a Kubernetes secret (see Section 2).

[Configure trusted sources](https://docs.digitalocean.com/products/databases/mysql/how-to/secure/) on the database to restrict connections to your DOKS cluster and any bastion hosts that need access.

### Managed NFS

The Slurm cluster uses a shared NFS volume mounted across login and worker pods for home directories, job scripts, and shared data. This gives users a familiar HPC experience where files written on a login node are immediately visible to running jobs.

[Create a managed NFS file system](https://docs.digitalocean.com/products/nfs/how-to/create/) in the same VPC. Note that NFS performance scales with the size of the share. Larger shares get higher throughput and IOPS. For a PoC or small workloads, the smallest tier is fine; for production workloads with heavy I/O, size up accordingly.

Note the **Mount Source** from the NFS resource as you will need these for the PV definition in Section 4.

### Custom slurmd Container Image

GPU workers require a custom slurmd image that extends the upstream Slinky slurmd image with the CUDA runtime, NCCL collective communication libraries, the `nccl-tests` benchmarks, RDMA userspace tools, and MPI. The upstream image ships only the Slurm daemon and has none of these.

The recommended registry for DOKS is DigitalOcean Container Registry (DOCR), which now supports images up to 100 GB total with up to 5 GB per layer — comfortably above the size of this image. See the DigitalOcean docs for [creating a container registry](https://docs.digitalocean.com/products/container-registry/how-to/create-registry/) and [using it with Docker and DOKS](https://docs.digitalocean.com/products/container-registry/how-to/use-registry-docker-kubernetes/) (including the one-click integration that wires DOCR credentials into the cluster so you don't have to manage image pull secrets manually).

Build and push the image:

```bash
# Build the image (uses CUDA 12.9 toolkit for Blackwell Ultra / sm_103)
docker build -t registry.digitalocean.com/<your-registry>/slurmd-cuda:25.11 docker/slurmd-cuda/

# Push to your registry
doctl registry login
docker push registry.digitalocean.com/<your-registry>/slurmd-cuda:25.11
```

See [docker/slurmd-cuda/Dockerfile](../docker/slurmd-cuda/Dockerfile) for full build details — CUDA version selection (12.9 minimum for B300 native sm_103 codegen), the `nccl-tests` build flags, and the RDMA userspace packages baked in.

---

## 2. Namespace Layout

Create the Slurm namespace:

```bash
kubectl create namespace slurm        # Slinky operator + Slurm cluster
```

cert-manager and kube-prometheus-stack use `--create-namespace` in their Helm install commands to create their namespaces automatically.

**Skip the next block** unless you enabled the optional accounting backend in Section 1. The default minimal Slurm install does not need this secret.

```bash
# Only required if enabling Slurm accounting against managed MySQL
kubectl create secret generic slurm-db-password \
  --namespace slurm \
  --from-literal=password='<mysql-password>'
```

If your registry requires authentication, create an image pull secret so DOKS can pull the custom slurmd image. If you are using DOCR with the [one-click DOKS integration](https://docs.digitalocean.com/products/container-registry/how-to/use-registry-docker-kubernetes/), credentials are wired into the cluster automatically and **this step is not needed** — you can also omit the `imagePullSecrets:` block in Section 8.

```bash
# Example for a private GHCR (or other third-party) registry
kubectl create secret docker-registry slurmd-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<username> \
  --docker-password=<token> \
  --namespace=slurm
```

---

## 3. Prerequisite Helm Charts

Slinky requires **cert-manager** (for webhook TLS) and benefits from **kube-prometheus-stack** (for Slurm metrics and Grafana dashboards). Both should run on management nodes.

### cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

### kube-prometheus-stack

Create `prometheus-values.yaml` to use with helm install below:

```yaml
prometheus:
  prometheusSpec:
    retention: 7d

# Node-exporter runs on ALL nodes (DaemonSet) — tolerate GPU taints
prometheus-node-exporter:
  tolerations:
    - operator: Exists
```

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace prometheus --create-namespace \
  --values prometheus-values.yaml
```



---

## 4. NFS Shared Storage

### Optimize NFS Performance on GPU Nodes

GPU nodes support jumbo frames (MTU 9000) on the VPC interface, but if workload pods mount NFS before the interface is tuned, TCP connections negotiate at the default 1500 MTU and are never renegotiated — resulting in degraded throughput for the lifetime of those mounts.

To prevent this, deploy a DaemonSet that tunes network settings on GPU nodes **before** any workloads schedule. The DaemonSet uses a startup taint to hold off other pods until tuning completes. See [Optimize NFS Performance on GPU Nodes](https://docs.digitalocean.com/products/kubernetes/how-to/use-nfs-storage/#optimize-nfs-performance-on-gpu-nodes) for full details.

**Step 1** — Add a startup taint to the GPU node pool so that workloads cannot schedule until tuning completes. In the [cloud console](https://docs.digitalocean.com/products/kubernetes/how-to/add-node-pools/), edit the GPU node pool and add the taint:

- **Key**: `node.digitalocean.com/network-not-tuned`
- **Value**: `true`
- **Effect**: `NoSchedule`

Or via the CLI:

```bash
doctl kubernetes cluster node-pool update <cluster-id> <gpu-pool-id> \
  --taint "node.digitalocean.com/network-not-tuned=true:NoSchedule"
```

**Step 2** — Apply the GPU network tuner DaemonSet (includes RBAC resources):

```bash
kubectl apply -f manifests/gpu-network-tuner.yaml
kubectl rollout status daemonset/gpu-network-tuner -n kube-system --timeout=120s
```

The DaemonSet runs two init containers on each GPU node: the first sets TCP buffer sysctls and MTU 9000 via netplan, the second removes the startup taint so workloads can schedule. Once complete, all NFS mounts will negotiate at optimal MTU.

### Create NFS PV and PVC

The official Slinky guide does not cover shared storage. For job scripts, input data, and output files, create a PersistentVolume backed by the managed NFS and a PersistentVolumeClaim that login and worker pods will mount. `server` and `path` values come form the NFS **Mount Source** in the console.

```yaml
# slurm-nfs-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: slurm-nfs-pv
spec:
  capacity:
    storage: 100Gi # Scheduler hint only (NFS won't enforce quota)
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  mountOptions:
    - vers=4.1
    - nconnect=8
  nfs:
    server: <nfs-private-ip>       # e.g., 10.100.32.2
    path: <nfs-mount-path>         # e.g. /2633050/31489843-2785-4493-9ed4-8c9526627981
---
# slurm-nfs-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: slurm-nfs-pvc
  namespace: slurm
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""             # Bind to the static PV
  volumeName: slurm-nfs-pv
  resources:
    requests:
      storage: 100Gi
```

```bash
kubectl apply -f slurm-nfs-pv.yaml
kubectl apply -f slurm-nfs-pvc.yaml
```

Verify the PVC is **Bound** before proceeding:

```bash
kubectl get pvc -n slurm slurm-nfs-pvc
```

---

## 5. RDMA Fabric Setup

B300 GPU nodes on DOKS have 16 dedicated fabric NICs (`fabric0`–`fabric15`, two per GPU) used for RoCE (RDMA over Converged Ethernet) — high-bandwidth, low-latency GPU-to-GPU communication across nodes. These NICs must be attached into Slurm worker pods so that NCCL/RCCL can use them for collective operations. See [Configure Multi-Node GPU Communication](https://docs.digitalocean.com/products/kubernetes/how-to/configure-multinode-gpus/) for background on DOKS fabric networking.

> **NIC count by GPU generation:** The B300 (Blackwell Ultra) layout is **2 fabric NICs per GPU** for 16 total. Older NVIDIA generations on DOKS — including **H100 and H200** — have **1 fabric NIC per GPU** for **8 total** (`fabric0`–`fabric7`). On those nodes, create only 8 NADs, request only 8 `rdma/fabricN` resources per pod, and attach only 8 entries in the Multus annotation. The rest of the procedure is identical.

This requires [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni) (to attach multiple network interfaces to pods) and NetworkAttachmentDefinitions (NADs) that map each fabric NIC.

### Install Multus CNI

```bash
kubectl apply -f \
  https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=120s
```

### Create NetworkAttachmentDefinitions

Each NAD uses the `host-device` CNI plugin to move a host fabric NIC into the pod's network namespace. Here is the pattern for one interface:

```yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: roce-net-fabric0
  namespace: slurm
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "fabric0"
    }'
```

All 16 NADs (`roce-net-fabric0` through `roce-net-fabric15`) follow the same pattern, changing only the name and device field. Apply them all at once from the provided manifest:

```bash
kubectl apply -n slurm -f manifests/fabric-nads.yaml
```

### Verify

```bash
kubectl get net-attach-def -n slurm
# B300: 16 NADs (roce-net-fabric0 through roce-net-fabric15)
# H100/H200: 8 NADs (roce-net-fabric0 through roce-net-fabric7)
```

---

## 6. GPU Discovery

Slurm requires a `gres.conf` file to map GPU device paths so that it can schedule GPU resources. Autodetect is not available inside containers, so you must discover the device paths from a GPU node and feed them into the Helm values.

### Deploy a Probe Pod

Deploy a minimal pod on a GPU node to inspect available device paths. The pod needs a single GPU resource so it gets scheduled on a GPU node:

```yaml
# gpu-probe-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-probe
  namespace: slurm
spec:
  restartPolicy: Never
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: doks.digitalocean.com/gpu-brand
                operator: Exists
  tolerations:
    - key: nvidia.com/gpu       # Use amd.com/gpu for AMD nodes
      operator: Exists
      effect: NoSchedule
  containers:
    - name: probe
      image: ubuntu:24.04
      command: ["sleep", "300"]
      resources:
        limits:
          nvidia.com/gpu: 1     # Use amd.com/gpu for AMD nodes
```

```bash
kubectl apply -f gpu-probe-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-probe -n slurm --timeout=120s
```

### Discover NVIDIA GPU Devices

```bash
kubectl exec -n slurm gpu-probe -- ls /dev/nvidia[0-9]*
```

On a B300 node this lists eight devices, `/dev/nvidia0` through `/dev/nvidia7`. The resulting `gres.conf` line:

```
Name=gpu File=/dev/nvidia[0,1,2,3,4,5,6,7]
```

### Discover AMD GPU Devices (alternative)

If you are deploying on AMD GPU nodes instead, discover the DRM render device minor numbers:

```bash
kubectl exec -n slurm gpu-probe -- sh -c \
  'for d in /sys/class/drm/card*/device/vendor; do
     n=$(echo $d | grep -oP "card\K[0-9]+")
     echo $((n + 128))
   done | sort -n | paste -sd, -'
```

This outputs values like `128,136,144,152,160,168,176,184`, which become the `gres.conf` line:

```
Name=gpu File=/dev/dri/renderD[128,136,144,152,160,168,176,184]
```

### Clean Up

```bash
kubectl delete pod gpu-probe -n slurm
```

Save the discovered `gres.conf` line — you will use it in the Slurm cluster Helm values (Section 8).

---

## 7. Slinky Operator

Install the Slinky operator. The CRDs can be installed as a subchart by setting `crds.enabled=true`:

```bash
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --set 'crds.enabled=true' \
  --namespace slurm
```

---

## 8. Slurm Cluster

Deploy the Slurm cluster with all DOKS-specific customizations including GPU resources, RDMA fabric, custom container image, and shared memory.

Create `slurm-values.yaml` to use with helm install:

```yaml
# ── Controller (slurmctld) ──────────────────────────────────────────────
controller:
  extraConfMap:
    ReturnToService: 2       # Auto-return nodes after transient failures
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      labels:
        release: prometheus  # Must match your Prometheus Helm release name

# ── Accounting (slurmdbd) — disabled by default ─────────────────────────
# This guide deploys a minimal Slurm cluster without accounting. The job
# scheduler, GPU resources, RDMA fabric, login pods, and shared NFS all
# work without slurmdbd — you simply lose `sacct`, `sreport`, fair-share
# scheduling, and the multi-cluster federation features.
#
# To enable accounting, uncomment the block below. Two options:
#
#   A. In-cluster MariaDB (dev/test): keep `enabled: true` and remove the
#      entire `storageConfig:` block. Slinky deploys a MariaDB pod whose
#      lifecycle is tied to the Helm release. Easy to start, easy to lose.
#
#   B. Managed MySQL (production): keep `storageConfig:` and point it at
#      a managed MySQL instance in the same VPC. Requires the database,
#      user, and `slurm-db-password` Secret created in Sections 1 and 2.
#
# accounting:
#   enabled: true
#   storageConfig:
#     host: <mysql-private-host>     # <-- REPLACE with managed MySQL private hostname
#     port: 25060                    # <-- REPLACE if your managed DB uses a different port
#     database: slurm_acct
#     username: slurm
#     passwordKeyRef:
#       name: slurm-db-password      # Secret created in Section 2
#       key: password

# ── Login Nodes ─────────────────────────────────────────────────────────
loginsets:
  slinky:
    enabled: true
    login:
      volumeMounts:
        - name: shared-nfs
          mountPath: /shared
    podSpec:
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc
    service:
      spec:
        type: ClusterIP

# ── GRes Configuration (from Section 6 discovery) ──────────────────────
# Device paths are hardware-specific and discovered via the probe pod.
# NVIDIA B300 example: Name=gpu File=/dev/nvidia[0,1,2,3,4,5,6,7]
# AMD MI300X example:  Name=gpu File=/dev/dri/renderD[128,136,144,152,160,168,176,184]
configFiles:
  gres.conf: |
    Name=gpu File=/dev/nvidia[0,1,2,3,4,5,6,7]

# ── Image Pull Secret (created in Section 2) ───────────────────────────
imagePullSecrets:
  - name: slurmd-pull-secret

# ── GPU Worker Nodes ───────────────────────────────────────────────
#
# NVIDIA B300 example shown below. For AMD nodes, replace:
#   - nvidia.com/gpu → amd.com/gpu  (in tolerations and resources)
#   - gpu-brand label value → amd    (in nodeSelector)
#   - gres.conf line → Name=gpu File=/dev/dri/renderD[128,136,...,184]
#   - slurmd image  → your slurmd-rocm image
#
nodesets:
  slinky:
    replicas: 2                    # <-- REPLACE with your GPU node count
    slurmd:
      image:
        repository: registry.digitalocean.com/<your-registry>/slurmd-cuda   # <-- REPLACE with your image
        tag: "25.11"
      # B300 has 16 fabric NICs (2 per GPU). On H100/H200, drop
      # fabric8..fabric15 from both `requests` and `limits` below.
      resources:
        requests:
          nvidia.com/gpu: 8
          rdma/fabric0: 1
          rdma/fabric1: 1
          rdma/fabric2: 1
          rdma/fabric3: 1
          rdma/fabric4: 1
          rdma/fabric5: 1
          rdma/fabric6: 1
          rdma/fabric7: 1
          rdma/fabric8: 1
          rdma/fabric9: 1
          rdma/fabric10: 1
          rdma/fabric11: 1
          rdma/fabric12: 1
          rdma/fabric13: 1
          rdma/fabric14: 1
          rdma/fabric15: 1
        limits:
          nvidia.com/gpu: 8
          rdma/fabric0: 1
          rdma/fabric1: 1
          rdma/fabric2: 1
          rdma/fabric3: 1
          rdma/fabric4: 1
          rdma/fabric5: 1
          rdma/fabric6: 1
          rdma/fabric7: 1
          rdma/fabric8: 1
          rdma/fabric9: 1
          rdma/fabric10: 1
          rdma/fabric11: 1
          rdma/fabric12: 1
          rdma/fabric13: 1
          rdma/fabric14: 1
          rdma/fabric15: 1
      securityContext:
        privileged: true
        capabilities:
          add:
            - IPC_LOCK
      volumeMounts:
        - name: shared-nfs
          mountPath: /shared
        - name: shm
          mountPath: /dev/shm
    extraConfMap:
      Gres: "gpu:8"               # Tells slurmctld this nodeset has 8 GPUs per node
    partition:
      configMap:
        State: UP
        MaxTime: UNLIMITED
    # Multus annotation attaches all fabric NICs into the pod.
    # B300 has 16 NICs (2 per GPU); H100/H200 have 8 NICs (1 per GPU) —
    # for H100/H200, keep only entries fabric0..fabric7.
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: >-
          roce-net-fabric0@fabric0,
          roce-net-fabric1@fabric1,
          roce-net-fabric2@fabric2,
          roce-net-fabric3@fabric3,
          roce-net-fabric4@fabric4,
          roce-net-fabric5@fabric5,
          roce-net-fabric6@fabric6,
          roce-net-fabric7@fabric7,
          roce-net-fabric8@fabric8,
          roce-net-fabric9@fabric9,
          roce-net-fabric10@fabric10,
          roce-net-fabric11@fabric11,
          roce-net-fabric12@fabric12,
          roce-net-fabric13@fabric13,
          roce-net-fabric14@fabric14,
          roce-net-fabric15@fabric15
    podSpec:
      nodeSelector:
        doks.digitalocean.com/gpu-brand: nvidia  # <-- REPLACE with amd for AMD nodes
      tolerations:
        - key: nvidia.com/gpu       # <-- REPLACE with amd.com/gpu for AMD nodes
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc
        # Large shared memory for GPU collectives (NCCL uses /dev/shm)
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 64Gi
```

Key additions compared to a CPU-only deployment:

- **`configFiles.gres.conf`** — Maps GPU device paths so Slurm can schedule GPU resources
- **`imagePullSecrets`** — Allows DOKS to pull the custom slurmd image from a private registry
- **`slurmd.image`** — Uses the custom image with CUDA/NCCL instead of the upstream slurmd
- **`slurmd.resources`** — Requests 8 GPUs and 16 RDMA fabric devices per worker pod (8 fabric devices on H100/H200)
- **`extraConfMap.Gres`** — Tells slurmctld that each node in this nodeset has 8 GPUs
- **`metadata.annotations`** — Multus annotation attaches all fabric NICs into the pod — 16 on B300 (2 per GPU), 8 on H100/H200 (1 per GPU)
- **`shm` volume** — 64 GiB shared memory for GPU collective operations (NCCL uses `/dev/shm`)

```bash
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace slurm \
  --values slurm-values.yaml
```

---

## 9. Verification

After all Helm installs complete, run through these checks:

### Operator

In current Slinky chart releases the admission webhook is served from the same process as the controller, so a healthy install shows a **single** operator pod (not a separate webhook deployment as in older 0.3.x charts).

```bash
# One slurm-operator pod, Running and Ready, on a mgmt node
kubectl get pods -n slurm -l app.kubernetes.io/name=slurm-operator -o wide

# Webhook configurations should be registered
kubectl get validatingwebhookconfigurations | grep slurm
kubectl get mutatingwebhookconfigurations  | grep slurm

# The webhook Service should have a populated Endpoints list
kubectl get svc,endpoints -n slurm -l app.kubernetes.io/name=slurm-operator
```

If the `helm install slurm …` step in Section 8 created `slurm-controller`, `slurm-login-*`, and `slurm-worker-*` pods without `denied the request` errors, the webhook is functionally working regardless of how many pods you see.

### Slurm Components

```bash
kubectl get pods -n slurm
# Expected: controller, restapi, login, and worker pods all Running.
# If you enabled accounting in Section 8, an `accounting` pod (slurmdbd)
# is also present.
```

### Node Health

```bash
# Exec into the login pod
kubectl exec -it -n slurm deploy/slurm-login-slinky -- bash

# Inside the pod:
sinfo -N -l
# All nodes should show "idle" state
```

### GPU Resources

```bash
# Inside a login pod:
scontrol show node slinky-0 | grep -i gres
# Should show: Gres=gpu:8 and GresUsed=gpu:0
```

### Accounting (only if enabled)

Skip this check if you left accounting commented out in Section 8 — `sacctmgr` will return an error against a cluster without `slurmdbd`.

```bash
# Inside a login pod, only if accounting is enabled:
sacctmgr show cluster
# Should show your cluster registered with the configured storage backend
# (managed MySQL, or the in-cluster MariaDB if you used Option A)
```

### Shared Storage

```bash
# From a login pod:
echo "hello" > /shared/test.txt

# From a worker pod:
kubectl exec -it -n slurm slurm-worker-slinky-0 -- cat /shared/test.txt
# Should print "hello"
```

### Fabric NICs

```bash
# Verify fabric interfaces are present inside a worker pod
kubectl exec -n slurm slurm-worker-slinky-0 -- ip -br link | grep fabric
# B300: fabric0 through fabric15 (16 NICs, 2 per GPU)
# H100/H200: fabric0 through fabric7 (8 NICs, 1 per GPU)

# Verify RDMA devices (requires custom slurmd image)
kubectl exec -n slurm slurm-worker-slinky-0 -- ibv_devices
# Should list one mlx5 device per fabric NIC (16 on B300, 8 on H100/H200)
```

### REST API

```bash
# From a login pod, generate a JWT token:
scontrol token lifespan=600

# Port-forward slurmrestd:
kubectl port-forward -n slurm svc/slurm-restapi 6820:6820 &

# Query the API (from your local machine).
# The /slurm/* endpoints are served by slurmctld and work on any install.
curl -s -H "X-SLURM-USER-NAME: root" \
     -H "X-SLURM-USER-TOKEN: <token>" \
     http://localhost:6820/slurm/v0.0.43/diag | jq .

# The /slurmdb/* endpoints require slurmdbd — only available if you
# enabled accounting in Section 8:
# curl -s -H "X-SLURM-USER-NAME: root" \
#      -H "X-SLURM-USER-TOKEN: <token>" \
#      http://localhost:6820/slurmdb/v0.0.43/clusters | jq .
```

### Metrics

```bash
# Port-forward Grafana:
kubectl port-forward -n prometheus svc/prometheus-grafana 3000:80

# Retrieve the admin password:
kubectl get secret -n prometheus prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Open http://localhost:3000, log in, and verify Slurm metrics appear
# in the Prometheus data source (search for metrics prefixed with slurm_)
```

---

## 10. NCCL Validation

NCCL (NVIDIA Collective Communications Library) validation confirms that GPU-to-GPU communication is working correctly, both within a single node (over NVLink) and across nodes (over the RDMA fabric). This is the final validation step before running real training workloads.

**Prerequisites**: Fabric deployed (Section 5), workers running the custom slurmd-cuda image, compute nodes idle (`sinfo` shows `idle` state). The `all_reduce_perf`, `reduce_scatter_perf`, and `all_gather_perf` binaries from `nccl-tests` are baked into `/usr/local/bin/` of the slurmd-cuda image.

### Single-Node Test

Tests GPU-to-GPU bandwidth within one node (8 GPUs over NVLink). From a login pod, create and submit the job script:

```bash
mkdir -p /shared/output /shared/jobs

cat > /shared/jobs/nccl-allreduce-1node.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=nccl-allreduce-1node
#SBATCH --partition=slinky
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --output=/shared/output/allreduce-1node-%j.out
#SBATCH --error=/shared/output/allreduce-1node-%j.err
#SBATCH --time=00:30:00

mkdir -p /shared/output

# CUDA / NCCL runtime libraries (baked into the slurmd-cuda image)
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}
export NCCL_DEBUG=INFO

# MPI control traffic over pod network
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=eth0

srun --mpi=pmix \
  /usr/local/bin/all_reduce_perf \
  -b 1 -e 16G -f 2 -g 1 -c 1 -n 100
EOF

sbatch /shared/jobs/nccl-allreduce-1node.sh
```

Expected results: a bandwidth table from `all_reduce_perf`. On B300 (NVLink 5) the in-place bus bandwidth saturates in the hundreds of GB/s for large message sizes — well above what any single fabric NIC could deliver — which confirms the collective stayed on NVLink and never escaped the node.

### Multi-Node Test

Tests GPU-to-GPU bandwidth across 2 nodes (16 GPUs) using the RDMA fabric:

```bash
cat > /shared/jobs/nccl-allreduce-2node.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=nccl-allreduce-2node
#SBATCH --partition=slinky
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --output=/shared/output/allreduce-2node-%j.out
#SBATCH --error=/shared/output/allreduce-2node-%j.err
#SBATCH --time=01:00:00

mkdir -p /shared/output

# CUDA / NCCL runtime libraries
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}
export NCCL_DEBUG=INFO

# MPI control traffic over pod network
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=eth0

# RDMA fabric hints (uncomment if NCCL doesn't auto-detect the HCAs).
# B300 has 16 HCAs; on H100/H200 trim this list to mlx5_0..mlx5_7.
# export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_12,mlx5_13,mlx5_14,mlx5_15
# export NCCL_NET_GDR_LEVEL=5

srun --mpi=pmix \
  /usr/local/bin/all_reduce_perf \
  -b 1G -e 16G -f 2 -g 1 -c 1 -n 100
EOF

sbatch /shared/jobs/nccl-allreduce-2node.sh
```

Expected results: a bandwidth table from `all_reduce_perf` along with `NCCL_DEBUG=INFO` output showing `NET/IB` transport selection over the `mlx5_*` devices. On B300 with all 16 fabric NICs engaged, expect inter-node bus bandwidth in the hundreds of GB/s; values that collapse to a few GB/s indicate NCCL fell back to TCP rather than RDMA.

### Environment Variables Explained

| Variable | Purpose |
|----------|---------|
| `LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu` | Ensures the CUDA runtime and NCCL libraries are found at runtime |
| `NCCL_DEBUG=INFO` | Enables NCCL debug logging — shows transport selection (`NET/IB` for RoCE) |
| `OMPI_MCA_btl=self,tcp` | Restricts MPI control traffic to TCP (not RDMA) — keeps fabric NICs free for GPU data |
| `OMPI_MCA_btl_tcp_if_include=eth0` | Forces MPI TCP traffic over the pod's primary network interface |

### Reading Output

Job output is written to NFS at `/shared/output/`:

```
/shared/output/allreduce-1node-<jobid>.out
/shared/output/allreduce-2node-<jobid>.out
```

Monitor job progress:

```bash
squeue                                        # Check job state
cat /shared/output/allreduce-1node-*.out      # View single-node results
cat /shared/output/allreduce-2node-*.out      # View multi-node results
```

### Fabric Verification

If NCCL tests fail or show unexpectedly low bandwidth, verify the fabric is correctly configured inside worker pods:

```bash
# Check fabric interfaces are present
kubectl exec -n slurm slurm-worker-slinky-0 -- ip -br link | grep fabric
# B300: fabric0..fabric15, all UP. H100/H200: fabric0..fabric7, all UP.

# Check RDMA devices
kubectl exec -n slurm slurm-worker-slinky-0 -- ibv_devices
# B300: mlx5_0..mlx5_15 (one per fabric NIC). H100/H200: mlx5_0..mlx5_7.

# Check RDMA device details
kubectl exec -n slurm slurm-worker-slinky-0 -- ibv_devinfo
# Should show active port state and RoCE link layer (Ethernet)
```
