# Third-party sources

| Source | Used for | Why not build it ourselves | Changes we made |
|--------|----------|----------------------------|-----------------|
| [kodekloudhub/amazon-elastic-kubernetes-service-course](https://github.com/kodekloudhub/amazon-elastic-kubernetes-service-course) (`eks/`) | Basis of `infra/terraform/`: EKS + unmanaged node group + IAM names/policy that the KodeKloud playground's restricted IAM accepts | Playground only allows exact role/cluster names and denies managed node groups; this code is known to fit. No licence file upstream, so it is credited in comments and adapted, not vendored verbatim. | AL2023 + nodeadm instead of AL2; region is a variable; aws-auth and EBS CSI addon managed in Terraform; no generated SSH key; no CloudFormation signal; no instance refresh (3-node cap); IMDSv2 required; gp3 root volume |
| [kodekloudhub/certified-kubernetes-administrator-course](https://github.com/kodekloudhub/certified-kubernetes-administrator-course/tree/master/managed-clusters/eks) | Reference only: console walkthrough that explains the cluster role, node role and `aws-auth` join | n/a (read, not copied) | - |
| hashicorp/aws, hashicorp/kubernetes Terraform providers | Provider plugins | Official providers | - |
