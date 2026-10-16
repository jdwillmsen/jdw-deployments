{{- define "crew.name" -}}
{{ .Values.crew.name }}
{{- end -}}

{{- define "crew.serverHost" -}}
{{ .Release.Name }}-minecraft-bedrock.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}
