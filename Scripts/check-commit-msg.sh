#!/usr/bin/env bash
#
# Checks that commit subjects follow `type(scope): description`, with an optional gitmoji after
# the colon — the form the history already uses:
#
#   feat(settings): ✨ Add adjustable panel opacity
#   fix: the hotkey gives an unfocused panel the focus back
#
# Usage:
#   Scripts/check-commit-msg.sh <base> <head>   check every commit in base..head
#   Scripts/check-commit-msg.sh <commit>        check one commit
#   Scripts/check-commit-msg.sh                 check the commits on HEAD that origin/master lacks
#
# Merge commits and the `fixup!`/`squash!` autosquash prefixes are skipped for merges and rejected
# for the latter, since they must not reach a shared branch.
#
set -euo pipefail

TYPES='feat|fix|refactor|docs|chore|test|ci|build|perf|style|revert'
PATTERN="^(${TYPES})(\\([a-z0-9][a-z0-9._/-]*\\))?!?: [^ ].*"

if [ "$#" -eq 2 ]; then
  RANGE="$1..$2"
elif [ "$#" -eq 1 ]; then
  RANGE="$1^!"
else
  RANGE="origin/master..HEAD"
fi

COMMITS=$(git rev-list --no-merges "$RANGE")
if [ -z "$COMMITS" ]; then
  echo "No commits to check in $RANGE."
  exit 0
fi

FAILED=0
COUNT=0
for sha in $COMMITS; do
  COUNT=$((COUNT + 1))
  SUBJECT=$(git log -1 --format=%s "$sha")
  if ! printf '%s\n' "$SUBJECT" | grep -Eq "$PATTERN"; then
    FAILED=$((FAILED + 1))
    echo "::error title=Invalid commit message::${sha:0:9} \"$SUBJECT\""
    echo "  ${sha:0:9}  $SUBJECT" >&2
  fi
done

if [ "$FAILED" -gt 0 ]; then
  {
    echo
    echo "$FAILED of $COUNT commit message(s) do not follow \`type(scope): description\`."
    echo "  type:  ${TYPES//|/, }"
    echo "  scope: optional, lowercase, e.g. (settings)"
    echo "  e.g.   feat(settings): ✨ Add adjustable panel opacity"
    echo "Fix with \`git rebase -i\` (reword) and force-push the branch."
  } >&2
  exit 1
fi

echo "$COUNT commit message(s) OK."
