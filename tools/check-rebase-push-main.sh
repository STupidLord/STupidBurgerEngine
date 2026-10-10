#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE=${REMOTE:-origin}
TARGET=${TARGET:-main}
CHECK_CMD=${CHECK_CMD:-'./burger.sh validate SampleGame --days 60'}
MESSAGE=${1:-'Apply pending changes'}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  printf 'Usage: %s [commit-message]\n' "$0"
  printf 'Environment: CHECK_CMD, REMOTE (default origin), TARGET (default main)\n'
  exit 0
fi

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'Run this inside the repository.'
cd "$ROOT"
BRANCH=$(git branch --show-current)
[[ -n "$BRANCH" ]] || fail 'Detached HEAD is not supported.'
[[ "$BRANCH" != "$TARGET" ]] || fail "Refusing to run from '$TARGET'; use a change branch."
git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "Remote '$REMOTE' does not exist."

printf 'Current branch: %s\nTarget: %s/%s\n' "$BRANCH" "$REMOTE" "$TARGET"
git status --short
[[ -n "$(git status --porcelain --untracked-files=all)" ]] || fail 'No changes found to commit.'

if [[ -n "$CHECK_CMD" ]]; then
  command -v dotnet >/dev/null 2>&1 || fail 'Missing required command: dotnet'
  printf '\nRunning validation:\n  %s\n' "$CHECK_CMD"
  bash -lc "$CHECK_CMD" || fail 'Validation failed; no commit, rebase, or push was attempted.'
else
  printf '\nValidation skipped because CHECK_CMD is empty.\n'
fi

printf '\nAll changes will be staged:\n'
git diff --stat
git status --short
confirm "Stage, commit, rebase onto $REMOTE/$TARGET, and push directly to $REMOTE/$TARGET?" || { printf 'Cancelled.\n'; exit 0; }

git add -A
git diff --cached --quiet && fail 'No staged changes remain after git add -A.'
git commit -m "$MESSAGE"
git fetch "$REMOTE" "$TARGET"
git rebase "$REMOTE/$TARGET" || {
  printf 'Rebase stopped. Resolve conflicts, stage files, then run: git rebase --continue\n' >&2
  exit 1
}

printf '\nCommits to push to %s/%s:\n' "$REMOTE" "$TARGET"
git log --oneline --decorate "$REMOTE/$TARGET..HEAD"
confirm "Push these commits directly to $REMOTE/$TARGET?" || { printf 'Cancelled after rebase; branch remains rebased.\n'; exit 0; }
git push "$REMOTE" "HEAD:$TARGET"
git fetch "$REMOTE" "$TARGET"
git switch "$TARGET"
git pull --ff-only "$REMOTE" "$TARGET"
git branch -D "$BRANCH"
printf 'SUCCESS: changes pushed to %s/%s; switched to %s and deleted branch %s.\n' "$REMOTE" "$TARGET" "$TARGET" "$BRANCH"
