# ---------------------------------------------------------------------------
# Asked on every apply/destroy (no default on purpose)
# ---------------------------------------------------------------------------
variable "create_worker" {
  description = "Create the WORKER cluster too? Type yes or no"
  type        = string

  validation {
    condition     = contains(["yes", "no"], lower(var.create_worker))
    error_message = "Answer yes or no."
  }
}

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------
variable "region" {
  description = "AWS region for everything"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Name prefix for all resources (clusters become <prefix>-central / <prefix>-worker)"
  type        = string
  default     = "vmlab"
}

variable "kubernetes_version" {
  description = "EKS version. Keep it in STANDARD support ($0.10/hr); extended support is $0.60/hr"
  type        = string
  default     = "1.36"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One per AZ, in AZ order. Small: only NAT GW and load balancers live here"
  type        = list(string)
  default     = ["10.50.0.0/24", "10.50.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One per AZ, in AZ order. Large: every pod gets an IP from here (VPC CNI)"
  type        = list(string)
  default     = ["10.50.32.0/19", "10.50.64.0/19"]
}

variable "excluded_zone_ids" {
  description = "AZ IDs to skip. use1-az3 does not support EKS control planes"
  type        = list(string)
  default     = ["use1-az3"]
}

variable "public_access_cidrs" {
  description = "Who may reach the EKS API endpoints from the internet. Tighten to [\"<your-ip>/32\"]"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------
variable "capacity_type" {
  description = "ON_DEMAND or SPOT. SPOT is cheaper but a single node can be taken away mid-session"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "Use ON_DEMAND or SPOT."
  }
}

variable "central_instance_types" {
  description = "Central runs VMCluster + Grafana + operator + alerting: needs ~8 GiB"
  type        = list(string)
  default     = ["t4g.large"]
}

variable "worker_instance_types" {
  description = "Worker runs vmagent + exporters + a sample app"
  type        = list(string)
  default     = ["t4g.medium"]
}
