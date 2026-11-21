# Adapted from KodeKloud's playground-compatible EKS Terraform:
# https://github.com/kodekloudhub/amazon-elastic-kubernetes-service-course (eks/)
# Changes vs. upstream: AL2023 nodes (nodeadm), region as a variable, aws-auth and
# EBS CSI addon managed here, no generated SSH key, no CloudFormation leftovers.
# See docs/third-party.md and docs/phases/01-infrastructure.md.

terraform {
  required_version = ">= 1.10" # S3 native state locking (use_lockfile) needs 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }

  # No backend block here on purpose:
  #  - kodekloud: local state (bootstrap.sh keeps one file per AWS account)
  #  - personal:  bootstrap.sh copies envs/personal.backend.tf.example to backend.tf
}

provider "aws" {
  region = var.region
}

# Talks to the cluster this same apply creates, to write the aws-auth ConfigMap.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}
