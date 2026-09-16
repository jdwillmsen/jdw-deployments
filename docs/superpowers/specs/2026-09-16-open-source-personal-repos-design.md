# Taking the four personal repos public

Date: 2026-09-16

## Problem

The `jdwillmsen` account is on track to exceed its 2,000 free Actions minutes
for private repositories. Measured across every workflow run between 2026-09-01
and 2026-09-16, billed as GitHub bills — per job, rounded up to the minute:

| Repository | Billed | Actual compute | Rounding overhead |
|---|---|---|---|
| `jdw-deployments` | 770 min | 197 min | +291% |
| `minecraft-afk-bot` | 639 min | 370 min | +73% |
| `minecraft-server-agent` | 431 min | 337 min | +28% |
| `mc-console-bridge` | 28 min | 17 min | +67% |
| **Total** | **1,868 min** | **921 min** | **+103%** |

Half the bill is not compute. It is the per-job round-up. `jdw-deployments` is
the extreme case: `ci.yml` fans out six jobs averaging 6-30 seconds each, and
every one of them bills a full minute. 118 CI runs over sixteen days cost 708
minutes for roughly 77 seconds of real work per run.

At 117 billed minutes per day the account exhausts the free allowance around
2026-09-17.

Public repositories have no Actions minute allowance to exhaust — the minutes
are unmetered. Making these four public removes the constraint entirely rather
than deferring it, and does so without touching a single workflow.

The four public `jdwlabs` org repositories already cost nothing for this reason.
The entire private burn comes from these four personal repositories.

## Decisions

Four decisions were settled before this document was written. Each is recorded
with the reasoning, because the reasoning is what a later reader will need.

### Public now, community layer deferred

These become public repositories with a license. They do not become projects
soliciting contributions: no issue triage commitment, no response-time
expectation, no support promise.

**Issues stay enabled.** An earlier draft of this document disabled them, which
was a defect. Every repository's `renovate.json` extends `config:recommended`,
which includes `:dependencyDashboard` — `minecraft-afk-bot` has that dashboard
open right now as issue #10. Disabling Issues hides the dashboard and makes
Renovate log an error on every run. The right control is a `SUPPORT.md` saying
no support is offered, not an off switch that breaks tooling.

The community health files in Phase 1 are not in tension with that. They exist
to *state* the position — a `CONTRIBUTING.md` whose content is "this is a
personal homelab, contributions are not being sought" is more useful to a
visitor than no file at all, and a `SECURITY.md` giving a disclosure address is
worth having the moment the code is readable by strangers.

This is reversible in the direction that matters: adding a community layer later
is easy, and withdrawing one is not.

### PolyForm Noncommercial 1.0.0, matching the org

All five `jdwlabs` repositories (`deployments`, `apps`, `infrastructure`,
`platform`, `.github`) carry `LICENSE.md` containing PolyForm Noncommercial
1.0.0 with the notice `Copyright Jake Willmsen`. GitHub reports these as
`NOASSERTION` because PolyForm has no SPDX identifier in GitHub's licence
database.

PolyForm Noncommercial is source-available, not OSI open source: it forbids
commercial use. That is a deliberate divergence from "open source" as the phrase
is normally meant, and it is the right one here — consistency across all eight
repositories matters more than an OSI badge on a homelab, and the free-minutes
outcome is identical either way. Actions pricing keys off repository
*visibility*, never licence.

Relicensing to MIT stays available for as long as there is a single copyright
holder. It becomes hard once outside contributors hold copyright in the tree.

### Repositories stay under `jdwillmsen`

Not transferred to the `jdwlabs` org, despite the org holding the four
sibling repositories and the shared `.github`.

`minecraft-server-agent` declares `module github.com/jdwillmsen/minecraft-server-agent`
and carries 337 internal import references to that path. `minecraft-afk-bot` and
`mc-console-bridge` declare matching `github.com/jdwillmsen/*` module paths.
Transferring would mean either rewriting every import path across three repos or
living permanently on a GitHub redirect with a module path that disagrees with
its host. Public Actions minutes are free regardless of owner, so the transfer
buys nothing and costs a large mechanical change.

### The historical `jdwillmsen@gmail.com` commits are accepted, not purged

Twenty-eight commits across three repositories carry `jdwillmsen@gmail.com` as
author or committer:

| Repository | PR refs | Gmail commits reachable |
|---|---|---|
| `jdw-deployments` | 103 | 18 |
| `minecraft-server-agent` | 43 | 6 |
| `minecraft-afk-bot` | 19 | 4 |
| `mc-console-bridge` | 3 | 0 |

