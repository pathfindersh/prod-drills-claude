# Upstream provenance

Copied ONCE from https://github.com/GoogleCloudPlatform/microservices-demo
(Online Boutique), Apache License 2.0 (see `LICENSE`; the upstream repo ships no
separate NOTICE file, and per-file license headers are kept untouched).

- Upstream commit: `c7cb6d5bfd6ea3aed768634ebbcb98cb7a523712`
- Release the images were mirrored from: `v0.10.7`
- Copied: the 11 service directories + `protos/`.
- Not copied: skaffold, kustomize, terraform, istio, helm-chart, docs,
  `shoppingassistantservice` (needs Gemini/AlloyDB; not part of the release).

This repo does not reference the upstream repo after this copy. Local changes
to `src/` are ours; do not "sync" blindly.
