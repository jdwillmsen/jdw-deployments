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

{{- define "bot2.name" -}}
{{ .Release.Name }}-afk-bot-2
{{- end -}}

{{- define "bot.serverHost" -}}
{{ .Release.Name }}-minecraft-bedrock.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{- define "versionCheck.name" -}}
{{ .Release.Name }}-version-check
{{- end -}}

{{- define "versionCheck.candidatePod" -}}
{{ .Release.Name }}-version-check-candidate
{{- end -}}

{{- define "mcMonitor.host" -}}
{{ .Release.Name }}-mc-monitor.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{- define "consoleBridge.name" -}}
{{ .Release.Name }}-console-bridge
{{- end -}}

{{- define "consoleBridge.host" -}}
{{ include "consoleBridge.name" . }}.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{- define "agent.name" -}}
{{ .Release.Name }}-server-agent
{{- end -}}

{{- define "deployAnnounce.name" -}}
{{ .Release.Name }}-deploy-announce
{{- end -}}

{{/*
A digest of the values that determine the server StatefulSet.

Used to tell a sync that will restart the server from one that only touches a
bot, a CronJob or the agent. It hashes the minecraft-bedrock subchart's values
rather than the rendered StatefulSet, because a parent chart cannot render its
own subchart to inspect the result.

That approximation is deliberate and has one known gap: bumping the vendored
subchart version changes the rendered pod template without changing these
values, so that one case would not warn. Every change made through this chart
does.
*/}}
{{- define "deployAnnounce.serverSpecHash" -}}
{{ index .Values "minecraft-bedrock" | toYaml | sha256sum | trunc 16 }}
{{- end -}}

{{- define "deployAnnounce.hashConfigMap" -}}
{{ .Release.Name }}-server-spec-hash
{{- end -}}
