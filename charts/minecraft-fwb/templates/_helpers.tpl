{{- define "backup.name" -}}
{{ .Release.Name }}-backup
{{- end -}}

{{- define "backup.serverPod" -}}
{{ .Release.Name }}-minecraft-bedrock-0
{{- end -}}

{{- define "recovery.name" -}}
{{ .Release.Name }}-volume-recovery
{{- end -}}
