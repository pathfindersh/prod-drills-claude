variable "region" {
  type        = string
  description = "AWS region. No default on purpose: bootstrap.sh passes it (AWS_REGION or `aws configure get region`)."
}

# KodeKloud playground only allows these exact names for cluster and IAM objects.
variable "cluster_name" {
  type    = string
  default = "demo-eks"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS control-plane version. Pin it in envs/*.tfvars (newest in STANDARD support)."
}

variable "cluster_role_name" {
  type    = string
  default = "eksClusterRole"
}

variable "node_role_name" {
  type    = string
  default = "eksWorkerNodeRole"
}

variable "additional_policy_name" {
  type    = string
  default = "eksPolicy"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_count" {
  type        = number
  description = "Desired = min = max. Playground caps at 3 nodes; instance refresh is off, so no surge."
  default     = 3

  validation {
    condition     = var.node_count >= 2 && var.node_count <= 3
    error_message = "Use 2 or 3 nodes (playground max is 3)."
  }
}

variable "az_suffixes" {
  type        = list(string)
  description = "AZ letters to use. Not every AZ supports EKS control planes, so default is a,b,c."
  default     = ["a", "b", "c"]
}

variable "use_custom_elb_ebs_policy" {
  type        = bool
  description = "Fallback: create the custom eksPolicy (policy.yaml). Off by default; the playground cannot delete it."
  default     = false
}
