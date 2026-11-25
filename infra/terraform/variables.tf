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

variable "enable_prefix_delegation" {
  type        = bool
  description = <<-EOT
    VPC CNI prefix delegation: ~110 pods/node instead of 17 on t3.medium. When true, Terraform patches the
    CNI (terraform_data.cni_prefix) BEFORE the node ASG exists and nodes advertise maxPods=110. When false,
    the CNI is left in its default (non-prefix) mode and kubelet keeps its default max pods (17). One switch
    drives both so the CNI mode and maxPods can never disagree. false for the KodeKloud playground (see
    docs/phases/03-application.md: a fresh cluster with prefix delegation was deleted by the playground
    checker; cause unproven), true for a personal account. Changing it on a running cluster requires
    rolling the nodes.
  EOT
  default     = false
}
