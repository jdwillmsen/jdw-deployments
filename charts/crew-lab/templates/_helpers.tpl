{{- define "crew.serverHost" -}}
{{ .Release.Name }}-minecraft-bedrock.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{/*
Labels every crew object carries, so all units can be selected together.
Takes the unit id.
*/}}
{{- define "crew.labels" -}}
app: {{ . }}
app.kubernetes.io/component: crew
{{- end -}}

{{- define "crew.control.dbSecret.name" -}}
crew-control-db
{{- end -}}
