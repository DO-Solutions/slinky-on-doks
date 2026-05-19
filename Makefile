SHELL := /bin/bash
.DEFAULT_GOAL := help
TF := terraform -chdir=terraform

# Accept DO_API_TOKEN as alias for DIGITALOCEAN_TOKEN (DigitalOcean SE convention)
ifdef DO_API_TOKEN
  export DIGITALOCEAN_TOKEN := $(DO_API_TOKEN)
endif

CLUSTER_NAME := $(shell $(TF) output -raw cluster_name 2>/dev/null || echo "slinky-poc")

ifndef SLURMD_IMAGE
  $(warning SLURMD_IMAGE is not set — defaulting to placeholder. Set via: export SLURMD_IMAGE=ghcr.io/yourorg/slurmd-rocm:25.11)
  SLURMD_IMAGE := slurmd-rocm:latest
endif

# ── Infrastructure (Terraform) ───────────────────────────────────────────────

.PHONY: infra/init
infra/init: ## Initialize Terraform providers and backend
	$(TF) init

.PHONY: infra/plan
infra/plan: ## Preview infrastructure changes
	$(TF) plan

.PHONY: infra/apply
infra/apply: ## Provision DOKS, MySQL, NFS, VPC
	$(TF) apply -auto-approve

.PHONY: infra/destroy
infra/destroy: ## Destroy all infrastructure
	$(TF) destroy -auto-approve

.PHONY: infra/kubeconfig
infra/kubeconfig: ## Save kubeconfig — from Terraform state, or via doctl for existing clusters
	@mkdir -p ~/.kube
	@KC=$$($(TF) output -raw kubeconfig 2>/dev/null) && \
	if [ -n "$$KC" ]; then \
		echo "$$KC" > ~/.kube/config && echo "Kubeconfig saved from Terraform."; \
	else \
		echo "Cluster is external — fetching kubeconfig via doctl..." && \
		doctl kubernetes cluster kubeconfig save $(CLUSTER_NAME); \
	fi
	@kubectl get nodes

.PHONY: infra/output
infra/output: ## Print all Terraform outputs
	$(TF) output

.PHONY: infra/import-cluster
infra/import-cluster: ## Import existing DOKS cluster into Terraform state (set CLUSTER_NAME=<name>)
	@echo "Looking up cluster: $(CLUSTER_NAME)"
	@CLUSTER_ID=$$(doctl kubernetes cluster get $(CLUSTER_NAME) --format ID --no-header 2>/dev/null) && \
	[ -n "$$CLUSTER_ID" ] || { echo "ERROR: cluster '$(CLUSTER_NAME)' not found. Run: doctl kubernetes cluster list"; exit 1; } && \
	VPC_ID=$$(doctl kubernetes cluster get $(CLUSTER_NAME) -o json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['vpc_uuid'])") && \
	[ -n "$$VPC_ID" ] || { echo "ERROR: could not read VPC UUID for cluster '$(CLUSTER_NAME)'"; exit 1; } && \
	echo "Importing cluster $$CLUSTER_ID and VPC $$VPC_ID..." && \
	$(TF) import digitalocean_kubernetes_cluster.main $$CLUSTER_ID || true && \
	$(TF) import digitalocean_vpc.main $$VPC_ID || true && \
	echo "Done. Run 'make infra/plan' to verify no cluster changes, then 'make up-from-existing'."

# ── Prerequisites (Helm + Manifests) ─────────────────────────────────────────

.PHONY: prereqs/install
prereqs/install: ## Install cert-manager and prometheus
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update
	helm upgrade --install cert-manager jetstack/cert-manager \
		--set crds.enabled=true \
		--namespace cert-manager --create-namespace \
		--wait
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
		--values helm/prerequisites/prometheus-values.yaml \
		--namespace prometheus --create-namespace \
		--wait

.PHONY: prereqs/status
prereqs/status: ## Check pod status across prerequisite namespaces
	@echo "=== cert-manager ==="
	kubectl get pods -n cert-manager
	@echo ""
	@echo "=== prometheus ==="
	kubectl get pods -n prometheus

.PHONY: prereqs/uninstall
prereqs/uninstall: ## Uninstall all prerequisites
	-helm uninstall prometheus -n prometheus
	-helm uninstall cert-manager -n cert-manager
	-kubectl delete namespace prometheus --ignore-not-found
	-kubectl delete namespace cert-manager --ignore-not-found

