{{/* Multi-source Application: upstream chart + values file from THIS repo ($values ref). */}}
{{- define "app.chartApp" -}}
{{- $root := .root -}}
{{- $c := .c -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ .wave | quote }}
spec:
  project: default
  sources:
    - repoURL: {{ $c.repo }}
      chart: {{ $c.chart }}
      targetRevision: {{ $c.version | quote }}
      helm:
        releaseName: {{ .release | default .name }}
        valueFiles:
          - $values/platform/values/{{ .name }}.yaml
    - repoURL: {{ $root.Values.repoURL }}
      targetRevision: {{ $root.Values.revision }}
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .ns }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      {{- range .extraSync }}
      - {{ . }}
      {{- end }}
{{- end -}}
