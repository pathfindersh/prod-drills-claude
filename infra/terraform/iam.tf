# Shared ELB/EBS permissions (see policy.yaml).
resource "aws_iam_policy" "elb_ebs" {
  name        = var.additional_policy_name
  path        = "/"
  description = "Create LoadBalancer Services and EBS volumes"
  policy      = jsonencode(yamldecode(file("${path.module}/policy.yaml")))
}

# --- Control plane role: assumed by the EKS service ---
data "aws_iam_policy_document" "assume_eks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = var.cluster_role_name
  assume_role_policy = data.aws_iam_policy_document.assume_eks.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = {
    cluster  = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    vpc_ctrl = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
    elb_ebs  = aws_iam_policy.elb_ebs.arn
  }
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# --- Node role: assumed by the EC2 instances ---
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = var.node_role_name
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = {
    worker  = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    cni     = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    ecr     = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    ssm     = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # shell via SSM instead of SSH keys
    elb_ebs = aws_iam_policy.elb_ebs.arn
  }
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  name = "NodeInstanceProfile"
  role = aws_iam_role.node.name
}
