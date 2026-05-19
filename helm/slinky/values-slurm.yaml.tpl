# Slurm Cluster on DOKS — GPU worker values
# Generated from values-slurm.yaml.tpl by `make slinky/configure`

# ── Image tag overrides (chart default 25.11-ubuntu24.04 does not exist; use patch release)
controller:
  slurmctld:
    image:
      tag: "25.11.5-ubuntu24.04"
  reconfigure:
    image:
      tag: "25.11.5-ubuntu24.04"
  extraConfMap:
    ReturnToService: 2
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      labels:
        release: prometheus

# ── Accounting (slurmdbd) ───────────────────────────────────────────────────
accounting:
  slurmdbd:
    image:
      tag: "25.11.5-ubuntu24.04"
  enabled: true
  storageConfig:
    host: __DB_HOST__
    port: 25060
    database: slurm_acct
    username: slurm
    passwordKeyRef:
      name: slurm-db-password
      key: password

# ── Login Nodes ──────────────────────────────────────────────────────────────
loginsets:
  slinky:
    enabled: true
    login:
      image:
        tag: "25.11.5-ubuntu24.04"
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


# ── REST API (slurmrestd) ────────────────────────────────────────────────────
restapi:
  slurmrestd:
    image:
      tag: "25.11.5-ubuntu24.04"

# ── Slurm GRes (auto-discovered by `make gpu/discover-gres`) ─────────────
# Device paths are hardware-specific and discovered via a debug pod.
# Run `make gpu/discover-gres` before `make slinky/configure`.
# AMD MI300X example: Name=gpu File=/dev/dri/renderD[128,136,144,152,160,168,176,184]
# NVIDIA example:     Name=gpu File=/dev/nvidia[0,1,2,3,4,5,6,7]
configFiles:
  gres.conf: |
    __GRES_CONF_LINE__

# ── GHCR pull secret for custom slurmd image ──────────────────────────────
imagePullSecrets:
  - name: slurmd-pull-secret

# ── GPU Worker Nodes ────────────────────────────────────────────────────────
nodesets:
  slinky:
    replicas: __GPU_NODE_COUNT__
    slurmd:
      image:
        repository: __SLURMD_IMAGE_REPO__
        tag: "__SLURMD_IMAGE_TAG__"
      resources:
        requests:
          __GPU_VENDOR__.com/gpu: 8
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
          __GPU_VENDOR__.com/gpu: 8
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
      Gres: "gpu:8"
    partition:
      configMap:
        State: UP
        MaxTime: UNLIMITED
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
        doks.digitalocean.com/gpu-brand: __GPU_VENDOR__
      tolerations:
        - key: __GPU_TAINT_KEY__
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: shared-nfs
          persistentVolumeClaim:
            claimName: slurm-nfs-pvc
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 64Gi
