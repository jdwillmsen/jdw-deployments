# Minecraft FWB — agent re-authentication runbook

For `JdwillmsenMinecraftAgentDisconnected` when the agent pod is running but
not ready and its log says Microsoft will not take its token any more: *the
agent's Xbox Live login is dead and a person has to sign in again.*

**Scope.** This describes the agent as of **`agent-v0.28.0`**, and every claim
below was checked against the source at that tag. A later agent release may
make steps 2 and 3 unnecessary (a dead token would then start the sign-in
itself instead of being retried forever). Check the release you are running
before parking anything, and treat this runbook as stale where it disagrees
with the agent's own README.

**Keep the device code out of any AI agent's session by default.** Step 5
prints a Microsoft sign-in code. A code that lands in a transcript can be used
by whoever reads the transcript, and a printed credential cannot be un-printed.
Nothing up to step 4 or from step 6 prints a secret, so those steps can be run
through an agent without a credential reaching its transcript; step 5 is for a
person in their own terminal. That is a statement about exposure only. Steps
2, 3 and 7 change production (the token store, the running pod), and an agent
runs each of them only on the operator's go-ahead. This is the same rule as
the box-wide one for credential-minting commands, and it applies to Claude
Code's `! <command>` too, which appends its output to the session. The one
exception is an operator who explicitly accepts the exposure for that code
(it is single-use and expires in about 15 minutes, but it is still readable by
anyone who can read the transcript); an agent never makes that call itself.

