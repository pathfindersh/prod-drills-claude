#!/usr/bin/env bash
# Idempotent GitHub repo settings: branch protection on main (PR required).
# PUT on the protection endpoint replaces the whole config, so reruns converge.
# Admins are enforced too (no direct pushes to main), approvals stay at 0 so the
# sole owner can still merge their own PRs.
# Environments (staging/prod) are added in Phase 5.
# Usage: scripts/setup-github.sh [owner/repo]
set -euo pipefail

REPO="${1:-pathfindersh/prod-drills-claude}"
BRANCH="main"

gh auth status >/dev/null 2>&1 || { echo "gh not authenticated: run 'gh auth login'" >&2; exit 1; }

# Protection needs the branch to exist (an empty repo has none).
if ! gh api "repos/${REPO}/branches/${BRANCH}" >/dev/null 2>&1; then
  echo "Branch '${BRANCH}' does not exist on ${REPO} yet. Merge the first PR, then rerun." >&2
  exit 1
fi

echo "Protecting ${REPO}@${BRANCH}..."
gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input - >/dev/null <<JSON
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": true
}
JSON

echo "Current protection:"
gh api "repos/${REPO}/branches/${BRANCH}/protection" \
  --jq '{pr_required: (.required_pull_request_reviews != null), approvals: .required_pull_request_reviews.required_approving_review_count, force_push: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled, enforce_admins: .enforce_admins.enabled}'
