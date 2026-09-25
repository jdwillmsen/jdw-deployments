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

{{- define "netherNet.name" -}}
{{ .Release.Name }}-nethernet
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

global.* is merged into the subchart's values, so global.actors and
global.presence would move this digest on every edit, though the StatefulSet
reads only the kick list derived from them: a bot's default flipped there
would count down a server restart that never comes. They are swapped for what
the bridge sidecar renders from them, and with presence off the digest is the
one it was before either existed.
*/}}
{{- define "deployAnnounce.serverSpecHash" -}}
{{- /* A copy, because set writes into the map it is given, and the original is the live subchart values every later template reads. */ -}}
{{- $values := deepCopy (index .Values "minecraft-bedrock") -}}
{{- $global := omit $values.global "actors" "presence" -}}
{{- if .Values.global.presence.enabled -}}
{{- $_ := set $global "bridgeKickable" (include "actors.kickable" .) -}}
{{- end -}}
{{- $_ := set $values "global" $global -}}
{{ $values | toYaml | sha256sum | trunc 16 }}
{{- end -}}

{{/*
A digest of the values that determine the chat agent's Deployment -- empty
whenever this sync leaves no agent in chat: the two flags that Deployment
renders under, and a replica count above zero, since the Deployment renders
at zero replicas but no bot is there to announce anything about.

Kept apart from the server's digest rather than folded into it, because the two
earn different announcements: a server restart disconnects everyone and is worth
holding the sync for, while an agent restart only takes the bot out of chat for
the length of a fresh login.

Empty rather than a real digest when no agent will be there, because turning the
agent off, or parking it at zero replicas to free its Microsoft account, moves
its values too. Both the recorded digest and the hook's comparison use this, so
an empty value on either side means "no agent was in chat", and neither losing
the bot nor getting it back is announced as an update -- telling players it
"will come straight back" about a sync that takes it away for good is the kind
of wrong warning this hook exists to stop sending.

Same approximation as the server's, for the same reason, with the same gap: a
change to the agent's template rather than to these values -- a probe, a
rollout strategy -- moves the pod without moving this digest, and that sync
stays quiet.

The actor list reaches the agent as PRESENCE_ACTORS, so it is part of what
restarts the agent once presence is on -- and nothing while it is off, which
keeps this digest unchanged until then.
*/}}
{{- define "deployAnnounce.agentSpecHash" -}}
{{- if and .Values.agent.enabled .Values.global.consoleBridge.enabled
          (gt (int .Values.agent.replicas) 0) -}}
{{- $values := .Values.agent -}}
{{- if .Values.global.presence.enabled -}}
{{- $values = dict "agent" .Values.agent "actors" (include "actors.json" .) -}}
{{- end -}}
{{ $values | toYaml | sha256sum | trunc 16 }}
{{- end -}}
{{- end -}}

{{- define "deployAnnounce.hashConfigMap" -}}
{{ .Release.Name }}-server-spec-hash
{{- end -}}

{{- define "agent.dbSecret.name" -}}
{{ .Release.Name }}-server-agent-db
{{- end -}}

{{- define "census.name" -}}
{{ .Release.Name }}-census
{{- end -}}

{{- define "joinProbe.name" -}}
{{ .Release.Name }}-join-probe
{{- end -}}

{{- define "census.metricsConfigMap" -}}
{{ .Release.Name }}-census-metrics
{{- end -}}

{{- define "census.exporter.name" -}}
{{ .Release.Name }}-census-exporter
{{- end -}}

{{- define "scheduledRestart.name" -}}
{{ .Release.Name }}-scheduled-restart
{{- end -}}

{{- define "tickRateAlert.name" -}}
{{ .Release.Name }}-tick-rate
{{- end -}}