None are on `main` in any repository — `main` is clean at 0 of 110 and 0 of 44
respectively. They survive only on merged pull request branches, and therefore
in `refs/pull/*`.

`refs/pull/*` is read-only and server-maintained. Deleting the branch does not
remove it; the branch for PR #9 is already deleted on the remote and GitHub
still serves its commits. Neither a client nor the REST API can touch it:

```
$ git push origin :refs/pull/9/head
 ! [remote rejected] refs/pull/9/head (deny updating a hidden ref)

$ gh api -X DELETE /repos/jdwillmsen/jdw-deployments/git/refs/pull/9/head
{"message":"refs/pull/* is read-only.","status":"422"}
```

`git filter-repo` rewrites `refs/heads/*` and `refs/tags/*` only. Running it
here would change every SHA on `main` from 2026-08-19 onward, strip the
signature from all 110 currently-verified commits — `filter-repo` cannot re-sign
— and still leave the address exposed. It is strictly worse than doing nothing.

Two routes do work, and both were declined:

- **GitHub Support** will dereference affected PRs, garbage-collect the server
  and clear cached views. Their stated bar is sensitive data whose risk "can't
  be mitigated by rotating affected credentials", which an email address does
  not obviously meet. Cost of waiting depends on a fact not yet established —
  see the payment-method caveat under Verification.
- **Delete and recreate** each repository. A complete purge, entirely
  self-service, that destroys all pull request review history and breaks 135
  commit-message cross-references of the form `(#96)`.

Accepted instead: the address is a Gmail account already known to every service
the owner has signed up for, the commits are invisible outside old PR views, and
neither remedy is proportionate. Account-level email privacy is enabled so that
nothing new leaks.

## Design

### Phase 1 — content pass, while still private

Everything in this phase is a normal pull request against a private repository.
Nothing here is visible to anyone until Phase 2.

**`LICENSE.md` in all four repositories.** PolyForm Noncommercial 1.0.0, copied
byte-identical from `jdwlabs/.github`, carrying `Required Notice: Copyright Jake
Willmsen`. Without it, a public repository defaults to all rights reserved,
which communicates less than the licence does.

**A new public `jdwillmsen/.github` repository.** No such repository exists
today. A user-level `.github` repository supplies default community health files
to every public repository the account owns, present and future, from one place:

```
CODE_OF_CONDUCT.md
CONTRIBUTING.md
SECURITY.md
ISSUE_TEMPLATE/{bug_report.md,feature_request.md,config.yml}
PULL_REQUEST_TEMPLATE.md
SUPPORT.md
```

Adapted from `jdwlabs/.github`, reworded for what these actually are: a personal
homelab, maintained for its owner, with no support promise and no response-time
commitment. Four repositories share one source rather than each carrying a copy
that drifts.

**README correction in `jdw-deployments`.** Its third line currently reads
"Private deployment manifests for the `jdwillmsen` tenant of the jdwlabs
Kubernetes platform." That becomes false at the moment of the flip.

The other three READMEs need nothing. They already explain purpose, boundaries
and configuration to a reader with no context — `mc-console-bridge` documents
the console websocket protocol as verified against a live server, and
`minecraft-afk-bot` opens by explaining why mob farms need a player present.
They are better than most published projects. Leave them alone.

**Delete merged branches.** `jdw-deployments` and `minecraft-server-agent` each
carry roughly twenty stale remote branches whose PRs merged weeks ago. This is
hygiene, not privacy: the gmail commits survive in `refs/pull/*` regardless, and
deleting branches does not touch them.

**Account settings.** Enable "Keep my email address private" and "Block command
line pushes that expose my email". `user.email` is already the `users.noreply`
address both locally and globally, so nothing is currently leaking; this closes
the hole rather than fixing a live problem.

### Phase 2 — the flip

```
gh repo edit jdwillmsen/<repo> --visibility public --accept-visibility-change-consequences
```

Ordered smallest blast radius first: `mc-console-bridge` (4 commits, 3 PR refs,
zero gmail exposure), then `minecraft-afk-bot`, `minecraft-server-agent`,
`jdw-deployments`. `mc-console-bridge` is the canary — everything in Phase 3 is
proven against it before the other three follow.

### Phase 3 — hardening, which only becomes possible once public

Branch protection and rulesets require GitHub Pro on private repositories. On
these four the API currently returns:

```
$ gh api /repos/jdwillmsen/jdw-deployments/rulesets
{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}
```

The global working rules mandate PR-only merges to `main` with green CI and no
direct pushes. On these repositories that rule is currently convention, not
enforcement. Going public makes it enforceable at no cost, which is the largest
quality gain in this plan and the reason Phase 3 is not optional.

