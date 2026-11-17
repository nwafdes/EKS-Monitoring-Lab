output "vpc_id" {
  value = aws_vpc.this.id
}

output "availability_zones" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "nat_public_ip" {
  description = "Outbound internet traffic from the private subnets leaves from this IP"
  value       = aws_eip.nat.public_ip
}

output "central_cluster_name" {
  value = module.central.cluster_name
}

output "central_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.central.cluster_name} --alias central"
}

output "worker_cluster_name" {
  value = local.create_worker ? module.worker[0].cluster_name : null
}

output "worker_kubeconfig_command" {
  value = local.create_worker ? "aws eks update-kubeconfig --region ${var.region} --name ${module.worker[0].cluster_name} --alias worker" : null
}
