#!/usr/bin/env bash
#
# A ratchet on comments that point at documents this repository does not contain.
#
# Comments here used to cite "decision 76", "design frame 2a" or "LAB.md" — pieces of a private
# decision record that is not published. To anyone else those are dead links, so they are being
# rewritten into self-contained explanations (docs/architecture-refactor-plan.md, section 10.1) and
# no new ones may be added.
#
# The number of matches is held in Scripts/doc-refs.baseline. The check is strict in both
# directions: more matches than the baseline fails (something new was added), and fewer fails too,
# with a reminder to lower the baseline, so every reduction is recorded rather than quietly undone
# by the next addition. When the baseline reaches 0 the file is deleted and any match fails.
#
#   Scripts/check-doc-refs.sh           check
#   Scripts/check-doc-refs.sh --list    show every match
#
# The count is of matches, not of lines, and covers every tracked text file except .gitignore
# (whose comment explains why those documents stay local).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PATTERN='[Dd]ecisions? [0-9]+|[Ff]rames? [0-9]+[a-z]\b|LAB\.md|BRIEF\.md'
BASELINE_FILE=Scripts/doc-refs.baseline

matches() {
	# `|| true`: grep exits 1 when a file has no match, which is the good case.
	git ls-files -z | { grep -zv '^\.gitignore$' || true; } | xargs -0 grep -InoE "$PATTERN" 2>/dev/null || true
}

if [[ "${1:-}" == "--list" ]]; then
	matches
	exit 0
fi

actual=$(matches | wc -l | tr -d ' ')

if [[ ! -f "$BASELINE_FILE" ]]; then
	if [[ "$actual" -eq 0 ]]; then
		echo "✓ no references to unpublished documents"
		exit 0
	fi
	echo "✗ $actual reference(s) to unpublished documents, and no baseline file allows any:" >&2
	matches | head -20 >&2
	exit 1
fi

baseline=$(tr -d '[:space:]' < "$BASELINE_FILE")

if [[ "$actual" -gt "$baseline" ]]; then
	echo "✗ $actual references to unpublished documents, but the baseline allows $baseline." >&2
	echo "  Explain the reason in the comment itself instead of citing 'decision N', 'frame Xy' or LAB.md." >&2
	base=
	for ref in origin/dev origin/master master; do
		base=$(git merge-base HEAD "$ref" 2>/dev/null) && break || base=
	done
	echo "  Matches added since ${base:-the first commit}:" >&2
	[[ -n "$base" ]] || base=$(git rev-list --max-parents=0 HEAD | tail -1)
	git diff -U0 "$base" -- . ':(exclude).gitignore' ':(exclude)docs' \
		| grep -E '^\+[^+]' | grep -E "$PATTERN" | head -20 >&2 || true
	exit 1
elif [[ "$actual" -lt "$baseline" ]]; then
	echo "✗ only $actual references remain, below the baseline of $baseline." >&2
	echo "  Lower Scripts/doc-refs.baseline to $actual so the reduction is kept." >&2
	exit 1
fi

echo "✓ $actual references to unpublished documents (baseline $baseline)"
