locals {
  create_worker = lower(var.create_worker) == "yes"

  azs = slice(data.aws_availability_zones.this.names, 0, length(var.public_subnet_cidrs))

  central_name = "${var.prefix}-central"
  worker_name  = "${var.prefix}-worker"

  # Lets EKS / load balancer controllers discover the subnets for both clusters
  cluster_tags = {
    "kubernetes.io/cluster/${local.central_name}" = "shared"
    "kubernetes.io/cluster/${local.worker_name}"  = "shared"
  }
}

data "aws_availability_zones" "this" {
  state            = "available"
  exclude_zone_ids = var.excluded_zone_ids
}

# ===========================================================================
# VPC
# ===========================================================================
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # required by EKS
  enable_dns_hostnames = true # required by EKS

  tags = { Name = "${var.prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-igw" }
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.cluster_tags, {
    Name                     = "${var.prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1" # internet-facing load balancers go here
  })
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.cluster_tags, {
    Name                              = "${var.prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1" # internal load balancers go here
  })
}

# ---------------------------------------------------------------------------
# NAT gateway: ONE zonal NAT in the first public subnet (cheapest option)
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Route tables (the main route table is left untouched: local route only)
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-private-rt" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ===========================================================================
# EKS clusters
#   - control plane ENIs in BOTH private subnets (EKS needs 2 AZs)
#   - nodes ONLY in the first private subnet: same AZ as the NAT (no cross-AZ
#     data charges) and EBS volumes (vmstorage, Grafana) can always re-attach
# ===========================================================================
module "central" {
  source = "./modules/eks-cluster"

  name                = local.central_name
  kubernetes_version  = var.kubernetes_version
  vpc_cidr            = var.vpc_cidr
  cluster_subnet_ids  = aws_subnet.private[*].id
  node_subnet_ids     = [aws_subnet.private[0].id]
  public_access_cidrs = var.public_access_cidrs
  instance_types      = var.central_instance_types
  capacity_type       = var.capacity_type

  # The NAT route must exist before nodes boot, or they can't pull images
  depends_on = [aws_route.private_nat, aws_route_table_association.private]
}

module "worker" {
  source = "./modules/eks-cluster"
  count  = local.create_worker ? 1 : 0

  name                = local.worker_name
  kubernetes_version  = var.kubernetes_version
  vpc_cidr            = var.vpc_cidr
  cluster_subnet_ids  = aws_subnet.private[*].id
  node_subnet_ids     = [aws_subnet.private[0].id]
  public_access_cidrs = var.public_access_cidrs
  instance_types      = var.worker_instance_types
  capacity_type       = var.capacity_type

  depends_on = [aws_route.private_nat, aws_route_table_association.private]
}
