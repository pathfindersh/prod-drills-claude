# Phase 0 — Prerequisites & repository setup

## 1. Goal

Create a safe, portable foundation for the lab before any cloud resource
exists. The repo is public, so the main risk is leaking a credential. This phase
sets up the working rules (`CLAUDE.md`), the repo skeleton, an automated secret
scanner that blocks bad commits locally, and a script that makes GitHub enforce
"changes to `main` only through a pull request". No AWS or Kubernetes resources
are created.

## 2. Architecture

```
 developer machine                                   GitHub (public repo)
┌──────────────────────────────────┐              ┌───────────────────────────┐
│ git commit                       │              │ main  (protected: PR only)│
│   └─ pre-commit framework        │   git push   │   ▲                       │
│        └─ gitleaks hook ──block──┼─ x (secret)  │   │ merge by owner        │
│              │ clean             │              │ feat/* ──► Pull Request   │
│              ▼                   │──────────────►                           │
│ feature branch feat/phase-N-*    │              └───────────────────────────┘
└──────────────────────────────────┘
   scripts/setup-github.sh ──(gh api)──► sets branch protection on main
```

## 3. What was built

| File / resource | Purpose |
|-----------------|---------|
| `CLAUDE.md` | Working rules: safety checks, teach mode, doc format, definition of done |
| `README.md` | Purpose, prerequisites (Ubuntu/WSL, macOS), quickstart, moving machines |
| `.gitignore` | Keeps tfstate, tfvars (except `envs/*.tfvars.example`), `.env`, kubeconfig, `*.pem`, age keys out of git |
| `LICENSE` | MIT |
| `.pre-commit-config.yaml` | Runs gitleaks (pinned `v8.30.1`) on every commit |
| `scripts/test-secret-block.sh` | Proves the hook blocks a fake AWS key; cleans up after itself |
| `scripts/setup-github.sh` | Idempotent `gh api` call: branch protection on `main` (PR required for everyone incl. admins, 0 approvals, no force-push/delete) |
| `docs/phases/` | One write-up per phase |
| `docs/commands-cheatsheet.md` | Verified commands grouped by tool |
| GitHub branch protection on `main` | Applied by `setup-github.sh` (run by the owner) |

## 4. Working commands

Run in order from the repo root.

```bash
# 1. Install the hook framework (Ubuntu/WSL; macOS: brew install pre-commit)
pip install --user pre-commit && export PATH=$HOME/.local/bin:$PATH
pre-commit --version
# pre-commit 4.6.2

# 2. Enable the hook in this clone (once per clone)
pre-commit install
# pre-commit installed at .git/hooks/pre-commit

# 3. Scan the whole repo
pre-commit run --all-files
# Detect hardcoded secrets.................................................Passed

# 4. Prove a fake AWS key is blocked
./scripts/test-secret-block.sh
# Detect hardcoded secrets.................................................Failed
# RuleID:      aws-access-token
# RuleID:      generic-api-key
# PASS: commit was blocked by gitleaks

# 5. Apply branch protection to main (run by the owner, after the first PR is merged)
./scripts/setup-github.sh
# Protecting pathfindersh/prod-drills-claude@main...
# {"approvals":0,"deletions":false,"enforce_admins":true,"force_push":false,"pr_required":true}
# (safe to rerun: same output)

# 6. Check which GitHub account and repo you are using
gh auth status
# ✓ Logged in to github.com account pathfindersh
gh api repos/pathfindersh/prod-drills-claude --jq '{default_branch,visibility}'
# {"default_branch":"main","visibility":"public"}
```

The first pre-commit run downloads gitleaks (and a Go toolchain) into
`~/.cache/pre-commit`; expect an "Installing environment" pause.

## 5. Problems hit and fixes

| Error message | Root cause | Command that failed | Command that worked | Lesson |
|---------------|-----------|---------------------|---------------------|--------|
| `FAIL: commit succeeded, hook did not block the secret` (hook showed `Passed`) | The test used AWS's documented example key (`AKIA...EXAMPLE`). Gitleaks allowlists it on purpose because it appears in countless docs | `./scripts/test-secret-block.sh` with the `...EXAMPLE` key | `./scripts/test-secret-block.sh` with a random-looking fake key | A security test must prove it can fail. Test with realistic input, and check the scanner directly before trusting it |
| Empty GitHub repo has no `main`, so a PR has no base branch | A new repo has no commits or branches, and CLAUDE.md forbids pushing to `main` | `gh pr create` (no base to target) | Owner-approved one-time seed: `git push origin <first-commit>:refs/heads/main` | Bootstrap needs one explicit exception to "never push to main"; do it once, then protect the branch |

