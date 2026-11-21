data "aws_caller_identity" "current" {}

# Playground gives a default VPC; we use it instead of creating one (see docs).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [for s in var.az_suffixes : "${var.region}${s}"]
  }
}

# Latest AWS-recommended AL2023 EKS AMI for the pinned Kubernetes version.
data "aws_ssm_parameter" "node_ami" {
  name = "/aws/service/eks/optimized-ami/${var.kubernetes_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}
