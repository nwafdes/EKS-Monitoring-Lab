data "aws_partition" "current" {}

locals {
  policy_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

# ===========================================================================
# Control plane
# ===========================================================================
resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "${local.policy_prefix}/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # We install vpc-cni, kube-proxy and coredns ourselves as managed add-ons below
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids              = var.cluster_subnet_ids
    endpoint_private_access = true # nodes talk to the API inside the VPC
    endpoint_public_access  = true # you run kubectl from your VM
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true # whoever runs terraform becomes cluster admin
  }

  # Control plane logging is off on purpose (CloudWatch costs money)

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# Let the other cluster (anything in the VPC) reach this cluster's nodes and pods,
# e.g. worker vmagent -> central vminsert. Lab-wide rule, like an internal network.
resource "aws_vpc_security_group_ingress_rule" "from_vpc" {
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "All TCP from inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
}

# ===========================================================================
# Add-ons that must exist BEFORE nodes (networking + pod identity)
# ===========================================================================
resource "aws_eks_addon" "before_nodes" {
  for_each = toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# ===========================================================================
# Nodes: one managed node group, arm64 (Graviton), private subnet only
# ===========================================================================
resource "aws_iam_role" "node" {
  name = "${var.name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "${local.policy_prefix}/${each.key}"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.node_subnet_ids

  ami_type       = "AL2023_ARM_64_STANDARD"
  capacity_type  = var.capacity_type
  instance_types = var.instance_types
  disk_size      = var.node_disk_gb

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count + 1
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "lab/cluster" = var.name
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_nodes,
  ]
}

# ===========================================================================
# Add-ons that need running nodes
# ===========================================================================
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# EBS CSI driver: needed for PVCs (vmstorage, Grafana). Gets AWS permissions
# through EKS Pod Identity instead of node permissions.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "${local.policy_prefix}/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
