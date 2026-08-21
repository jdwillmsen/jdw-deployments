{{- define "backup.name" -}}
{{ .Release.Name }}-backup
{{- end -}}

{{- define "backup.exporter.name" -}}
{{ .Release.Name }}-backup-exporter
{{- end -}}

{{- define "backup.serverPod" -}}
{{ .Release.Name }}-minecraft-bedrock-0
{{- end -}}

{{- define "backup.metricsConfigMap" -}}
{{ .Release.Name }}-backup-metrics
{{- end -}}

{{- define "backup.serverStatefulSet" -}}
{{ .Release.Name }}-minecraft-bedrock
{{- end -}}

{{- define "recovery.name" -}}
{{ .Release.Name }}-volume-recovery
{{- end -}}

{{- define "restore.name" -}}
{{ .Release.Name }}-restore
{{- end -}}

{{- define "restore.scratchPVC.name" -}}
{{ .Release.Name }}-restore-scratch
{{- end -}}

{{- define "bot.name" -}}
{{ .Release.Name }}-afk-bot
{{- end -}}

{{- define "bot.serverHost" -}}
{{ .Release.Name }}-minecraft-bedrock.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}
