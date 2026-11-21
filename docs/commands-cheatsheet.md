# Commands cheatsheet

Only commands verified to work. Grouped by tool; updated every phase.

## pre-commit

```bash
pip install --user pre-commit && export PATH=$HOME/.local/bin:$PATH
pre-commit install                  # enable hooks in this clone (once per clone)
pre-commit run --all-files          # scan the whole repo
pre-commit uninstall                # remove the hook
```

## gitleaks (via pre-commit)

```bash
./scripts/test-secret-block.sh      # prove a fake AWS key is blocked
```

AWS's documented `...EXAMPLE` keys are allowlisted and will NOT be flagged.

## git

```bash
git checkout -b feat/<name>                       # feature branch
git push -u origin feat/<name>                    # publish branch
git push origin <sha>:refs/heads/main             # one-time seed of an empty repo (owner-approved)
```

## gh

```bash
gh auth status
./scripts/setup-github.sh                 # idempotent branch protection on main (admins enforced, 0 approvals; needs main to exist)
gh api repos/pathfindersh/prod-drills-claude --jq '{default_branch,visibility}'
gh api repos/pathfindersh/prod-drills-claude/branches/main/protection \\
  --jq '{enforce_admins: .enforce_admins.enabled, approvals: .required_pull_request_reviews.required_approving_review_count, pr_required: (.required_pull_request_reviews != null), force_push: .allow_force_pushes.enabled}'
```
