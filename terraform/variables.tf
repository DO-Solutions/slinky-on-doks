variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "ric1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "slinky-poc"
}

# ── VPC ──────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.100.32.0/20"
}

# ── Kubernetes ───────────────────────────────────────────────────────────────

variable "k8s_version" {
  description = "DOKS Kubernetes version slug"
  type        = string
  default     = "1.34.1-do.5"
}

variable "cluster_subnet" {
  description = "CIDR for Kubernetes pod network"
  type        = string
  default     = "10.156.0.0/16"
}

variable "service_subnet" {
  description = "CIDR for Kubernetes service network"
  type        = string
  default     = "10.157.0.0/16"
}

variable "mgmt_node_size" {
  description = "Droplet size for management node pool"
  type        = string
  default     = "c-4"
}

variable "mgmt_node_count" {
  description = "Number of management nodes"
  type        = number
  default     = 3
}

variable "gpu_node_size" {
  description = "Droplet size for GPU worker node pool"
  type        = string
  default     = "gpu-b300x8-2304gb-fabric-contracted"
}

variable "gpu_node_count" {
  description = "Number of GPU worker nodes"
  type        = number
  default     = 2
}

variable "gpu_vendor" {
  description = "GPU vendor (amd or nvidia) — determines taints and labels"
  type        = string
  default     = "nvidia"

  validation {
    condition     = contains(["nvidia", "amd"], var.gpu_vendor)
    error_message = "gpu_vendor must be \"nvidia\" or \"amd\"."
  }
}

# ── Database ─────────────────────────────────────────────────────────────────

variable "db_size" {
  description = "Database droplet size slug"
  type        = string
  default     = "db-s-1vcpu-2gb"
}

variable "db_node_count" {
  description = "Number of database nodes"
  type        = number
  default     = 1
}

variable "db_name" {
  description = "Name of the Slurm accounting database"
  type        = string
  default     = "slurm_acct"
}

variable "db_user" {
  description = "Database user for Slurm"
  type        = string
  default     = "slurm"
}

variable "db_mysql_auth_plugin" {
  description = "MySQL authentication plugin"
  type        = string
  default     = "caching_sha2_password"
}

# ── NFS ──────────────────────────────────────────────────────────────────────

variable "nfs_size_gib" {
  description = "NFS share size in GiB"
  type        = number
  default     = 1024
}

variable "nfs_performance_tier" {
  description = "NFS performance tier"
  type        = string
  default     = "high"
}

# ── Bring-Your-Own-Cluster ────────────────────────────────────────────────────

variable "existing_cluster_id" {
  description = "ID of an existing DOKS cluster. When set, skips cluster and VPC creation. Use with existing_vpc_id."
  type        = string
  default     = ""
}

variable "existing_vpc_id" {
  description = "ID of the existing VPC that contains the cluster. Required when existing_cluster_id is set."
  type        = string
  default     = ""
}