# ── NFS (PV/PVC from Managed NFS) ────────────────────────────────────────────

.PHONY: nfs/configure
nfs/configure: ## Generate NFS PV from template, create namespace, apply PV + PVC
	@NFS_HOST=$${NFS_HOST:-$$($(TF) output -raw nfs_host)} && \
	NFS_PATH=$${NFS_PATH:-$$($(TF) output -raw nfs_mount_path)} && \
	sed "s|__NFS_HOST__|$$NFS_HOST|g; s|__NFS_PATH__|$$NFS_PATH|g" \
		manifests/nfs-pv.yaml.tpl > manifests/nfs-pv.yaml && \
	kubectl apply -f manifests/slurm-namespace.yaml && \
	kubectl apply -f manifests/nfs-pv.yaml && \
	kubectl apply -f manifests/nfs-pvc.yaml

.PHONY: nfs/test
nfs/test: ## Deploy busybox pod to verify NFS read/write
	@echo "Deploying NFS test pod..."
	kubectl apply -f manifests/nfs-test-pod.yaml
	@echo "Waiting for pod to be ready..."
	kubectl wait --for=condition=Ready pod/nfs-test -n slurm --timeout=60s
	@echo "Testing write..."
	kubectl exec nfs-test -n slurm -- sh -c 'echo "NFS test $$(date)" > /mnt/nfs/test-file.txt'
	@echo "Testing read..."
	kubectl exec nfs-test -n slurm -- cat /mnt/nfs/test-file.txt
	@echo "Cleaning up..."
	kubectl delete pod nfs-test -n slurm --ignore-not-found

.PHONY: nfs/gpu-tuner
nfs/gpu-tuner: ## Deploy GPU network tuner DaemonSet (MTU 9000 + TCP buffers)
	kubectl apply -f manifests/gpu-network-tuner.yaml
	@echo "Waiting for gpu-network-tuner rollout..."
	kubectl rollout status daemonset/gpu-network-tuner -n kube-system --timeout=120s

.PHONY: nfs/gpu-tuner-uninstall
nfs/gpu-tuner-uninstall: ## Remove GPU network tuner DaemonSet
	-kubectl delete -f manifests/gpu-network-tuner.yaml

.PHONY: nfs/status
nfs/status: ## Check PV/PVC binding status
	@echo "=== PersistentVolumes ==="
	kubectl get pv
	@echo ""
	@echo "=== PersistentVolumeClaims ==="
	kubectl get pvc -A

# ── Docker (Custom slurmd Image) ─────────────────────────────────────────────

.PHONY: docker/build-slurmd
docker/build-slurmd: ## Build custom slurmd image with ROCm/RCCL (AMD)
	docker build -t $(SLURMD_IMAGE) docker/slurmd-rocm/

.PHONY: docker/build-slurmd-cuda
docker/build-slurmd-cuda: ## Build custom slurmd image with CUDA/NCCL (NVIDIA)
	docker build -t $(SLURMD_IMAGE) docker/slurmd-cuda/

.PHONY: docker/push-slurmd
docker/push-slurmd: ## Push slurmd image (login to your registry first)
	docker push $(SLURMD_IMAGE)

# ── Fabric (Multus + NetworkAttachmentDefinitions) ───────────────────────────

.PHONY: fabric/install-multus
fabric/install-multus: ## Install Multus CNI plugin
	kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
	@echo "Waiting for Multus pods..."
	kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=120s

.PHONY: fabric/install-nads
fabric/install-nads: ## Create fabric NetworkAttachmentDefinitions in slurm namespace
	kubectl apply -f manifests/fabric-nads.yaml --namespace=slurm

.PHONY: fabric/install
fabric/install: fabric/install-multus fabric/install-nads ## Install Multus + NADs

.PHONY: fabric/status
fabric/status: ## Check Multus and NAD status
	@echo "=== Multus Pods ==="
	kubectl get pods -n kube-system -l app=multus
	@echo ""
	@echo "=== NetworkAttachmentDefinitions ==="
	kubectl get net-attach-def -n slurm

.PHONY: fabric/uninstall
fabric/uninstall: ## Remove fabric NADs and Multus
	-kubectl delete -f manifests/fabric-nads.yaml --namespace=slurm
	-kubectl delete -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

# ── GPU Discovery ────────────────────────────────────────────────────────────