**Rulesets, managed as code.** `jdwlabs/.github` already contains
`.github/rulesets/apply.sh`, which defaults its target to whatever `origin`
points at, accepts `--repo` and `--dir`, records a `source` field in each export
and refuses to apply one repository's export to another without `--force`. Each
repository gets its own `.github/rulesets/` directory holding its own
`baseline.json` naming its own CI job contexts.

Rules mirror the org baseline: `pull_request` with one approving review and
`dismiss_stale_reviews_on_push`, `deletion`, `non_fast_forward`,
`required_linear_history`, `required_status_checks`. Plus the branch naming
convention, regex `^(feat|fix|hotfix|release|chore|docs|refactor|test|ci)/.+`
over `refs/heads/**` excluding `main`.

One change is mandatory, and it is not the obvious one. The org baseline's
bypass actor is:

```json
{"actor_id": null, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}
```

`OrganizationAdmin` does not exist on a personal repository, so the org's
`required_approving_review_count: 1` cannot be carried over as written — GitHub
does not allow approving your own pull request, and there is no second person.
Left uncorrected, this deadlocks the repository permanently.

The tempting fix is a `RepositoryRole` bypass actor with the admin role id.
Do not do this: the REST API documents `RepositoryRole` as a valid
`actor_type` but publishes **no mapping from role name to integer id**, so any
value written here is a guess that happens to work until it doesn't.

Use `required_approving_review_count: 0` instead. The `pull_request` rule still
forbids pushing directly to `main` and still requires a pull request, which is
the property the working rules actually mandate. A required approval that the
sole maintainer bypasses by construction enforces nothing; dropping it removes
the deadlock, removes the undocumented magic number, and loses no real
guarantee. This is a deliberate divergence from the org baseline, recorded here
so nobody "fixes" it back.

**Adopt the org's reusable security workflows.** `jdwlabs/.github` is public and
both workflows are `workflow_call`, so a personal repository can call them. Pin
by SHA exactly as `jdwlabs/deployments` does:

```yaml
uses: jdwlabs/.github/.github/workflows/security-scan.yml@b827924589b7e129a81762131b9d451121718bdc
uses: jdwlabs/.github/.github/workflows/verify-pr-signatures.yml@b827924589b7e129a81762131b9d451121718bdc
```

This contributes the `scan / scan`, `scan / gitleaks`, `scan / binaries` and
`signatures / signatures` contexts. None of the four repositories has any
secret scanning today. Adding gitleaks to every pull request is the single
largest security improvement available here, and it is the concrete meaning of
"bring up quality".

**Actions fork policy.** Set each repository to require approval for all outside
collaborators before workflows run. The structural risk is already low — none of
the four uses `pull_request_target` or a self-hosted runner, and every
secret-bearing workflow (`release`, `renovate`, `protocol-check`) triggers on
tag, schedule or dispatch only, never on `pull_request`. The PR-triggered
`ci.yml` in all four consumes no secrets.

**Code scanning becomes available.** GitHub's documentation: *"If you want to
use code scanning on private repositories, you need a GitHub Code Security
licence."* No such licence is needed on a public repository, so CodeQL becomes
available to all four at no cost the moment they flip. None has code scanning
today. This is worth taking alongside the reusable security workflows, though
it is additive rather than blocking — set it up after Phase 3 proves out on
`mc-console-bridge`.

**GHCR package visibility is left alone.** Making a repository public does not
publish its `ghcr.io/jdwillmsen/*` images. The cluster continues pulling with
its existing pull secret. A separate decision, deliberately not bundled here.

### Deferred

CI consolidation in `jdw-deployments`: six jobs collapsing to one or two,
eliminating five redundant `actions/checkout` plus `azure/setup-helm` pairs per
run and the 291% rounding overhead. Once the repository is public these minutes
are free, so this stops being urgent. It remains worth doing for run latency and
for the plain wastefulness of paying six setup costs for 77 seconds of work.
Tracked as follow-up, not done here.

## Verification

Two facts underpinning this document were not verifiable from the API available
to the agent that wrote it, and should be confirmed by a human before Phase 2.

**Is there a payment method on file?** This decides whether running out of
minutes is a bill or a wall. GitHub's billing documentation: *"If your account
does not have a valid payment method on file, usage is blocked once you use up
your quota."* With a card, overage on roughly 1,500 minutes is about $12 and the
timeline is relaxed. Without one, **CI stops entirely on all four repositories
around 2026-09-17** and stays stopped until the cycle resets. An earlier draft
asserted the $12 figure unconditionally, which was wrong. Check Settings →
Billing.

