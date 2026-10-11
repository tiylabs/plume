#!/usr/bin/env bash
#
# Runs the PlumeKit suite.
#
# Not `swift test`: neither XCTest nor swift-testing ships with the Command Line Tools, so the
# standard runner needs a full Xcode install. The suite is an ordinary executable instead, which
# means a fresh checkout can be tested with nothing but the toolchain that builds the app.
#
# The suite is built once and then run as several shards at the same time. Almost all of its time is
# the Git sync tests waiting on real `git` subprocesses, not computing, so the shards overlap well
# even on a runner with few cores. `PLUME_TEST_SHARDS=1` runs it as a single process.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# SwiftPM's Xcode build-system layout is not always .build/<triple>/<config>; make the
# test-only resource path explicit rather than relying on the executable's directory depth.
export PLUME_LOCALES="${PLUME_LOCALES:-$ROOT/Locales}"

SHARDS="${PLUME_TEST_SHARDS:-6}"

swift build "$@" --product PlumeKitTests
BIN="$(swift build "$@" --product PlumeKitTests --show-bin-path)/PlumeKitTests"

if [ "$SHARDS" -le 1 ]; then
    exec "$BIN"
fi

LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

pids=()
for ((i = 0; i < SHARDS; i++)); do
    PLUME_TEST_SHARD="$i/$SHARDS" "$BIN" >"$LOGS/$i.log" 2>&1 &
    pids+=($!)
done

status=0
for ((i = 0; i < SHARDS; i++)); do
    if wait "${pids[$i]}"; then
        # Passing shards print one summary line each; fold them into a single total below.
        :
    else
        status=1
        echo "--- shard $i/$SHARDS failed ---"
        cat "$LOGS/$i.log"
    fi
done

if [ "$status" -eq 0 ]; then
    cat "$LOGS"/*.log | awk '
        /^✓ [0-9]+ tests, [0-9]+ assertions/ { t += $2; a += $4 }
        END { printf "✓ %d tests, %d assertions, all passing\n", t, a }'
fi
exit "$status"