.PHONY: gpu/discover-gres
gpu/discover-gres: ## Discover GPU device paths via debug pod and save gres.conf line
	@kubectl delete pod gpu-probe -n slurm --ignore-not-found 2>/dev/null && \
	GPU_VENDOR=$${GPU_VENDOR:-$$($(TF) output -raw gpu_vendor)} && \
	GPU_TAINT_KEY=$${GPU_TAINT_KEY:-$$($(TF) output -raw gpu_taint_key)} && \
	GPU_RESOURCE_KEY="$$GPU_VENDOR.com/gpu" && \
	echo "Deploying GPU probe pod (vendor=$$GPU_VENDOR)..." && \
	sed "s|__GPU_TAINT_KEY__|$$GPU_TAINT_KEY|g; s|__GPU_RESOURCE_KEY__|$$GPU_RESOURCE_KEY|g" \
		manifests/gpu-probe-pod.yaml.tpl | kubectl apply -f - && \
	echo "Waiting for gpu-probe pod..." && \
	kubectl wait --for=condition=Ready pod/gpu-probe -n slurm --timeout=120s && \
	if [ "$$GPU_VENDOR" = "amd" ]; then \
		NUMS=$$(kubectl exec -n slurm gpu-probe -- sh -c \
			'for d in /sys/class/drm/card*/device/vendor; do \
				n=$$(echo $$d | grep -oP "card\K[0-9]+"); \
				echo $$((n + 128)); \
			done | sort -n | paste -sd, -') && \
		GRES_LINE="Name=gpu File=/dev/dri/renderD[$$NUMS]"; \
	else \
		NUMS=$$(kubectl exec -n slurm gpu-probe -- sh -c \
			'ls -1 /dev/nvidia[0-9]* 2>/dev/null | sed "s|.*/nvidia||" | sort -n | paste -sd, -') && \
		GRES_LINE="Name=gpu File=/dev/nvidia[$$NUMS]"; \
	fi && \
	kubectl delete pod gpu-probe -n slurm --ignore-not-found && \
	echo "$$GRES_LINE" > helm/slinky/.gres-conf-line && \
	echo "" && echo "Discovered gres.conf:" && \
	echo "  $$GRES_LINE" && \
	echo "(Saved to helm/slinky/.gres-conf-line)"

# ── Slinky / Slurm ──────────────────────────────────────────────────────────

.PHONY: slinky/create-db-secret
slinky/create-db-secret: ## Create Slurm DB password secret from Terraform output
	@DB_PASS=$${DB_PASSWORD:-$$($(TF) output -raw db_password)} && \
	kubectl create secret generic slurm-db-password \
		--namespace slurm \
		--from-literal=password="$$DB_PASS" \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: slinky/install-operator
slinky/install-operator: ## Install slurm-operator with CRDs
	helm upgrade --install slurm-operator \
		oci://ghcr.io/slinkyproject/charts/slurm-operator \
		--set crds.enabled=true \
		--namespace slinky --create-namespace \
		--wait

.PHONY: slinky/configure
slinky/configure: ## Generate values-slurm.yaml from template using Terraform outputs
	@DB_HOST=$${DB_HOST:-$$($(TF) output -raw db_host)} && \
	GPU_VENDOR=$${GPU_VENDOR:-$$($(TF) output -raw gpu_vendor)} && \
	GPU_TAINT_KEY=$${GPU_TAINT_KEY:-$$($(TF) output -raw gpu_taint_key)} && \
	GPU_NODE_COUNT=$${GPU_NODE_COUNT:-$$($(TF) output -raw gpu_node_count)} && \
	IMG_REPO=$$(echo '$(SLURMD_IMAGE)' | sed 's|:[^:]*$$||') && \
	IMG_TAG=$$(echo '$(SLURMD_IMAGE)' | sed 's|.*:||') && \
	if [ -f helm/slinky/.gres-conf-line ]; then \
		GRES_LINE=$$(cat helm/slinky/.gres-conf-line); \
	else \
		echo "WARNING: helm/slinky/.gres-conf-line not found. Run 'make gpu/discover-gres' first." >&2; \
		GRES_LINE="Name=gpu File=/dev/UNKNOWN — run: make gpu/discover-gres"; \
	fi && \
	sed "s|__DB_HOST__|$$DB_HOST|g; s|__GPU_VENDOR__|$$GPU_VENDOR|g; s|__GPU_TAINT_KEY__|$$GPU_TAINT_KEY|g; s|__GPU_NODE_COUNT__|$$GPU_NODE_COUNT|g; s|__SLURMD_IMAGE_REPO__|$$IMG_REPO|g; s|__SLURMD_IMAGE_TAG__|$$IMG_TAG|g; s|__GRES_CONF_LINE__|$$GRES_LINE|g" \
		helm/slinky/values-slurm.yaml.tpl > helm/slinky/values-slurm.yaml

