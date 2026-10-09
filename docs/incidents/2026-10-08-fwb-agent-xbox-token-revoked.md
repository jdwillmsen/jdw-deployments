# 2026-10-08 — FWB agent offline 7.5 hours until Microsoft got a second sign-in step

| | |
|---|---|
| **Workload** | `jdwillmsen-prd/jdwillmsen-minecraft-fwb-prd-server-agent` (agent `agent-v0.28.0`) |
| **Detected** | 2026-10-08 16:53:55 UTC (`JdwillmsenMinecraftAgentDisconnected` fired); acted on ~23:25 |
| **Resolved** | 2026-10-09 00:14:22 UTC (agent `spawned`) |
| **Data loss** | None |
| **User impact** | Agent absent from the world for ≈ 7 h 32 min (16:42 → 00:14). Bedrock server, AFK bots and join probe stayed healthy |

## Summary

Microsoft refused the agent account's token refresh with `invalid_grant`, and
then refused every fresh device-code sign-in too, even though the sign-in
itself looked successful in the browser. It stopped refusing once two-step
verification was enabled on the agent's Microsoft account. **Cause class:
Microsoft refused token issuance for the account until two-step verification
was enabled; the underlying trigger — why Microsoft began demanding a stronger
sign-in for this account — is unknown.**

## Impact

The agent pod ran `0/1` with `/readyz` returning 503, so the ArgoCD app
`jdwillmsen-minecraft-fwb-prd` sat `Progressing`. Side effects while it was
down: `JdwillmsenMinecraftAgentSessionStale` fired at 23:52:29 and
`JdwillmsenMinecraftAfkBotsDegraded` (twice) at 00:03:55. The AFK bots stayed
connected throughout; they logged `presence_report_recovered` /
`presence_fetch_recovered` at 00:14:35–37 once the agent's presence API
returned.

## Timeline

All times UTC. 2026-10-08 unless stated.

```
16:42:06  daily token refresh refused: invalid_grant "The user could not be authenticated
          or user interaction is required. The user must sign in again and if needed
          grant the client application access to the requested scope."
16:53:55  JdwillmsenMinecraftAgentDisconnected fires (34 rejections followed in all)
~23:29    dead row parked (account renamed), pod deleted
23:30:32  device code issued; human signs in as the correct account; browser shows
          "All done! You're now signed in to Minecraft for Android"
23:39:12  device-token poll returns the same invalid_grant
23:41:48  second code issued
23:43:23  second code rejected the same way
23:52:29  JdwillmsenMinecraftAgentSessionStale fires
~23:58    throwaway Go probe on the devbox (gophertunnel v1.62.0
          auth.RequestLiveTokenContext, same Android client config, same public
          egress IP as the cluster); a first "All done" in the browser left the
          probe's code pending
~00:02    (10-09) the probe's code entered again: identical refusal
00:03:55  JdwillmsenMinecraftAfkBotsDegraded fires (x2)
~00:10    two-step verification turned on for the agent's Microsoft account
00:13:20  new pod issues a code; sign-in completes with the second step
00:13:56  auth_token_written; plain line "Authentication successful."
00:13:58  one session_error: DNS lookup i/o timeout
00:14:09  server log: Player connected: JDWServerAgent, xuid: 2535439664242923
00:14:22  agent joined, spawned; pod 1/1; ArgoCD app Healthy
```

The human also signed in to account.microsoft.com normally during this: no
lock, no verification prompt, nothing pending. The parked row was deleted
afterwards.

## Root cause

