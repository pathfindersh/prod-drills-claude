# KodeKloud AWS playground. Local state (bootstrap.sh keeps one file per account).
# No region here: bootstrap.sh passes -var region=... (AWS_REGION or aws configure).
# 1.37 = newest in STANDARD support per `describe-cluster-versions` (checked 2026-11-21;
# standard support ends 2027-12-01). Re-check before bumping.
kubernetes_version = "1.37"
instance_type      = "t3.medium"
node_count         = 3
# Prefix delegation OFF here: the playground deleted a fresh cluster that had it on (cause unproven;
# A/B test pending, see docs/phases/03-application.md). Pods/node stays 17.
enable_prefix_delegation = false
# Playground rule: gp2 only, max 30GB per node. 20 leaves room for pod volumes.
node_volume_type = "gp2"
node_volume_size = 20
