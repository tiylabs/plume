#!/usr/bin/env bash
# Native Settings regressions, linked to the app's actual debug objects. A real display cycle is
# essential: fittingSize alone does not catch the update-constraints loop when Storage is shown.
# Exclude only the app entry point so the suite owns NSApplication without launching app services.
set -euo pipefail
cd "$(dirname "$0")/.."

export PLUME_LOCALES="$PWD/Locales"
swift build --product Plume
BIN="$(swift build --product Plume --show-bin-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Use SwiftPM's current link list, not *.o: incremental builds can retain objects for deleted files.
awk '!/\/Plume.build\/main.swift.o$/' "$BIN/Plume.product/Objects.LinkFileList" > "$WORK/objects"
swiftc -parse-as-library -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$WORK/objects" \
    Tests/PlumeSettingsTests/SettingsLayoutTests.swift -o "$WORK/settings-tests"
"$WORK/settings-tests"