The mechanism up to Microsoft: the agent's token refresh and then every
device-code poll for this account were answered `invalid_grant` ("user
interaction is required"). The probe run outside the cluster, with the same
library and client configuration, received the identical refusal; its raw
response body held only `error`, `error_description` and a `correlation_id`.
That rules out the pod, the database and the agent code. A separate review of
the agent found no persistence defect: the rejected refresh token was exactly
what Microsoft issued a day earlier, and access tokens last 24 hours, which is
why the refresh lined up with the daily 16:42 restart — a coincidence, not the
trigger.

What cured it: enabling two-step verification on the account. An upstream
report against another Bedrock client library (PrismarineJS/mineflayer issue
3656) describes identical error text on the same flow with the same cure, and
was the lead.

**Not known:** why Microsoft started requiring a stronger sign-in for this
account, and whether the two-step requirement is what changed on their side.
The fix is established; the cause behind it is not.

## Contributing factors

* The agent never replaces a row that exists, so the first recovery step had to
  be done by hand (and, as it turned out, was not what was wrong).
* Both a revoked token and a refused issuance log as `auth_rejected` /
  `invalid_grant`, and an abuse hold logs the same code with different text.
  Nothing in the log separated them.
* The 15-minute rejection backoff meant each failed sign-in cost minutes before
  the next code, unless the pod was deleted.
* `kubectl logs deploy/...` can return a terminating pod's old code right after
  a restart.
* The agent account's email address is recorded nowhere in the repo or a
  secret.
* Detection to action was about six and a half hours.

## Hypotheses considered and rejected

| Hypothesis | Why it looked right | What disproved it |
|---|---|---|
| A dead stored token that the agent retries forever | Log said "must sign in again"; the row existed and the agent only prompts on an empty store | Parking the row got a code, but a correct sign-in was rejected again, twice. A new token was never issued |
| An account-side hold (abuse mode) | `invalid_grant` is what a hold looks like to the agent | The error text was the "user interaction" one, not "service abuse mode"; account.microsoft.com showed no lock, verification prompt or pending item |
| The pod, database or agent code | It was the only thing that had changed (a fresh pod and row) | The same refusal from a throwaway client on the devbox with the same egress IP |
| The sign-ins were not reaching the code being polled | One browser "All done" left the probe's code pending for over three minutes; why was never established (a stale tab or an earlier code are the likely slips) | The same code entered again was refused identically, as the two pod codes before it had been |

Three rejected sign-ins and one that reached no poller were spent before the
two-step-verification lead.

## Detection

`JdwillmsenMinecraftAgentDisconnected` at 16:53:55, 12 minutes after the first
rejection. It was acted on at about 23:25. Nothing named the cause: the alert
says the agent is disconnected, not that Microsoft is refusing it.

## Resolution

Enable two-step verification on the agent's Microsoft account (recovery code to
the password manager only), restart the pod, sign in once. The procedure,
including the earlier steps that turned out not to be the fix, is
[docs/minecraft-fwb-agent-reauth-runbook.md](../minecraft-fwb-agent-reauth-runbook.md).

## Action items

| # | Action | Type | Status |
|---|--------|------|--------|
| 1 | Agent starts a sign-in itself after a rejected token (branch `fix/agent-auth-rejection-recovery` in gameops) | mitigate | Unmerged |
| 2 | Alert `JdwillmsenMinecraftAgentAuthRejected` (platform repo) so a rejection is named, not just "disconnected" | detect | Unmerged |
| 3 | Bring the two AFK bot accounts to the same sign-in requirement ahead of time; they use the same client and flow | prevent | Not pursued (owner decision, 2026-10-09). If a bot is refused the same way, the runbook's fix applies to its account |
| 4 | Record where the agent account's email address lives | mitigate | Done: `account_email_*` fields of the `minecraft-fwb` Vault document, named in the runbook |
| 5 | Find why Microsoft began requiring a stronger sign-in for this account | prevent | Open, trigger unknown |
| 6 | Fix README step 5, stale for 0.28.0 (`device_code_required`, `/data/auth`) | mitigate | Done in this change |

## Assumptions invalidated

* **A rejected `invalid_grant` means the stored token is dead and a fresh
  sign-in cures it.** Here a fresh sign-in was refused too; the account needed
  a second verification step.
* **A browser saying "All done" means the sign-in worked.** The agent's
  device-token poll was rejected after it.
