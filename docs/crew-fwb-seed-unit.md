# crew-23: Dotablaze7321 on fwb-seed

`crew-23` is a crew worker that joins the `fwb-seed` server (NetherNet, online
mode, `http://192.168.1.163:31301`) as the Xbox account FWB's `afk-bot-2` plays
on, Dotablaze7321. afk-bot-2 stays on FWB, untouched. The unit searches for
oak near its base, fells it and deposits the logs in a chest. It is a `crew-lab` chart
unit with a `server` override (`charts/crew-lab/README.md`, "Units on another
server"); the lab's unit-kit pack, rebuild job, gate and yards ignore it, and it has
its own gear chest through `survival`, so the lab server is not restarted.

It runs at `replicas: 1`; set `replicas: 0` (not `kubectl scale`, Argo reverts it) to stop it.

## Can one account be on two servers? (read from the code, not run)

**Two sessions: probably yes.** crew dials NetherNet through the server's own
signaling URL (`endpoint.NewClient`, no Xbox signalling service), and each
Bedrock server only turns away a second login from the same account on that
server (`afkbot/internal/mcdial`). Nothing found links FWB to fwb-seed. Unproven
until the test below.

**One shared refresh token: likely to break afk-bot-2.** Each program loads the
token file once at start, keeps it in memory, refreshes when its access token has
expired at the next connect, and writes the result to its own file. Neither
re-reads the file or knows the other exists. The shared `mcauth` package says
Microsoft retires a refresh token the moment it issues the replacement, and gates
its own standby for exactly that. I could not check that against Microsoft. If it
holds:

- the copy is a second holder of one login. Whichever of afk-bot-2 and crew-23
  refreshes first retires the other's token;
- crew-23 refreshes on its first connect after the copy's access token expires,
  so it is the likelier winner. afk-bot-2 keeps its current session (the token is
  only used at connect) but its next reconnect (FWB or pod restart, a kick) fails
  with a refused refresh, and afkbot then retries forever without printing a
  device code, because only a missing file asks for one;
- each human re-login then retires the other's copy again, so the two will not
  coexist longer than one access-token lifetime;
- repeated refused refreshes can put the account in Microsoft's abuse hold, which
  locks out both.

If Microsoft keeps old refresh tokens valid, they refresh independently and this
all works. The test finds out which.

**Safer alternative:** give crew-23 its own Xbox account. The owner runs the
device-code login in their own terminal (`charts/crew-lab/README.md`, "Warriors
on NetherNet"), never through an agent, and sets `name` to that account. No Job,
no shared token, nothing to break on FWB.

## Sign-in copy

crew-23 runs with `MC_USERNAME=fwb-afk-bot-2`, the name afk-bot-2 uses, so both
programs name the file `token-fwb-afk-bot-2-db037fe8.json` (slug plus the first
four bytes of the name's sha256). Both store it as `oauth2.Token` JSON; crew also
refuses one with no refresh token or no expiry. `crew-23-auth-import-job.yaml`
checks both without printing, then copies it from afk-bot-2's volume (mounted
read-only) to `crew-shared:/data/crew-23/auth`, and refuses to overwrite.

## Test (owner)

Nothing below is done by the PR. Run the copy when you are ready to look:

1. `kubectl apply -f docs/crew-23-auth-import-job.yaml`, then
   `kubectl -n jdwillmsen-prd logs job/crew-23-auth-import` ends in `copied`.
   afk-bot-2 is not touched.
2. Put the axe in place (below) on fwb-seed once the unit is on, or skip it for
   the first run: the test does not need work.
3. Start it: a PR setting `replicas: 1` on crew-23 in
   `charts/crew-lab/values.yaml`. Argo CD self-heals, so `kubectl scale` alone is
   put back within minutes. Merging restarts crew-control once (its roster gains
   the unit); the lab server is not touched.
4. Watch for 15 minutes:
   - crew-23 on fwb-seed: `kubectl -n jdwillmsen-prd logs deploy/crew-23` shows
     `spawned` and no `auth_failed`; `MC_SELECTOR=app=jdwillmsen-fwb-seed-prd-minecraft-bedrock tools/mc players`
     lists Dotablaze7321.
   - afk-bot-2 on FWB: `kubectl -n jdwillmsen-prd logs deploy/jdwillmsen-minecraft-fwb-prd-afk-bot-2 --since=20m`
     shows no `session_ended` or `session_error`, and `tools/mc players` still
     lists it.
   A disconnect on either side means duplicate sessions break: stop (below).
5. The token risk shows later, not in step 4. After a day, check afk-bot-2's log
   for refused refreshes at its next reconnect. This is the part that can cost
   afk-bot-2 its login.

## Axe, bread, and a place to stand

fwb-seed has no unit-kit pack and no keepInventory, so by hand, after the unit
has joined (`send-command` returns 0 whether or not it worked; check the unit's
inventory in crew-control):

    kubectl -n jdwillmsen-prd exec jdwillmsen-fwb-seed-prd-minecraft-bedrock-0 -- send-command 'give "Dotablaze7321" iron_axe 1'
    kubectl -n jdwillmsen-prd exec jdwillmsen-fwb-seed-prd-minecraft-bedrock-0 -- send-command 'give "Dotablaze7321" bread 16'
    kubectl -n jdwillmsen-prd exec jdwillmsen-fwb-seed-prd-minecraft-bedrock-0 -- send-command 'give "Dotablaze7321" dirt 32'

The dirt is the pillar it climbs for tall trunks. The unit joins at the world
spawn (0, 0), about 300 blocks from its base, and a walk only paths over chunks
already sent, so move it once to the base by hand:

    kubectl -n jdwillmsen-prd exec jdwillmsen-fwb-seed-prd-minecraft-bedrock-0 -- send-command 'effect "Dotablaze7321" slow_falling 60 0 true'
    kubectl -n jdwillmsen-prd exec jdwillmsen-fwb-seed-prd-minecraft-bedrock-0 -- send-command 'tp "Dotablaze7321" 114 90 331'

It then taps the bed (the plan's first task), which sets its respawn point at
the base, so a death returns it there, where its gear chest is in reach. No
`spawnpoint` command is needed. Stock the gear chest at 114 69 331 (sword,
axe, pickaxe, armour, food).

## Before it does real work

- **This twin world has its own terrain.** The FWB base and village
  coordinates mean nothing here. The base is a strip of grass beside the oak
  forest at X89-143, Z310-405: bed at 115 69 329-330, delivery chest 112 69 330,
  gear chest 114 69 331. Keep every coordinate inside x, z -500..499.
- `search` only steers where the unit looks for trees; it does not limit what
  it breaks, so keep the search box away from anything built of oak.
- Not verified on a live server: that a daytime tap on the bed sets the
  respawn point, and the death recovery and gear pickup (new in crew 1.87.0 and
  opt-in through `survival`). Night shelter exists as a task but nothing starts
  it yet.
- crew-23 shows in the crew console like any unit. Do not select it for lab Jobs:
  those use lab coordinates. crew-control only reads units and queues tasks; it
  neither kits nor restarts them.

## Rollback

Stop the unit: set `replicas: 0` on crew-23 in `charts/crew-lab/values.yaml` (or
revert the PR that turned it on). afk-bot-2 needs no action unless its login broke.

Remove the copy: `kubectl apply -f docs/crew-23-auth-remove-job.yaml`.

## If afk-bot-2 loses its login

Symptom: after a FWB or pod restart, `session_error` repeats in its log and it
never rejoins. Stop crew-23 first. Then clear afk-bot-2's token with the second
variant described at the top of `crew-23-auth-remove-job.yaml`, start afk-bot-2,
and in your own terminal run `kubectl -n jdwillmsen-prd logs -f
deploy/jdwillmsen-minecraft-fwb-prd-afk-bot-2` and complete the device code as
Dotablaze7321. Do not run that through an agent.