**The minute figures are a reconstruction, not GitHub's own accounting.** The
`/actions/runs/{id}/timing` endpoint returns `total_ms: 0` for every run on this
account, including old ones, so it could not be used. The table above was
computed from each job's `completed_at - started_at`, rounded up per job, with
skipped and never-dispatched jobs excluded — which is how GitHub documents its
billing, but is still an estimate. Confirm the totals against Settings → Billing
before treating them as exact. The conclusion is robust to a wide margin of
error: the free allowance is 2,000 and the estimate is 1,868 with two weeks to
run.

| Check | Command | Expected |
|---|---|---|
| Visibility | `gh repo view jdwillmsen/<repo> --json visibility` | `PUBLIC` ×4 |
| Rulesets live | `gh api /repos/jdwillmsen/<repo>/rulesets` | HTTP 200 — currently 403, so 200 proves both flip and ruleset |
| Licence detected | `gh api /repos/jdwillmsen/<repo>/license` | resolves `LICENSE.md` |
| Community files | `gh api /repos/jdwillmsen/<repo>/community/profile` | inherits from `jdwillmsen/.github` |
| Enforcement real | open a throwaway PR on `mc-console-bridge` | direct push to `main` rejected; PR blocked until checks green |
| Minutes | re-run the per-job billing measurement next cycle | private-repo consumption approaching zero |

## Risks

**Ruleset deadlock.** A wrong bypass actor locks the repository against its only
maintainer. Mitigated by applying to `mc-console-bridge` first and proving a
full PR cycle there before touching the other three.

**Renovate auto-merge stalls.** `jdw-deployments` configures Renovate
auto-merge, which waits on required checks. Adding four new contexts means its
open PRs hang until those checks report. Sequence deliberately: apply the
ruleset, watch one Renovate PR go green end to end, then continue.

**`RENOVATE_TOKEN` on a public repository.** The PAT is never exposed to fork
PRs — `renovate.yml` triggers on schedule and dispatch only, and GitHub
withholds secrets from `pull_request` runs on forks regardless. Confirm the
token's scopes are minimal before the flip rather than after.

**The flip is irreversible in practice.** A public repository is cloned, forked
and indexed within minutes. Returning it to private does not retract what was
taken. This is accepted knowingly; the secret audit below is what makes it
acceptable.

## Security audit, as performed

Every commit of all four repositories was scanned before this document was
written.

No credentials found: zero matches for GitHub PAT (`ghp_`, `gho_`, `ghs_`,
`github_pat_`), AWS access key (`AKIA…`), OpenAI or Anthropic key (`sk-`,
`sk-ant-`), Slack token (`xox[baprs]-`), Google API key (`AIza…`), GitLab PAT
(`glpat-`), PEM private key block, or JWT (`eyJhbGciOi…`). Every hit on
`password`/`token`/`secret` assignment patterns resolved to a test fixture
(`"s3cret-token"`, `AccessToken: "fresh"`) or a struct field name. No `.pem`,
`.key`, `.kubeconfig`, `.env`, `.npmrc` or `.netrc` was ever added in any
repository's history.

`jdw-deployments` contains three `ExternalSecret` manifests. These hold Vault
*references* — `key: minecraft-fwb`, `property: console_websocket_password` —
never values. No `kind: Secret` manifest exists in the tree.

Known and accepted exposures:

- **RFC1918 addresses.** `charts/minecraft-fwb/values.yaml` carries
  `http://192.168.1.50:8000/v1` (vLLM) and `target: 192.168.1.87:31134`;
  `minecraft-server-agent/docs/eval/*.md` cites `192.168.1.50:8000` throughout.
  Unreachable from outside the LAN, but a published map of the home network.
  Left as-is: the values file is live ArgoCD configuration and editing it to
  scrub a private address risks a production change for no security gain, given
  the same addresses persist in history either way.
- **`10.96.0.1`** is the default Kubernetes service CIDR, not site-specific.
- **`10.0.0.5`** appears only in `minecraft-server-agent` test fixtures.
- **The 28 `jdwillmsen@gmail.com` commits** described above.

## Follow-up

- CI consolidation in `jdw-deployments` (six jobs to two)
- The community layer generally: whether to accept contributions, and whether
  the issue templates should invite reports or discourage them
- GHCR package visibility
- `minecraft-afk-bot`'s `Protocol Check`: 321 `workflow_dispatch` runs in
  sixteen days at 361 billed minutes, the single largest job in the estate.
  Worth understanding why it is dispatched that often even once the minutes
  are free.
