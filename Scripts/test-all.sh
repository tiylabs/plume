#!/usr/bin/env bash
# Every gate, in one run: the PlumeKit suite (which includes the on-disk formats and the Swift ⇄ web
# bridge contract), the typecheck, the keyboard tables, the theme contract, and the WKWebView suites
# against one build of the editor bundle. What CI and the release workflow run, runnable here.
#
# THIS IS THE ONLY PLACE THE LIST OF SUITES LIVES. A new suite is added here and nowhere else; CI
# (.github/workflows/ci.yml) and the release workflow call this script rather than keeping their own
# lists, which is how the i18n suite once went unrun in both.
#
#   Scripts/test-all.sh               everything
#   Scripts/test-all.sh --only kit    just the PlumeKit suite (needs no Node)
#   Scripts/test-all.sh --only web    everything except the PlumeKit suite (typecheck, keyboard
#                                     tables, editor bundle, WKWebView suites)
set -uo pipefail
cd "$(dirname "$0")/.."

only=all
case "${1:-}" in
	"")          ;;
	--only)      only="${2:-}" ;;
	*)           echo "usage: $0 [--only kit|web]" >&2; exit 2 ;;
esac
case "$only" in
	all|kit|web) ;;
	*)           echo "usage: $0 [--only kit|web]" >&2; exit 2 ;;
esac

status=0
step() { echo; echo "==> $1"; shift; "$@" || { status=1; echo "✗ FAILED: $*"; }; }

if [[ "$only" != web ]]; then
	step "PlumeKit"            Scripts/test.sh
fi

if [[ "$only" != kit ]]; then
	step "Typecheck"          bash -c 'cd Editor && npm run --silent typecheck'
	step "Keyboard tables"    Scripts/test-keyboard.sh
	step "Theme contract"     bash -c 'cd Editor && node tests/theme-contract.mjs'
	step "Editor bundle"      bash -c 'cd Editor && node build.mjs >/dev/null'
	# Every WKWebView suite (commands, markdown, switcher, space-assignment, narrow, tooltip, i18n);
	# the list lives in Scripts/test-web.sh. The bundle was built once, two steps up.
	step "WKWebView suites"   Scripts/test-web.sh --skip-editor
fi

echo
[[ $status -eq 0 ]] && echo "✓ every suite green" || echo "✗ at least one suite failed"
exit $status