**The fix is not always a fresh sign-in.** On 2026-10-08 the dead stored token
was not the real problem: Microsoft refused to issue a token for the account at
all until two-step verification was turned on. If a correct-looking sign-in is
followed by the same `invalid_grant`, go to
[Sign-in succeeds but is rejected](#sign-in-succeeds-but-is-rejected).

## What is broken

The server, the AFK bots and the join probe are all healthy. Only the agent —
the one real Microsoft account that gives the cluster a presence in the world —
cannot log in.

| Where | What you see |
|---|---|
| pod `jdwillmsen-minecraft-fwb-prd-server-agent-*`, namespace `jdwillmsen-prd` | `0/1 Running`; `/readyz` answers 503 |
| ArgoCD app `jdwillmsen-minecraft-fwb-prd` | stuck `Progressing` — the Deployment never becomes available |
| alert | `JdwillmsenMinecraftAgentDisconnected` firing |
| agent log | `"event":"auth_rejected"` repeating, error text `oauth2: "invalid_grant" ... The user must sign in again` |
| join probe, AFK bots, Bedrock server | unaffected |

The agent keeps its Xbox Live refresh token in Postgres, not on a volume: the
table `minecraft.auth_tokens` (`account`, `token`, `updated_at`) in database
`jdwillmsen_prd`, on the CNPG cluster `platform-postgresql-cluster-prd`
(namespace `database`). The row is keyed by the agent's `MC_USERNAME`,
`fwb-server-agent`. The chart mounts nothing at `/data/auth`
(`charts/minecraft-fwb/templates/agent-deployment.yaml`), so there is no file
copy to find or clear.

Microsoft is refusing that refresh token. The agent knows only that the
refresh was rejected, and what it does about that is the whole reason this
runbook exists:

* It starts a device-code sign-in **only when the store has no row** for its
  account. A row that exists but no longer works is never replaced — the agent
  retries the dead token indefinitely.
* Each retry waits `AUTH_RETRY_DELAY_MS`, 900000 (15 minutes), jittered to
  50–100% of that — hence an attempt every 7.5–15 minutes. The floor is
  deliberately long: retrying a rejected account faster can extend a hold
  Microsoft has on it.

So recovery is: take the dead row out of the way so the store reports "nothing
here", and let the agent ask a human to sign in.

## 1. Confirm the diagnosis

```bash
kubectl get pods -n jdwillmsen-prd -l app=jdwillmsen-minecraft-fwb-prd-server-agent
kubectl logs -n jdwillmsen-prd deploy/jdwillmsen-minecraft-fwb-prd-server-agent -c agent --tail=500 \
  | jq -R -r 'fromjson? | select(.event != null) | "\(.timestamp) \(.event)"'
```

The `jq` filter prints the timestamp and event name of JSON lines and **drops
everything else**, which is what makes this safe to run anywhere: the one
non-JSON line the agent ever writes is the sign-in code (step 4), and this
command cannot show it. Do not substitute a plain `kubectl logs`, or `--tail`
without the filter, in an agent's session.

You are looking for `auth_rejected` repeating and no `joined` or `spawned`
after it. To read the error itself:

```bash
kubectl logs -n jdwillmsen-prd deploy/jdwillmsen-minecraft-fwb-prd-server-agent -c agent --tail=500 \
  | jq -R -r 'fromjson? | select(.event == "auth_rejected") | "\(.timestamp) \(.error) next_try_ms=\(.delay_ms)"' \
  | tail -3
```

Also confirm the agent is reading the database and has no file cache behind it:

```bash
kubectl logs -n jdwillmsen-prd deploy/jdwillmsen-minecraft-fwb-prd-server-agent -c agent \
  | jq -R -r 'fromjson? | select(.event == "auth_store")'
```

`"store":"postgres"` with a `file_cache_error` and no `fallback_path` is what
this deployment should show. If a `fallback_path` appears, a file cache exists
and step 2 alone would not be enough — the load would fall through to it.

**`invalid_grant` is not proof the stored token was merely revoked.** The agent
treats that one OAuth code as "Xbox Live refused the account", and it covers
at least three different situations whose log lines look alike:

| Error description | Means | Go to |
|---|---|---|
| `The user could not be authenticated or user interaction is required. The user must sign in again and if needed grant the client application access to the requested scope.` | Microsoft wants a fresh sign-in; on 2026-10-08 it kept wanting one even after a correct sign-in | step 5, then [Sign-in succeeds but is rejected](#sign-in-succeeds-but-is-rejected) |
| `User account is found to be in service abuse mode.` | an account-side hold | [Abuse hold](#abuse-hold-and-account-locks) |
| any other | not seen yet | stop and read the full `auth_rejected` error |

The log alone does not separate these; the outcome of the sign-in in step 5
does.

## 2. Park the dead row

On a first-ever login there is no row to park: skip to step 5 once the pod
prints its code.

On the CNPG primary, as `postgres`. The `cnpg.io/cluster` label matters: the
`database` namespace also holds a non-prod cluster with its own primary.

```bash
kubectl -n database get pods -l cnpg.io/instanceRole=primary,cnpg.io/cluster=platform-postgresql-cluster-prd
kubectl -n database exec -it -c postgres <primary-pod> -- psql -U postgres -d jdwillmsen_prd
```

```sql
update minecraft.auth_tokens
   set account = 'fwb-server-agent.rejected-<yyyymmdd-hhmm>'
 where account = 'fwb-server-agent';
```

Expect `UPDATE 1`. Renaming rather than deleting keeps the step reversible
until the new sign-in lands — if the diagnosis turns out wrong, rename it
back. The suffix carries the time as well as the date because this step can
run twice in a day (a sign-in that landed on the wrong account is parked the
same way), and two rows cannot share a name.

**Never `select` the `token` column, and never use `select *`, `\d+`-style
dumps or a `pg_dump` of this table.** It is a live credential, and the output
of a psql session run through an agent is persisted. To check what is there,
list only the non-secret columns:

```sql
select account, updated_at from minecraft.auth_tokens;
```

## 3. Delete the agent pod

```bash
kubectl delete pod -n jdwillmsen-prd -l app=jdwillmsen-minecraft-fwb-prd-server-agent
```

Delete **the agent pod only**. The Bedrock server's pod
(`...-minecraft-bedrock-0`) is a different workload, and deleting it migrates
the world volume — see the warning in
[the joinability runbook](minecraft-fwb-joinability-runbook.md#refused-the-server-said-no).

The pod is needed because the running one holds the dead token in memory and
keeps refreshing from it. After each failed refresh it re-reads the store, finds
no row, and gives the original error back — it never falls into the sign-in
path. Only a process that starts with an empty store does.

The Deployment is a single replica. Were it ever scaled up, only the pod that
holds the leader lock prints a code (the one that logs `leader_acquired`); a
standby waits without printing.

## 4. Wait for the sign-in prompt

Poll the **JSON events only**, using the step 1 filter:

```bash
kubectl logs -n jdwillmsen-prd deploy/jdwillmsen-minecraft-fwb-prd-server-agent -c agent \
  | jq -R -r 'fromjson? | select(.event != null) | "\(.timestamp) \(.event)"' | tail
```

The sequence is `leader_acquired`, then `auth_device_code_login`. That second
event is the agent saying a code has just been printed. Along the way you may
also see `auth_token_standby_unwarmed`; it is expected on a pod with no token
and is not an error.

If `auth_device_code_login` never appears, do not go looking for the code:
check `auth_store_unavailable_retrying`, `auth_store_failed` and `auth_failed`
(the database is unreachable or the table is missing; the agent deliberately
never prompts for a login over a store it could not read, since that would not
be the same as an empty one), and `leader_acquired` (without it the pod is
waiting on the lock and has no code to print).

## 5. Sign in — a person, in their own terminal

> **Human-only.** Run this in a terminal outside any AI agent session — a
> separate SSH login or a tmux pane — never through an agent's shell tool and
> never with Claude Code's `!`. The output is a live sign-in code.

```bash
POD=$(kubectl get pod -n jdwillmsen-prd -l app=jdwillmsen-minecraft-fwb-prd-server-agent \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
kubectl logs -n jdwillmsen-prd "$POD" -c agent | grep '^Authenticate at' | tail -1
```

Read the **new pod by name**, as above. Right after a restart,
`kubectl logs deploy/...` can resolve to the terminating pod and hand you its
old, dead code. Check that `$POD` is the pod created by step 3.

The Deployment runs one replica, so the newest pod is the one with the code.
If it has been scaled up and the command prints nothing, the newest pod is a
standby: find the pod that logged `leader_acquired` with the step 1 filter
(JSON events only, safe anywhere) and read that pod by name instead.

The line is plain text, not JSON:

```text
Authenticate at https://www.microsoft.com/link using the code XXXXXXXX.
```

Open the URL in a **private/incognito window** and sign in as the agent's own
Microsoft account — gamertag **`JDWServerAgent`**. The device-code page signs
in whichever Microsoft account the browser already has active; it does not ask
which one you meant. The README already covers this, including why the
gamertag in the server log, not your intention, is the check — see *A device
code can land on the wrong account* in
[the README](../README.md#the-afk-bots). That paragraph's remedy
is for a bot's PVC; for the agent, the equivalent is to park the row again
(step 2, with a new time suffix), delete the pod, and redo this step in a
fresh incognito window.

The token is stored under `MC_USERNAME` whichever account you signed in as, so
a wrong account is invisible in the database. Step 6 is where it shows.

The README's step for the agent's first login now points here; the old
`device_code_required` event and `/data/auth` instructions do not apply to this
agent.

**After a sign-in that fails, the agent waits before asking again.** At 0.28.0
a rejected sign-in is an `auth_rejected` like any other, so the next code comes
only after the 7.5–15 minute rejection backoff. That wait is deliberate: do
not delete the pod to get around it and try again unchanged. Delete the pod
(step 3) for a fresh code only once something about the account has been
fixed — see [Sign-in succeeds but is rejected](#sign-in-succeeds-but-is-rejected)
— and you are making the one retry that follows. A code that expired unused
is different; see below.

### If the code expires before you sign in

A code lasts about a quarter of an hour. When it runs out the sign-in attempt
ends with an error, the session fails as an ordinary connection failure — it does not contain
`invalid_grant`, so it is not counted as `auth_rejected` — and the next
session asks for a **new code**. Because the failed attempt lasted far longer than the 60-second
stability threshold, the reconnect delay resets to its 5-second floor, so a
fresh `auth_device_code_login` should follow within seconds (derived from the
code; not timed against a live expiry) and the same
`grep ... | tail -1` returns the new line.

Always take the **last** `Authenticate at` line; older ones are dead codes
still in the log. If no new `auth_device_code_login` appears after a couple of
minutes, repeat step 3: a new pod prints a code as soon as it is the leader.
Nothing is written to the database by a code that expired, so there is nothing
to clean up.

### Sign-in succeeds but is rejected

The signature, seen on 2026-10-08: you sign in as the right account, the
browser says *All done! You're now signed in to Minecraft for Android*, and
the agent then logs `auth_rejected` with the "user interaction is required"
`invalid_grant` above, raised by the device-token poll (`poll device token`). A second fresh code behaved the same. The rejection is
Microsoft's, not the pod's, the database's or the agent's: the same refusal came
from a throwaway client on a different host using the same library and client
configuration.

**This is the fix that worked on 2026-10-08/09. Why Microsoft requires it is not
known.** An upstream report against another Bedrock client library describes
the same error on the same flow and the same cure.

1. **Stop retrying codes.** Each one is another refusal for the account, and
   the agent's own backoff is 15 minutes for a reason.
2. **Check the account is healthy.** The account's owner signs in to
   account.microsoft.com normally. A lock, a verification prompt or anything
   pending means this is the abuse/lock case instead, below.
3. **Check two-step verification on that Microsoft account, and turn it on if
   it is off.** Store the recovery code in the password manager only — never
   paste it into a terminal, a chat or an agent session.
4. **Get a fresh code** (step 3, delete the pod, then step 5) and sign in once;
   this time Microsoft asks for the second step. Expect `Authentication
   successful.` as a plain line and `auth_token_written` within seconds.

You may see one `session_error` for a DNS lookup timeout right after the token
is written; on 2026-10-08 the session was established about 25 seconds later
regardless.

### Abuse hold and account locks

If the page shows an account lock or a "verify your identity" prompt instead of
asking you to confirm the app, or the log's error is `User account is found to
be in service abuse mode.`, the account has a hold on its side. **Stop. Do not
retry in a loop, and do not try other accounts or browsers to get a code
through.** Clear the hold as the account's owner through Microsoft's own
recovery flow, then come back to step 5.

Leaving the pod alone meanwhile is safe: it asks for a fresh code every time
one expires, which writes nothing to the database. What it does not do is
speed anything up.

## 6. Verify

All of this is JSON events and is safe through an agent.

```bash
POD=$(kubectl get pod -n jdwillmsen-prd -l app=jdwillmsen-minecraft-fwb-prd-server-agent \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
kubectl logs -n jdwillmsen-prd "$POD" -c agent \
  | jq -R -r 'fromjson? | select(.event != null) | "\(.timestamp) \(.event)"' | tail -15
kubectl get pod -n jdwillmsen-prd -l app=jdwillmsen-minecraft-fwb-prd-server-agent
```

Read the same pod the code came from in step 5, by name: `deploy/...` picks a
pod for you, and with more than one replica it can pick a standby whose log
never shows the sign-in.

In order, after the sign-in: `auth_token_written`, `joined`, `spawned`. The pod
goes `1/1`.

* **The right account.** Check the server log for the gamertag that joined —
  `JDWServerAgent` — rather than trusting which window you used:

  ```bash
  kubectl logs -n jdwillmsen-prd jdwillmsen-minecraft-fwb-prd-minecraft-bedrock-0 \
    -c jdwillmsen-minecraft-fwb-prd-minecraft-bedrock --since=15m | grep -a "Player connected" | grep -a JDWServerAgent
  ```

  (`-a` because the Bedrock console log contains binary bytes and plain `grep`
  would answer "binary file matches".)

  Any other gamertag means the wrong account was signed in. Go back to
  [step 5](#5-sign-in--a-person-in-their-own-terminal).
* `auth_token_write_failed` or `auth_token_written_to_fallback` instead of
  `auth_token_written` means the row was not saved; the login will be lost on
  the next restart. Do not proceed to step 7.
* **ArgoCD.** `jdwillmsen-minecraft-fwb-prd` goes `Healthy` once the
  Deployment is available:

  ```bash
  kubectl get applications.argoproj.io -n argocd jdwillmsen-minecraft-fwb-prd
  ```
* **The alert.** `JdwillmsenMinecraftAgentDisconnected` resolves on its own
  once the agent's session is up. `JdwillmsenMinecraftAgentSessionStale`
  is the check that a real account is reaching spawn on a six-hour cycle; see
  [the joinability runbook](minecraft-fwb-joinability-runbook.md#what-the-alerts-mean).

## 7. Delete the parked row

If step 2 parked a row, do this only after step 6 passes: the parked token is
dead, but it is still a credential at rest. If step 2 was skipped because this
was a first-ever login, there is nothing to delete; skip this step.

```sql
delete from minecraft.auth_tokens
 where account like 'fwb-server-agent.rejected-%';
```

This removes every parked row, including a second one left by the
wrong-account path in step 5. Expect `DELETE n` with `n` the number of times
step 2 ran, then check with the non-secret listing from step 2: one row,
`fwb-server-agent`, with a fresh `updated_at`.

## Known gaps and follow-ups

* **Which Microsoft account is which.** The sign-in address for each account is
  a field of the `minecraft-fwb` document in Vault (mount `kv`), named
  `account_email_<gamertag in lower case>` — for the agent,
  `account_email_jdwserveragent`. They are not secrets, but they are kept out
  of this public repo. Nothing in the cluster reads them; they exist for the
  operator doing step 5. Passwords and recovery codes are not there and stay
  in the account owner's password manager.
* **The AFK bot accounts may hit the same refusal.** They use the same client
  and flow, so a future refresh could be refused the same way. Changing those
  accounts ahead of time was considered and not pursued; if a bot logs the
  same "user interaction is required" refusal, apply
  [Sign-in succeeds but is rejected](#sign-in-succeeds-but-is-rejected) to
  that bot's account.
* A change to the agent that recovers from a rejected sign-in by itself
  (`fix/agent-auth-rejection-recovery` in the gameops repo) and an alert named
  `JdwillmsenMinecraftAgentAuthRejected` (in the platform repo) were both
  unmerged when this was written.

## What not to do

* Do not read, print or copy the `token` column. Nothing in this procedure needs
  it.
* Do not delete the Bedrock server's pod to "restart everything".
* Do not run `kubectl logs` unfiltered, or pipe it to anything that stores it,
  from an agent session while a code may be live.
* Do not retry sign-in attempts in a loop, whether Microsoft is blocking the
  account or merely rejecting each sign-in.
* Do not change the cluster by hand to hide the symptom (scaling the agent,
  editing the Deployment). ArgoCD syncs this chart; the fix here is data, in the
  database, and the process is above.
