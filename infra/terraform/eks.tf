resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = data.aws_subnets.public.ids
  }

  # ConfigMap auth: nodes join through the aws-auth ConfigMap (see below).
  # New production clusters should use API / access entries instead (see docs).
  access_config {
    authentication_mode                         = "CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# Lets nodes join. KodeKloud's docs do this by hand with vi + kubectl apply;
# we do it here so a single apply yields a cluster whose nodes become Ready.
resource "kubernetes_config_map_v1" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([{
      rolearn  = aws_iam_role.node.arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    }])
  }
}

# EBS CSI driver (PersistentVolumes). Uses the node role's EBS permissions via IMDS.
# Needs Ready nodes to become ACTIVE, hence the dependency on the node group + aws-auth.
resource "aws_eks_addon" "ebs_csi" {
  count        = var.enable_ebs_csi_addon ? 1 : 0
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"
  depends_on   = [aws_autoscaling_group.nodes, kubernetes_config_map_v1.aws_auth]
}
