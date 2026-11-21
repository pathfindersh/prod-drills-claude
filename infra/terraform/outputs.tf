output "cluster_name" { value = aws_eks_cluster.this.name }
output "region" { value = var.region }
output "account_id" { value = data.aws_caller_identity.current.account_id }
output "kubernetes_version" { value = aws_eks_cluster.this.version }
output "node_role_arn" { value = aws_iam_role.node.arn }
output "node_asg_name" { value = aws_autoscaling_group.nodes.name }
output "vpc_id" { value = data.aws_vpc.default.id }
