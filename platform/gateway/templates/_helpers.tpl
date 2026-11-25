{{- /* Validated admin allow-list: IPv4 CIDRs, /16 or narrower (so never 0.0.0.0/0). */ -}}
{{- define "gw.adminCidrs" -}}
{{- $all := list -}}
{{- if .Values.admin.detectedCidr }}{{ $all = append $all .Values.admin.detectedCidr }}{{ end -}}
{{- range .Values.admin.extraCidrs }}{{ $all = append $all . }}{{ end -}}
{{- range $all -}}
{{- if not (regexMatch "^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])/(1[6-9]|2[0-9]|3[0-2])$" .) -}}
{{- fail (printf "admin CIDR %q refused: need an IPv4 CIDR with prefix /16 to /32" .) -}}
{{- end -}}
{{- end -}}
{{- $all | uniq | toJson -}}
{{- end -}}
