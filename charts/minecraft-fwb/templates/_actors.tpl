{{/*
The bot values blocks an afk-bot actor may name. Each has its own Deployment
template, so a third bot adds its key here in the same change that copies
bot2-deployment.yaml.
*/}}
{{- define "actors.botKeys" -}}
{{- list "bot" "bot2" | toJson -}}
{{- end -}}

{{/*
Fails the render on any actor list the agent, the bots or the bridge would
read differently. Rendered from its own template so a bad list stops every
sync, not only the ones that happen to touch the agent.

The gamertag rules are the agent's and the bridge's, so a list that renders
is one both start on: a quote or backslash could end a quoted kick target
early, a leading @ is a selector rather than a player, a control or format
character hides inside a name invisibly, and non-ASCII whitespace passes for
a plain space without being one. The plain space is stripped before that last
check because gamertags can contain it. Padding is refused because the agent
refuses it; the bridge would trim it instead, and the two would then disagree
on the name.
*/}}
{{- define "actors.validate" -}}
{{- $botKeys := include "actors.botKeys" . | fromJsonArray -}}
{{- $ids := dict -}}
{{- $gamertags := dict -}}
{{- $usedKeys := dict -}}
{{- $agents := 0 -}}
{{- range $i, $a := .Values.global.actors -}}
{{- $where := printf "global.actors[%d]" $i -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{0,62}$" (toString $a.id)) -}}
{{- fail (printf "%s.id %q must match ^[a-z0-9][a-z0-9-]{0,62}$" $where (toString $a.id)) -}}
{{- end -}}
{{- if eq $a.id "all" -}}
{{- fail (printf "%s.id \"all\" names every actor and cannot be one" $where) -}}
{{- end -}}
{{- if hasKey $ids $a.id -}}
{{- fail (printf "%s.id %q is listed twice" $where $a.id) -}}
{{- end -}}
{{- $_ := set $ids $a.id true -}}
{{- $tag := toString $a.gamertag -}}
{{- if or (not $a.gamertag) (regexMatch "[,\"\\\\]|^@" $tag) (ne $tag (trim $tag)) (regexMatch `[\p{Cc}\p{Cf}\p{Z}]` (replace " " "" $tag)) -}}
{{- fail (printf "%s.gamertag must be set, with no comma, quote, backslash, leading @, control or invisible character, non-ASCII space or padding: BRIDGE_KICKABLE is bare comma-separated names, and the agent refuses to start on the rest" $where) -}}
{{- end -}}
{{- if hasKey $gamertags (lower $a.gamertag) -}}
{{- fail (printf "%s.gamertag %q belongs to another actor" $where $a.gamertag) -}}
{{- end -}}
{{- $_ := set $gamertags (lower $a.gamertag) true -}}
{{- if not (has $a.defaultState (list "present" "parked")) -}}
{{- fail (printf "%s.defaultState must be present or parked, got %q" $where (toString $a.defaultState)) -}}
{{- end -}}
{{- if eq $a.kind "agent" -}}
{{- $agents = add1 $agents -}}
{{- if $a.valuesKey -}}
{{- fail (printf "%s is the agent and takes no valuesKey" $where) -}}
{{- end -}}
{{- else if eq $a.kind "afk-bot" -}}
{{- if not (has $a.valuesKey $botKeys) -}}
{{- fail (printf "%s.valuesKey must be one of %s, got %q" $where (join ", " $botKeys) (toString $a.valuesKey)) -}}
{{- end -}}
{{- if hasKey $usedKeys $a.valuesKey -}}
{{- fail (printf "%s.valuesKey %q is already another actor's" $where $a.valuesKey) -}}
{{- end -}}
{{- $_ := set $usedKeys $a.valuesKey true -}}
{{- else -}}
{{- fail (printf "%s.kind must be agent or afk-bot, got %q" $where (toString $a.kind)) -}}
{{- end -}}
{{- end -}}
{{- /* A second pass, so a group naming an actor listed after it is caught too. */ -}}
{{- range $i, $a := .Values.global.actors -}}
{{- $where := printf "global.actors[%d]" $i -}}
{{- range $a.groups -}}
{{- if eq . "all" -}}
{{- fail (printf "%s.groups lists \"all\", which every actor is already in" $where) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{0,62}$" (toString .)) -}}
{{- fail (printf "%s.groups entry %q must match ^[a-z0-9][a-z0-9-]{0,62}$" $where (toString .)) -}}
{{- end -}}
{{- if hasKey $ids . -}}
{{- fail (printf "%s.groups entry %q is also an actor id, so a target naming it is ambiguous" $where .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /* The operator token sits in PRESENCE_TOKENS beside the bots' tokens,
which are named after their actors, and keys the Secret the same way: a
shared name would hand one of them the other's token. */ -}}
{{- $operator := toString .Values.global.presence.operatorToken.name -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{0,62}$" $operator) -}}
{{- fail (printf "global.presence.operatorToken.name %q must match ^[a-z0-9][a-z0-9-]{0,62}$" $operator) -}}
{{- end -}}
{{- if hasKey $ids $operator -}}
{{- fail (printf "global.presence.operatorToken.name %q is also an actor id, so it would collide with that actor's token" $operator) -}}
{{- end -}}
{{- if ne $agents 1 -}}
{{- fail (printf "global.actors must list exactly one actor of kind agent, found %d" $agents) -}}
{{- end -}}
{{- range $botKeys -}}
{{- if and (index $.Values . "enabled") (not (hasKey $usedKeys .)) -}}
{{- fail (printf "%s.enabled is true but no global.actors entry has valuesKey %q: an unregistered bot is one the agent can neither park nor count" . .) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
PRESENCE_ACTORS for the agent, in the contract's snake_case field names. The
values list is camelCase like the rest of this file; valuesKey is chart
plumbing and stays out.
*/}}
{{- define "actors.json" -}}
{{- $out := list -}}
{{- range .Values.global.actors -}}
{{- $out = append $out (dict "id" .id "gamertag" .gamertag "kind" .kind "groups" (default list .groups) "default_state" .defaultState) -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/*
BRIDGE_KICKABLE. Every actor, the agent included: a parked agent whose
session the server holds open is kicked like any bot.
*/}}
{{- define "actors.kickable" -}}
{{- $tags := list -}}
{{- range .Values.global.actors -}}
{{- $tags = append $tags .gamertag -}}
{{- end -}}
{{- join "," $tags -}}
{{- end -}}

{{/*
The agent's own actor entry, as JSON. Validates first: templates render in
name order, so a consumer can reach a bad list before actors-validate.yaml
does, and would otherwise fail with a nil error instead of the real one.
*/}}
{{- define "actors.agent" -}}
{{- include "actors.validate" . -}}
{{- range .Values.global.actors -}}
{{- if eq .kind "agent" -}}{{- toJson . -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The actor entry for a bot values block, as JSON; call with
(dict "root" $ "key" "bot"). Validates first, for the reason above.
*/}}
{{- define "actors.forValuesKey" -}}
{{- include "actors.validate" .root -}}
{{- $key := .key -}}
{{- range .root.Values.global.actors -}}
{{- if eq (toString .valuesKey) $key -}}{{- toJson . -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/* The presence Secret key holding one token; call with an actor id or token name. */}}
{{- define "presence.tokenKey" -}}
presence_token_{{ . | replace "-" "_" }}
{{- end -}}

{{- define "presence.secret.name" -}}
{{ .Release.Name }}-presence
{{- end -}}
