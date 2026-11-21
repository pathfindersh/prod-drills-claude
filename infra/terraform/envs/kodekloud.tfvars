# KodeKloud AWS playground. Local state (bootstrap.sh keeps one file per account).
# No region here: bootstrap.sh passes -var region=... (AWS_REGION or aws configure).
# 1.37 = newest in STANDARD support per `describe-cluster-versions` (checked 2026-11-21;
# standard support ends 2027-12-01). Re-check before bumping.
kubernetes_version = "1.37"
instance_type      = "t3.medium"
node_count         = 3
