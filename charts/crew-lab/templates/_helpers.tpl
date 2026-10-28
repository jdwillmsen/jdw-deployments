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

{{/*
Where a unit's work yard is. Takes a dict with `id` (crew-NN) and `yards`
(crew.yards). Yards are a grid of square plots filled in unit order, west to
east and then north to south, so a unit's plot follows from its number alone
and ids are never reused. Rendered as JSON because a define returns text.
*/}}
{{- define "crew.plot" -}}
{{- $i := sub (atoi (trimPrefix "crew-" .id)) 1 -}}
{{- $y := .yards -}}
{{- dict "x" (add (int64 $y.originX) (mul (mod $i (int64 $y.columns)) (int64 $y.pitch))) "z" (add (int64 $y.originZ) (mul (div $i (int64 $y.columns)) (int64 $y.pitch))) | toJson -}}
{{- end -}}

{{/*
A unit's standing work (WORK_PLAN), by role. Takes a dict with `unit` and
`yards`. Offsets are relative to the plot's north-west corner and must match
the structures the unit-kit restock function builds (unit-kit-configmap.yaml):

  chests      (3, 64, 4) and (3, 64, 8)
  quarry      x 10..17, y 64..66, z 3..8
  grove       trunks at x 10 13 16 19 22, z 14 17 20 23, two logs high
  shaft sites entrances (4, 64, 27) and (20, 64, 27), both facing east
*/}}
{{- define "crew.workPlan" -}}
{{- $p := include "crew.plot" (dict "id" .unit.id "yards" .yards) | fromJson -}}
{{- $x := int64 $p.x -}}
{{- $z := int64 $p.z -}}
{{- $c1 := dict "x" (add $x 3) "y" 64 "z" (add $z 4) -}}
{{- $c2 := dict "x" (add $x 3) "y" 64 "z" (add $z 8) -}}
{{- $plan := list -}}
{{- if eq .unit.role "miner" -}}
{{- $area := dict "min" (dict "x" (add $x 8) "y" 64 "z" (add $z 1)) "max" (dict "x" (add $x 19) "y" 67 "z" (add $z 10)) -}}
{{- $plan = list (dict "template" "gather_and_deposit" "item" "cobblestone" "qty" 16 "area" $area "chest" $c1) -}}
{{- else if eq .unit.role "chopper" -}}
{{- $area := dict "min" (dict "x" (add $x 8) "y" 64 "z" (add $z 12)) "max" (dict "x" (add $x 24) "y" 67 "z" (add $z 25)) -}}
{{- $plan = list (dict "template" "gather_and_deposit" "item" "oak_log" "qty" 8 "area" $area "chest" $c1) -}}
{{- else if eq .unit.role "hauler" -}}
{{- $plan = list (dict "template" "haul" "items" (dict "cobblestone" 64) "from" (list $c1) "to" $c2) (dict "template" "haul" "items" (dict "cobblestone" 64) "from" (list $c2) "to" $c1) -}}
{{- else if eq .unit.role "shaft" -}}
{{- $area := dict "min" (dict "x" (add $x 2) "y" 40 "z" (add $z 22)) "max" (dict "x" (add $x 31) "y" 65 "z" (add $z 31)) -}}
{{- range $dx := list 4 20 -}}
{{- $plan = append $plan (dict "template" "mine_shaft" "entrance" (dict "x" (add $x $dx) "y" 64 "z" (add $z 27)) "facing" "east" "depth" 8 "branches" 3 "branch_length" 3 "area" $area "to" $c1) -}}
{{- end -}}
{{- else -}}
{{- fail (printf "unit %s: unknown role %q (miner, chopper, hauler, shaft, warrior, mender, builder)" .unit.id .unit.role) -}}
{{- end -}}
{{- $plan | toJson -}}
{{- end -}}

{{/*
Whether a unit is a mender or builder: a lab-only unit that works in creative
mode on a task and never in a yard. Takes the unit and renders "true" or
nothing, so it reads as a condition through `include`. It also refuses a role
that no template knows, and a squad on a lab role, because crew never lets such
a unit join one.
*/}}
{{- define "crew.labRole" -}}
{{- if and .role (not (has .role (list "miner" "chopper" "hauler" "shaft" "warrior" "mender" "builder"))) -}}
{{- fail (printf "unit %s: unknown role %q (miner, chopper, hauler, shaft, warrior, mender, builder)" .id .role) -}}
{{- end -}}
{{- if has .role (list "mender" "builder") -}}
{{- if .squad -}}
{{- fail (printf "unit %s: a %s never joins a squad, remove squad" .id .role) -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/*
Where a mender is put when it joins, as "x y z". The unit's own `home` wins
over crew.menderHome. A mender with neither fails the render.
*/}}
{{- define "crew.menderHome" -}}
{{- $h := .unit.home | default .default -}}
{{- if not (and $h (hasKey $h "x") (hasKey $h "y") (hasKey $h "z")) -}}
{{- fail (printf "unit %s: a mender needs a home with x, y and z (crew.menderHome or the unit's own home)" .unit.id) -}}
{{- end -}}
{{- printf "%d %d %d" (int64 $h.x) (int64 $h.y) (int64 $h.z) -}}
{{- end -}}

{{- define "versionCheck.name" -}}
{{ .Release.Name }}-version-check
{{- end -}}

{{- define "versionCheck.candidatePod" -}}
{{ .Release.Name }}-version-check-candidate
{{- end -}}
