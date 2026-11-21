#!/usr/bin/env bash
# Proves the gitleaks pre-commit hook blocks a fake AWS key.
# The key is assembled at runtime so no secret-shaped literal is stored in the repo.
# Usage: scripts/test-secret-block.sh        (stage + try to commit, then clean up)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

f=$(mktemp -p . fake-secret.XXXXXX.txt)
trap 'git reset -q -- "$f" 2>/dev/null || true; rm -f "$f"' EXIT

# Random-looking fake key (AKIA + 16 chars, 40-char secret). Do NOT use AWS's
# documented "...EXAMPLE" keys: gitleaks allowlists them, so they never trigger.
printf 'aws_access_key_id = %s%s\naws_secret_access_key = %s\n' \
  "AKIA" "QYLPMN5HHHFPZAM2" "h7Kd93LmQx2VbN8sTzR4wYc1PgJf6AeU0oIuXq5Z" > "$f"
git add "$f"

if git commit -m "test: fake aws key (must be blocked)"; then
  echo "FAIL: commit succeeded, hook did not block the secret" >&2
  git reset -q --soft HEAD~1
  exit 1
fi
echo "PASS: commit was blocked by gitleaks"