.PHONY: slinky/create-pull-secret
slinky/create-pull-secret: ## Create image pull secret (set REGISTRY_USER and REGISTRY_PASSWORD)
	@IMG_SERVER=$$(echo '$(SLURMD_IMAGE)' | cut -d/ -f1) && \
	kubectl create secret docker-registry slurmd-pull-secret \
		--docker-server="$$IMG_SERVER" \
		--docker-username="$$REGISTRY_USER" \
		--docker-password="$$REGISTRY_PASSWORD" \
		--namespace=slurm \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: slinky/install-slurm
slinky/install-slurm: slinky/create-db-secret slinky/create-pull-secret slinky/configure ## Install Slurm cluster
	helm upgrade --install slurm \
		oci://ghcr.io/slinkyproject/charts/slurm \
		--values helm/slinky/values-slurm.yaml \
		--namespace slurm --create-namespace \
		--wait --timeout 10m

.PHONY: slinky/update-slurm
slinky/update-slurm: slinky/configure ## Helm upgrade Slurm cluster with updated values
	helm upgrade slurm \
		oci://ghcr.io/slinkyproject/charts/slurm \
		--values helm/slinky/values-slurm.yaml \
		--namespace slurm \
		--wait --timeout 10m

.PHONY: slinky/status
slinky/status: ## Show pods across slinky + slurm namespaces
	@echo "=== Slinky Operator ==="
	kubectl get pods -n slinky
	@echo ""
	@echo "=== Slurm Cluster ==="
	kubectl get pods -n slurm
	@echo ""
	@echo "=== Slurm Node Status ==="
	-kubectl exec -n slurm deploy/slurm-login-slinky -- sinfo 2>/dev/null || echo "(login pod not ready)"

.PHONY: slinky/uninstall
slinky/uninstall: ## Uninstall Slurm cluster, operator, CRDs
	-helm uninstall slurm -n slurm
	-helm uninstall slurm-operator -n slinky
	-kubectl delete namespace slurm --ignore-not-found
	-kubectl delete namespace slinky --ignore-not-found

.PHONY: slinky/logs
slinky/logs: ## Tail operator and controller logs
	@echo "=== Slurm Operator Logs ==="
	kubectl logs -n slinky -l app.kubernetes.io/name=slurm-operator --tail=50 --prefix
	@echo ""
	@echo "=== Slurm Controller Logs ==="
	-kubectl logs -n slurm -l app.kubernetes.io/component=slurmctld --tail=50 --prefix

# ── Slurm Operations ─────────────────────────────────────────────────────────

.PHONY: slurm/shell
slurm/shell: ## Interactive shell on the login pod
	kubectl exec -it -n slurm deploy/slurm-login-slinky -- /bin/bash

.PHONY: slurm/info
slurm/info: ## Run sinfo, squeue, and show partitions
	@echo "=== sinfo ==="
	kubectl exec -n slurm deploy/slurm-login-slinky -- sinfo
	@echo ""
	@echo "=== squeue ==="
	kubectl exec -n slurm deploy/slurm-login-slinky -- squeue
	@echo ""
	@echo "=== partitions ==="
	kubectl exec -n slurm deploy/slurm-login-slinky -- scontrol show partitions

.PHONY: slurm/test-fabric
slurm/test-fabric: ## Verify fabric NICs and RDMA devices on GPU workers
	@echo "=== Fabric NICs ==="
	kubectl exec -n slurm sts/slurm-worker-slinky -c slurmd -- ip link show | grep -E 'fabric[0-9]|fabric1[0-5]' || echo "No fabric interfaces found"
	@echo ""
	@echo "=== RDMA Devices ==="
	kubectl exec -n slurm sts/slurm-worker-slinky -c slurmd -- ibv_devices 2>/dev/null || echo "ibv_devices not available"

.PHONY: slurm/submit-test
slurm/submit-test: ## Copy job scripts to NFS and submit basic test jobs
	scripts/submit-test-jobs.sh

.PHONY: slurm/run-validation
slurm/run-validation: ## Run the full validation suite
	scripts/run-validation-suite.sh

