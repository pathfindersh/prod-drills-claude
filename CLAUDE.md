# CLAUDE.md — prod-drills-claude

## Purpose
Portable production-practice lab. Repo = the whole lab: on any machine,
`git clone` + `./bootstrap.sh up --env <env>` brings everything up.
Owner: pathfindersh, senior DevOps/platform engineer building production habits.
Target: KodeKloud AWS playground (2h sessions, account wiped, max 3 EKS nodes,
t3.medium or smaller, restricted IAM). Later: personal AWS account.

## Safety (check before every action)
- `aws sts get-caller-identity` must show the expected account/region.
- `kubectl config current-context` must be this lab's cluster. Otherwise STOP.
- Repo is PUBLIC: never write a token, key, password or kubeconfig into any file.
- Never write a real public IP into any file or commit message (the admin IP, any
  real `/32`). Write "the owner's IP"; examples use 192.0.2.0/24, 198.51.100.0/24
  or 203.0.113.0/24. `scripts/check-no-ip.sh` must pass before every commit.
- On AccessDenied / explicit deny: STOP, show the exact error, propose options.
  Never try to escalate or work around IAM.
- Never push to main. Feature branch -> PR -> I merge.

## Ownership (default, not absolute)
- Prefer this repo's src/ for app code and ghcr.io/pathfindersh for app images.
- Use upstream/third-party sources when they are clearly the better or more
  practical choice (e.g. Argo CD, Prometheus/Grafana charts, base images).
  When you do, say why in one line and note it in docs/third-party.md.

## Teach mode (how we work)
1. Before each phase: explain the plan in <= 10 bullets (what, why, one
   alternative you rejected and why). Wait for my "go".
2. Mark 2-4 key commands per phase as YOU RUN: give me the command, what it
   does, and the expected output; wait for me to paste the result.
3. Small logical commits, conventional commit messages (feat:, fix:, docs:).
4. When something fails: show the error, explain the root cause in plain
   words, then fix. Never silently retry.

## Documentation (required at the end of every phase)
Write docs/phases/NN-<phase-name>.md with exactly these sections:
1. Goal - one paragraph.
2. Architecture - ASCII diagram of what exists after this phase.
3. What was built - table: file/resource | purpose.
4. Working commands - ONLY commands verified to work in this session, in run
   order, copy-pasteable, each with expected output. If a command failed and
   was replaced, list ONLY the working one here.
5. Problems hit and fixes - table: error message | root cause | command that
   failed | command that worked | lesson.
6. How to verify - checks proving the phase works.
7. Rollback / teardown - how to undo this phase safely.
8. Concepts - key terms explained in plain language with an analogy, and why
   each matters in production.
9. Interview questions - 5 questions with short model answers.
10. Break it - 3 ways this phase can fail in production (used later in drills).
Also keep README.md (prerequisites + quickstart) and
docs/commands-cheatsheet.md (every working command, grouped by tool) updated.

## Definition of done for a phase
PR open with code + docs, CI green (once CI exists), I ran the YOU RUN
commands myself, `./bootstrap.sh status` healthy (once it exists).
