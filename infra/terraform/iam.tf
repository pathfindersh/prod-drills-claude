# FALLBACK ONLY (default off). The playground allows CreatePolicy but denies
# iam:DeletePolicy, so a custom policy cannot be destroyed there. We use AWS-managed
# policies instead (nothing to create, nothing to delete). Set
# use_custom_elb_ebs_policy = true only if the managed policies prove insufficient;
# bootstrap.sh down then handles the undeletable policy (envs/kodekloud.undeletable).
resource "aws_iam_policy" "elb_ebs" {
  count       = var.use_custom_elb_ebs_policy ? 1 : 0
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
  # AmazonEKSClusterPolicy already carries the ELB + security-group + volume permissions
  # the control plane's cloud controller needs for Service type=LoadBalancer.
  for_each = merge(
    {
      cluster  = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
      vpc_ctrl = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
    },
    var.use_custom_elb_ebs_policy ? { elb_ebs = aws_iam_policy.elb_ebs[0].arn } : {}
  )
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
  for_each = merge(
    {
      worker = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      cni    = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      ecr    = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      ssm    = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # shell via SSM instead of SSH keys
      # For the EBS CSI driver Phase 2 installs (Helm/Argo CD, uses the node role via IMDS).
      # Attached now so the first `up` proves the playground allows it.
      ebs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    },
    var.use_custom_elb_ebs_policy ? { elb_ebs = aws_iam_policy.elb_ebs[0].arn } : {}
  )
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  name = "NodeInstanceProfile"
  role = aws_iam_role.node.name
}
