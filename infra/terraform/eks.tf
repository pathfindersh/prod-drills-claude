resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # EKS defaults new clusters to EXTENDED support, which bills extra once standard
  # support ends. STANDARD makes AWS auto-upgrade instead.
  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids = data.aws_subnets.public.ids
  }

  # Nodes join through the aws-auth ConfigMap (see below). API_AND_CONFIG_MAP honours
  # both aws-auth and access entries. We asked for CONFIG_MAP first, but EKS reported
  # API_AND_CONFIG_MAP on this 1.37 cluster; the mode can only move forward
  # (CONFIG_MAP -> API_AND_CONFIG_MAP -> API), never back, so the code follows reality.
  # New production clusters should use API (access entries only); see docs.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
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

# No storage driver here on purpose. The EKS addon could be created but not deleted in
# the playground (eks:DeleteAddon denied), which broke `down`. Phase 2 installs the EBS
# CSI driver with Helm via Argo CD (wave 0); Helm uninstall needs no AWS IAM.