.PHONY: slurm/submit-rccl-1node
slurm/submit-rccl-1node: ## Submit single-node RCCL all-reduce test
	kubectl exec -i -n slurm deploy/slurm-login-slinky -c login -- tee /shared/jobs/rccl-allreduce-1node.sh < jobs/rccl-allreduce-1node.sh > /dev/null
	kubectl exec -n slurm deploy/slurm-login-slinky -c login -- chmod +x /shared/jobs/rccl-allreduce-1node.sh
	kubectl exec -n slurm deploy/slurm-login-slinky -- sbatch /shared/jobs/rccl-allreduce-1node.sh

.PHONY: slurm/submit-rccl-2node
slurm/submit-rccl-2node: ## Submit multi-node RCCL all-reduce test (AMD)
	kubectl exec -i -n slurm deploy/slurm-login-slinky -c login -- tee /shared/jobs/rccl-allreduce-2node.sh < jobs/rccl-allreduce-2node.sh > /dev/null
	kubectl exec -n slurm deploy/slurm-login-slinky -c login -- chmod +x /shared/jobs/rccl-allreduce-2node.sh
	kubectl exec -n slurm deploy/slurm-login-slinky -- sbatch /shared/jobs/rccl-allreduce-2node.sh

.PHONY: slurm/submit-nccl-1node
slurm/submit-nccl-1node: ## Submit single-node NCCL all-reduce test (NVIDIA)
	kubectl exec -i -n slurm deploy/slurm-login-slinky -c login -- tee /shared/jobs/nccl-allreduce-1node.sh < jobs/nccl-allreduce-1node.sh > /dev/null
	kubectl exec -n slurm deploy/slurm-login-slinky -c login -- chmod +x /shared/jobs/nccl-allreduce-1node.sh
	kubectl exec -n slurm deploy/slurm-login-slinky -- sbatch /shared/jobs/nccl-allreduce-1node.sh

.PHONY: slurm/submit-nccl-2node
slurm/submit-nccl-2node: ## Submit multi-node NCCL all-reduce test (NVIDIA)
	kubectl exec -i -n slurm deploy/slurm-login-slinky -c login -- tee /shared/jobs/nccl-allreduce-2node.sh < jobs/nccl-allreduce-2node.sh > /dev/null
	kubectl exec -n slurm deploy/slurm-login-slinky -c login -- chmod +x /shared/jobs/nccl-allreduce-2node.sh
	kubectl exec -n slurm deploy/slurm-login-slinky -- sbatch /shared/jobs/nccl-allreduce-2node.sh

.PHONY: slurm/test-restapi
slurm/test-restapi: ## Test slurmrestd API endpoints
	scripts/test-restapi.sh

# ── Observability ─────────────────────────────────────────────────────────────

.PHONY: obs/dashboard
obs/dashboard: ## Deploy Slurm Grafana dashboard (ConfigMap loaded by sidecar)
	kubectl apply -f manifests/grafana-slurm-dashboard.yaml

.PHONY: obs/grafana
obs/grafana: ## Port-forward Grafana to localhost:3000
	@echo "Grafana available at http://localhost:3000 (admin/prom-operator)"
	kubectl port-forward -n prometheus svc/prometheus-grafana 3000:80

.PHONY: obs/prometheus
obs/prometheus: ## Port-forward Prometheus to localhost:9090
	@echo "Prometheus available at http://localhost:9090"
	kubectl port-forward -n prometheus svc/prometheus-kube-prometheus-prometheus 9090:9090

# ── Lifecycle / Compound Targets ──────────────────────────────────────────────

.PHONY: up
up: infra/apply infra/kubeconfig nfs/gpu-tuner prereqs/install nfs/configure fabric/install slinky/install-operator slinky/install-slurm ## Full deploy: infra -> kubeconfig -> gpu-tuner -> prereqs -> nfs -> fabric -> slinky

.PHONY: up-from-existing
up-from-existing: infra/apply infra/kubeconfig nfs/gpu-tuner prereqs/install nfs/configure fabric/install slinky/install-operator slinky/install-slurm ## Deploy Slinky on existing DOKS cluster (run make infra/import-cluster first)

.PHONY: down
down: slinky/uninstall fabric/uninstall prereqs/uninstall nfs/gpu-tuner-uninstall infra/destroy ## Full teardown: slinky -> fabric -> prereqs -> gpu-tuner -> infra

.PHONY: status
status: infra/output prereqs/status nfs/status fabric/status slinky/status slurm/info ## Show status of all components

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z/_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'
