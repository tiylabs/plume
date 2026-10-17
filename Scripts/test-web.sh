#!/usr/bin/env bash
#
# The editor's WKWebView suites: the real bundle, in a real WKWebView, driven from a JS file by
# Scripts/tools/editor-probe.swift.
#
# Separate from Scripts/test.sh because that one is pure Foundation and runs anywhere `swift build`
# does. These need a window server and the built web bundle. They cover the layer every editor bug
# in this project has come from, and they exist because a browser cannot measure layout and a mocked
# syntax tree would not catch what the real parser does with a real selection.
#
#   Scripts/test-web.sh                      every suite
#   Scripts/test-web.sh markdown switcher    just those
#   Scripts/test-web.sh --skip-editor ...    reuse Editor/dist instead of rebuilding it
#
# Suites:
#   commands          the formatting commands, eleven of them against every shape of selection
#   markdown          what a person typing markdown gets: every case is a keystroke script. Also
#                     writes its table to markdown-findings.txt
#   switcher          the switcher's geometry — a row can be selected, ordered and rendered correctly
#                     and still sit under a gradient, and only a real WKWebView has rectangles
#   space-assignment  the Assign to Desktop rows in the action panel
#   narrow            the action panel in a narrow panel (380 wide): its shortcut chips drop below
#                     420 so the labels fit, and that rule reads the viewport — which is the panel
#   tooltip           the pointer has to rest before a control is named; every case waits out a real
#                     timer, which is why its `run` is async and the probe awaits it
#   i18n              the language switch, against the real Locales/ files
#
# Adding a suite: add a line to SUITES below and list it above, and put its name in nothing else —
# Scripts/test-all.sh runs this script without arguments.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TESTS="$PWD/Editor/tests/webview"
HTML="$PWD/Editor/dist/index.html"
PROBE=Scripts/tools/editor-probe.swift

# name | test file | panel width (blank = the probe's default, which is the panel's own width)
SUITES=(
	"commands|commands.test.js|"
	"markdown|markdown.test.js|"
	"switcher|switcher.test.js|"
	"space-assignment|space-assignment.test.js|"
	"narrow|narrow.test.js|380"
	"tooltip|tooltip.test.js|"
	"i18n|i18n.test.js|"
	"agent|agent.test.js|"
)

skip_editor=0
wanted=()
for arg in "$@"; do
	case "$arg" in
		--skip-editor) skip_editor=1 ;;
		-h|--help)     sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*)            echo "unknown flag: $arg" >&2; exit 2 ;;
		*)             wanted+=("$arg") ;;
	esac
done

known() { local entry; for entry in "${SUITES[@]}"; do [[ "${entry%%|*}" == "$1" ]] && return 0; done; return 1; }
for name in ${wanted[@]+"${wanted[@]}"}; do
	known "$name" || { echo "unknown suite: $name" >&2; exit 2; }
done

if [[ "$skip_editor" -eq 0 ]]; then
	echo "==> Building the editor bundle"
	(cd Editor && node build.mjs >/dev/null)
fi

status=0
for entry in "${SUITES[@]}"; do
	IFS='|' read -r name file width <<<"$entry"
	if [[ ${#wanted[@]} -gt 0 ]]; then
		selected=0
		for w in "${wanted[@]}"; do [[ "$w" == "$name" ]] && selected=1; done
		[[ "$selected" -eq 1 ]] || continue
	fi

	echo "==> Running the $name suite"
	if [[ "$name" == markdown ]]; then
		swift "$PROBE" "$HTML" "$TESTS/$file" | tee markdown-findings.txt || status=1
		echo "==> Table written to markdown-findings.txt"
	else
		swift "$PROBE" "$HTML" "$TESTS/$file" ${width:+"$width"} || status=1
	fi
done
exit $status
