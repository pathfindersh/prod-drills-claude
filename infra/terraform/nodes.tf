# Unmanaged node group (playground denies managed node groups): launch template + ASG.

resource "aws_security_group" "node" {
  name        = "NodeSecurityGroupIngress"
  description = "Security group for all nodes in the cluster"
  vpc_id      = data.aws_vpc.default.id
  tags = {
    Name                                        = "NodeSecurityGroupIngress"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

locals {
  cluster_sg = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  description                  = "Nodes talk to each other"
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  description       = "Nodes egress anywhere (image pulls, AWS APIs)"
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cp_kubelet" {
  description                  = "Control plane to kubelet and pods"
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = local.cluster_sg
  from_port                    = 1025
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cp_443" {
  description                  = "Control plane to extension API servers on pods"
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = local.cluster_sg
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_from_node_443" {
  description                  = "Nodes/pods to API server"
  security_group_id            = local.cluster_sg
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cp_to_node_kubelet" {
  description                  = "Control plane to kubelet and pods"
  security_group_id            = local.cluster_sg
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 1025
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cp_to_node_443" {
  description                  = "Control plane to extension API servers on pods"
  security_group_id            = local.cluster_sg
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_launch_template" "node" {
  name          = "NodeLaunchTemplate"
  image_id      = data.aws_ssm_parameter.node_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.node.name
  }

  vpc_security_group_ids = [aws_security_group.node.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      delete_on_termination = true
      volume_size           = 30
      volume_type           = "gp3"
    }
  }

  # IMDSv2 required; hop limit 2 so pods (e.g. the EBS CSI controller in Phase 2) can reach it.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                        = "${var.cluster_name}-worker"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    }
  }

  # AL2023 has no /etc/eks/bootstrap.sh; nodes join via nodeadm reading this NodeConfig.
  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${aws_eks_cluster.this.name}
        apiServerEndpoint: ${aws_eks_cluster.this.endpoint}
        certificateAuthority: ${aws_eks_cluster.this.certificate_authority[0].data}
        cidr: ${aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr}
    --BOUNDARY--
  EOT
  )
}

# No instance_refresh: a rolling refresh surges above max and would break the
# playground's 3-node cap. To roll nodes, scale in/out manually.
resource "aws_autoscaling_group" "nodes" {
  name                = "node-asg"
  vpc_zone_identifier = data.aws_subnets.public.ids
  min_size            = var.node_count
  max_size            = var.node_count
  desired_capacity    = var.node_count
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  depends_on = [
    aws_vpc_security_group_ingress_rule.node_from_cp_kubelet,
    aws_vpc_security_group_ingress_rule.cp_from_node_443,
  ]
}