## 6. How to verify

```bash
pre-commit run --all-files          # Passed
./scripts/test-secret-block.sh      # ends with: PASS: commit was blocked by gitleaks
git status --short                  # empty: the test cleaned up after itself
```

```bash
gh api repos/pathfindersh/prod-drills-claude/branches/main/protection \
  --jq '{enforce_admins: .enforce_admins.enabled, approvals: .required_pull_request_reviews.required_approving_review_count, pr_required: (.required_pull_request_reviews != null), force_push: .allow_force_pushes.enabled}'
# {"approvals":0,"enforce_admins":true,"force_push":false,"pr_required":true}
```

`enforce_admins` is `true`, so the PR rule applies to the owner too. Required
approvals stay at 0, which lets the sole owner merge their own PR (GitHub does
not let you approve your own PR, so 1 required approval would deadlock). Not
tested: an actual direct push to `main` (CLAUDE.md forbids it).

## 7. Rollback / teardown

- Remove the hook from a clone: `pre-commit uninstall`.
- Remove branch protection:
  `gh api -X DELETE repos/pathfindersh/prod-drills-claude/branches/main/protection`.
- Nothing else to undo: no cloud resources exist.
- If a real secret is ever committed: **rotate it first**, then clean history.
  Deleting the commit does not un-leak a public repo.

## 8. Concepts

- **Pre-commit hook** — a script git runs before it records a commit. Like a
  bag check at the door: nothing gets in unless it passes. It matters because
  the cheapest place to catch a leak is before it ever leaves your machine.
- **Secret scanning (gitleaks)** — pattern and entropy matching for keys and
  tokens. Like a metal detector tuned to known shapes (`AKIA...`) plus
  "this string looks too random". It has allowlists, which is why the AWS docs
  key slipped through.
- **Branch protection** — server-side rules on a branch. Like requiring a
  second signature on a cheque. In production it forces review and a CI gate so
  no single person's mistake reaches the deploy branch.
- **Idempotent script** — rerunning gives the same end state. Like setting a
  thermostat to 20°C rather than "turn the heat up": safe to repeat. It matters
  for automation that may run twice.
- **Pinned versions** (`rev: v8.30.1`) — builds are reproducible and a hijacked
  upstream `main` cannot change what runs on your machine.

## 9. Interview questions

1. **Why scan for secrets in a pre-commit hook and also in CI?** The hook is
   fast feedback but can be skipped (`--no-verify`) or not installed; CI is the
   enforced backstop.
2. **A key was pushed to a public repo. What do you do?** Revoke and rotate it
   immediately; assume it is compromised (bots scrape within minutes). Then
   remove it from history and check access logs (CloudTrail).
3. **Why does a "no EXAMPLE keys" allowlist matter when testing a scanner?**
   Scanners ignore known dummy values, so a test with them gives a false
   "pass". Always confirm the test fails when it should.
4. **Why pin a hook to a tag or commit instead of `main`?** Reproducibility
   and supply-chain safety: updates are reviewed, not pulled silently.
5. **What does `enforce_admins: true` change?** Admins can no longer bypass
   the rules, so protection is a real control. With a solo owner, required
   approvals must stay 0 or the owner cannot merge their own PRs.

## 10. Break it

1. **Skip the hook:** `git commit --no-verify` with a fake key succeeds. Drill:
   add a CI gitleaks job and make it a required status check.
2. **Allowlisted lookalike:** commit a real key edited to contain `EXAMPLE`;
   the scanner ignores it. Drill: review allowlists, add a custom rule.
3. **Hook not installed on a new machine:** a fresh clone has no
   `.git/hooks/pre-commit` until `pre-commit install` is run. Drill: clone
   fresh, commit a fake key, observe it passes, then fix the onboarding step.
