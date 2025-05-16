# Create a VPC Peering connection between the EKS VPC and the external VPC
resource "aws_vpc_peering_connection" "eks_peer" {
  count       = var.enable_peering ? 1 : 0
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = var.peer_vpc_id
  auto_accept = true # auto-accept peering (works if the peer VPC is in same account; otherwise the peer owner must accept)
  tags = {
    "Name" = "${var.cluster_name}-peer"
  }
}

# Add routes in the EKS VPC's private route tables to reach the peer VPC via the peering connection
# (Note: The external VPC should also add a route back to the EKS VPC CIDR via the peering connection in its route table)
resource "aws_route" "eks_to_peer" {
  count                     = var.enable_peering ? length(module.vpc.private_route_table_ids) : 0
  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.eks_peer[0].id
}
