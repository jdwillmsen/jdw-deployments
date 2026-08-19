{{- define "backup.name" -}}
{{ .Release.Name }}-backup
{{- end -}}

{{- define "backup.serverPod" -}}
{{ .Release.Name }}-minecraft-bedrock-0
{{- end -}}

{{- define "recovery.name" -}}
{{ .Release.Name }}-volume-recovery
{{- end -}}

{{- define "bot.name" -}}
{{ .Release.Name }}-afk-bot
{{- end -}}

{{- define "bot.serverHost" -}}
{{ .Release.Name }}-minecraft-bedrock.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}
