# Rulesets

`protect-main.json` is what the branch protection on `main` is supposed to be.
It is the intended state, not a mirror of the live one — applying it is a
separate, manual step, the same way `jdwlabs/.github/.github/rulesets` works.

## Why this file exists now

GitHub Actions is blocked account-wide until **2026-10-01**: the free minutes
for private repositories ran out and there is no payment method on file, so
usage is blocked rather than billed. The block does not spare public
repositories, so nothing on this account builds.

`required_status_checks` cannot be satisfied while that holds. Every PR is
unmergeable, including a fix for a production incident, and `bypass_actors` is
empty by design so there is no way around it.

So that one rule is **temporarily removed from the live ruleset**, and the file
here keeps the version that has it. Everything else stays enforced: `main` is
still PR-only, still linear, still undeletable, still no force-pushes. The only
thing lost is the gate that has become impossible to pass.

`tools/ci-local` runs those same checks on a workstation in the meantime. It is
weaker than CI — same commands, not a clean machine — and it is what a merge
during this window rests on.

## Restoring it, on or after 2026-10-01

Confirm Actions actually runs again first; a restore while jobs still queue
puts the repository straight back to unmergeable.

```bash
# 1. Prove Actions is alive
gh workflow run ci.yml --repo jdwillmsen/jdw-deployments
gh run list --repo jdwillmsen/jdw-deployments --limit 1   # not "queued" forever

# 2. Put the required checks back
gh api -X PUT /repos/jdwillmsen/jdw-deployments/rulesets/23526991 \
  --input .github/rulesets/protect-main.json

# 3. Confirm what is live matches this file
gh api /repos/jdwillmsen/jdw-deployments/rulesets/23526991 \
  --jq '[.rules[].type] | sort'
# deletion, non_fast_forward, pull_request, required_linear_history, required_status_checks
```

## Drift

Nothing reconciles this file against the live ruleset automatically. If the two
disagree, the live one is what is enforced and this one is what was intended —
find out which is wrong before assuming either.
