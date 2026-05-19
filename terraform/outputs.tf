# ── Cluster ───────────────────────────────────────────────────────────────────

output "cluster_id" {
  description = "DOKS cluster ID"
  value       = local.cluster_id
}

output "cluster_endpoint" {
  description = "DOKS cluster API endpoint"
  value       = length(digitalocean_kubernetes_cluster.main) > 0 ? digitalocean_kubernetes_cluster.main[0].endpoint : ""
}

output "cluster_name" {
  description = "DOKS cluster name"
  value       = length(digitalocean_kubernetes_cluster.main) > 0 ? digitalocean_kubernetes_cluster.main[0].name : var.project_name
}

output "kubeconfig" {
  description = "Kubeconfig for the DOKS cluster (empty when using existing_cluster_id)"
  value       = length(digitalocean_kubernetes_cluster.main) > 0 ? digitalocean_kubernetes_cluster.main[0].kube_config[0].raw_config : ""
  sensitive   = true
}

output "k8s_version" {
  description = "Kubernetes version"
  value       = length(digitalocean_kubernetes_cluster.main) > 0 ? digitalocean_kubernetes_cluster.main[0].version : ""
}

# ── VPC ──────────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = local.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = length(digitalocean_vpc.main) > 0 ? digitalocean_vpc.main[0].ip_range : ""
}

# ── Database ─────────────────────────────────────────────────────────────────

output "db_host" {
  description = "MySQL private hostname"
  value       = digitalocean_database_cluster.mysql.private_host
}

output "db_port" {
  description = "MySQL port"
  value       = digitalocean_database_cluster.mysql.port
}

output "db_name" {
  description = "MySQL database name"
  value       = digitalocean_database_db.slurm_acct.name
}

output "db_user" {
  description = "MySQL user"
  value       = digitalocean_database_user.slurm.name
}

output "db_password" {
  description = "MySQL password"
  value       = digitalocean_database_user.slurm.password
  sensitive   = true
}

# ── GPU ──────────────────────────────────────────────────────────────────────

output "gpu_vendor" {
  description = "GPU vendor (amd or nvidia)"
  value       = var.gpu_vendor
}

output "gpu_taint_key" {
  description = "GPU taint key derived from vendor"
  value       = "${var.gpu_vendor}.com/gpu"
}

output "gpu_node_count" {
  description = "Number of GPU worker nodes"
  value       = var.gpu_node_count
}

# ── NFS ──────────────────────────────────────────────────────────────────────

output "nfs_host" {
  description = "NFS server hostname"
  value       = digitalocean_nfs.shared.host
}

output "nfs_mount_path" {
  description = "NFS mount path"
  value       = digitalocean_nfs.shared.mount_path
}

output "nfs_id" {
  description = "NFS share ID"
  value       = digitalocean_nfs.shared.id
}
