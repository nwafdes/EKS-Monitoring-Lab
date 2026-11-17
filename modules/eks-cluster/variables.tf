variable "name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  type = string
}

variable "vpc_cidr" {
  description = "Traffic from anywhere in the VPC (e.g. the other cluster) is allowed into this cluster"
  type        = string
}

variable "cluster_subnet_ids" {
  description = "Subnets for the control plane ENIs (at least 2 AZs)"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnets for worker nodes"
  type        = list(string)
}

variable "public_access_cidrs" {
  type = list(string)
}

variable "instance_types" {
  type = list(string)
}

variable "capacity_type" {
  type = string
}

variable "node_count" {
  type    = number
  default = 1
}

variable "node_disk_gb" {
  type    = number
  default = 20
}
