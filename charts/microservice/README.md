# microservice chart

One chart for every Online Boutique service (and redis-cart). Per-service differences
live in `apps/online-boutique/<svc>/values*.yaml`, never in the chart.

## Renders
Deployment (or StatefulSet when `persistence.enabled`), Service (+ headless Service for
StatefulSet), ConfigMap (from `env`), ServiceAccount (token not mounted), NetworkPolicy,
optional HPA and PDB. Secrets are only *referenced* (`secretRef`), never created here.

## Key values
| value | meaning |
|---|---|
| `image.repository` + `image.digest` | Image is ALWAYS `repo@sha256:...`. Schema rejects tags and malformed digests. |
| `env` | key/value map -> ConfigMap -> `envFrom` |
| `secretRef` | name of an existing Secret -> `envFrom` |
| `readinessProbe/livenessProbe.type` | `grpc` \| `httpGet` \| `tcpSocket` \| `none` |
| `networkPolicy.allowedFrom` | list of service names allowed to connect (default-deny otherwise) |
| `persistence.enabled` | switches to a StatefulSet with a gp3 PVC (see values.yaml for why) |
| `autoscaling.enabled`, `pdb.enabled` | optional HPA / PDB (not used in dev) |

NetworkPolicy objects are only *enforced* if the CNI has policy enforcement enabled
(VPC CNI needs `enableNetworkPolicy`); they are harmless otherwise.

## Validate
`KUBECONFORM=<path> scripts/validate-charts.sh [env...]`
