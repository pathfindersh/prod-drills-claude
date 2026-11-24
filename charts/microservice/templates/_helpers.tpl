{{- define "ms.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "ms.fullname" -}}
{{- if .Values.fullnameOverride -}}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else -}}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- end -}}
{{- define "ms.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ms.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "ms.labels" -}}
{{ include "ms.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
{{- define "ms.saName" -}}
{{- if .Values.serviceAccount.create -}}{{ default (include "ms.fullname" .) .Values.serviceAccount.name }}
{{- else -}}{{ default "default" .Values.serviceAccount.name }}{{- end -}}
{{- end -}}
{{- define "ms.probe" -}}
{{- $p := .probe -}}
{{- if eq $p.type "grpc" }}
grpc:
  port: {{ .port }}
{{- else if eq $p.type "tcpSocket" }}
tcpSocket:
  port: {{ .port }}
{{- else if eq $p.type "httpGet" }}
httpGet:
  path: {{ $p.path | default "/" }}
  port: {{ .port }}
  {{- with $p.httpHeaders }}
  httpHeaders: {{ toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- with $p.initialDelaySeconds }}
initialDelaySeconds: {{ . }}
{{- end }}
{{- with $p.periodSeconds }}
periodSeconds: {{ . }}
{{- end }}
{{- end -}}
{{- define "ms.podSpec" -}}
serviceAccountName: {{ include "ms.saName" . }}
automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken }}
securityContext: {{ toYaml .Values.podSecurityContext | nindent 2 }}
containers:
  - name: server
    image: "{{ .Values.image.repository }}@{{ .Values.image.digest }}"
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    securityContext: {{ toYaml .Values.securityContext | nindent 6 }}
    {{- with .Values.command }}
    command: {{ toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.args }}
    args: {{ toYaml . | nindent 6 }}
    {{- end }}
    {{- if .Values.service.enabled }}
    ports:
      - name: {{ .Values.service.portName }}
        containerPort: {{ .Values.containerPort }}
    {{- end }}
    {{- if or .Values.env .Values.secretRef }}
    envFrom:
      {{- if .Values.env }}
      - configMapRef: { name: {{ include "ms.fullname" . }} }
      {{- end }}
      {{- if .Values.secretRef }}
      - secretRef: { name: {{ .Values.secretRef }} }
      {{- end }}
    {{- end }}
    {{- if ne .Values.readinessProbe.type "none" }}
    readinessProbe: {{ include "ms.probe" (dict "probe" .Values.readinessProbe "port" .Values.containerPort) | nindent 6 }}
    {{- end }}
    {{- if ne .Values.livenessProbe.type "none" }}
    livenessProbe: {{ include "ms.probe" (dict "probe" .Values.livenessProbe "port" .Values.containerPort) | nindent 6 }}
    {{- end }}
    resources: {{ toYaml .Values.resources | nindent 6 }}
    volumeMounts:
      - { name: tmp, mountPath: /tmp }
      {{- if .Values.persistence.enabled }}
      - { name: data, mountPath: {{ .Values.persistence.mountPath }} }
      {{- end }}
volumes:
  - name: tmp
    emptyDir: {}
{{- with .Values.nodeSelector }}
nodeSelector: {{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations: {{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity: {{ toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
