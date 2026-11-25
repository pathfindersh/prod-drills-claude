MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUNDARY"

--BOUNDARY
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    apiServerEndpoint: ${endpoint}
    certificateAuthority: ${ca_data}
    cidr: ${service_cidr}
%{ if prefix_delegation ~}
  kubelet:
    config:
      # 110 only works with VPC CNI prefix delegation (terraform_data.cni_prefix below).
      maxPods: 110
%{ endif ~}
--BOUNDARY--
