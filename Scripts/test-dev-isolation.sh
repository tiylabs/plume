#!/usr/bin/env bash
# Verify real bundle metadata and profile resolution without launching either notes app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift Scripts/dev-app.swift --test
python3 - "$ROOT" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
source = plistlib.loads((root / 'App/Info.plist').read_bytes())
release_path = root / 'build/Plume.app'
dev_path = root / 'build/Plume Dev.app'
release = plistlib.loads((release_path / 'Contents/Info.plist').read_bytes())
dev = plistlib.loads((dev_path / 'Contents/Info.plist').read_bytes())
for key, value in source.items():
    if key not in ('CFBundleShortVersionString', 'CFBundleVersion'):
        assert release.get(key) == value, f'release metadata changed: {key}'
assert 'PlumeScratchBuild' not in release
assert 'CFBundleDisplayName' not in release
assert dev['CFBundleIdentifier'] == 'com.tiylabs.plume.dev'
assert dev['CFBundleName'] == dev['CFBundleDisplayName'] == 'Plume Dev'
assert dev['PlumeScratchBuild'] is True
assert dev['CFBundleExecutable'] == release['CFBundleExecutable'] == 'Plume'
for app in (release_path, dev_path):
    assert (app / 'Contents/MacOS/Plume').is_file()
    assert (app / 'Contents/Resources/Editor/index.html').is_file()
assert (release_path / 'Contents/Resources/AppIcon.icns').read_bytes() == (root / 'App/AppIcon.icns').read_bytes()
assert (dev_path / 'Contents/Resources/AppIcon.icns').read_bytes() == (root / 'App/AppIcon-dev.icns').read_bytes()
assert (root / 'App/AppIcon.icns').read_bytes() != (root / 'App/AppIcon-dev.icns').read_bytes()
print('✓ release metadata/resources unchanged; development identity and icon are separate')
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# A probe inside a copy of each plist tests Bundle.main, not a hand-picked enum. It reads no user
# settings and writes no vault, so this can run while someone uses the installed release app.
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

let expected: BuildProfile = CommandLine.arguments[1] == "dev" ? .scratch : .release
func verify(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}
verify(BuildProfile.current == expected, "bundle profile is wrong")
let defaults = Settings()
verify(defaults.vaultPath == expected.defaultVaultPath, "default vault is wrong")
if expected == .scratch {
    let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("Plume-scratch").standardizedFileURL.path
    verify(defaults.vaultPath == sibling, "development vault is not beside the app")
} else {
    verify(defaults.vaultPath == "~/Documents/Plume", "release vault changed")
}
verify(defaults.summonHotkey == expected.defaultSummonHotkey, "default hotkey is wrong")
verify(defaults.checkForUpdates == expected.allowsSystemIntegration, "daily update default is wrong")
verify(!defaults.launchAtLogin, "login default changed")
let store = try JSONFileStore<Settings>.inApplicationSupport("settings.json")
verify(store.url.deletingLastPathComponent().lastPathComponent == expected.supportDirectoryName,
       "settings path belongs to the other app")
let deleted = try RecentlyDeleted.standardStore()
verify(deleted.deletingLastPathComponent().lastPathComponent == expected.supportDirectoryName,
       "deleted notes path belongs to the other app")
let invalid = try JSONDecoder().decode(Settings.self, from: Data(#"{"summonHotkey":"invalid"}"#.utf8))
verify(invalid.summonHotkey == expected.defaultSummonHotkey, "invalid hotkey falls back to the other app")
var settings = Settings(summonHotkey: .defaultSummon, launchAtLogin: true, checkForUpdates: true)
let before = settings
settings.isolateDevelopmentSettings()
if expected == .release {
    verify(settings == before, "release settings were changed by dev migration")
} else {
    verify(settings.summonHotkey == expected.defaultSummonHotkey, "old dev hotkey was not migrated")
    verify(!settings.launchAtLogin && !settings.checkForUpdates, "dev system integrations remained enabled")
}
print("✓ \(expected.displayName): bundle-resolved paths, defaults, hotkey fallback and settings isolation")
SWIFT
# find, not a glob: PlumeKit is grouped into subdirectories and `*.swift` only matches the top level.
swiftc $(find Sources/PlumeKit -name '*.swift') "$TMP/main.swift" -o "$TMP/Probe"
for CHANNEL in release dev; do
    APP="$ROOT/build/Plume.app"
    [[ "$CHANNEL" == "dev" ]] && APP="$ROOT/build/Plume Dev.app"
    PROBE="$TMP/$CHANNEL.app/Contents"
    mkdir -p "$PROBE/MacOS"
    cp "$APP/Contents/Info.plist" "$PROBE/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Probe" "$PROBE/Info.plist"
    cp "$TMP/Probe" "$PROBE/MacOS/Probe"
    codesign --force --sign - --timestamp=none "$TMP/$CHANNEL.app"
    (cd / && PLUME_CHANNEL=dev TERMIO_CHANNEL=dev "$PROBE/MacOS/Probe" "$CHANNEL")
done

python3 - "$ROOT" "$TMP" <<'PY'
import pathlib, shutil, subprocess, sys
root, temporary = map(pathlib.Path, sys.argv[1:])
fixture = temporary / 'clean-fixture'
fixture.mkdir()
shutil.copyfile(root / 'Makefile', fixture / 'Makefile')
notes = fixture / 'build/Plume-scratch'
notes.mkdir(parents=True)
(notes / 'note.md').write_text('# Keep this note')
(notes / '.hidden-note').write_text('keep hidden content')
external = temporary / 'external-notes'
external.mkdir()
(external / 'note.md').write_text('# External note')
(fixture / 'build/external-link').symlink_to(external, target_is_directory=True)
for path in ['build/Plume.app', 'build/Plume Dev.app', 'build/.hidden-output', '.build', 'Editor/dist']:
    (fixture / path).mkdir(parents=True)
subprocess.run(['make', '-s', '-C', str(fixture), 'clean'], check=True)
assert (notes / 'note.md').read_text() == '# Keep this note'
assert (notes / '.hidden-note').read_text() == 'keep hidden content'
assert (external / 'note.md').read_text() == '# External note'
assert list((fixture / 'build').iterdir()) == [notes]
assert not (fixture / '.build').exists() and not (fixture / 'Editor/dist').exists()
# Repeated clean is harmless, and a scratch symlink must retain its target too.
subprocess.run(['make', '-s', '-C', str(fixture), 'clean'], check=True)
shutil.rmtree(notes)
notes.symlink_to(external, target_is_directory=True)
subprocess.run(['make', '-s', '-C', str(fixture), 'clean'], check=True)
assert notes.is_symlink() and (notes / 'note.md').read_text() == '# External note'
print('✓ make clean removes build products while preserving scratch notes and symlink targets')
PY

# Fail before staging a DMG, on either dev identity or the legacy scratch marker.
if Scripts/make-dmg.sh "$ROOT/build/Plume Dev.app" > "$TMP/dmg.log" 2>&1; then
    echo "error: packaging accepted a development bundle" >&2
    exit 1
fi
grep -q 'not a release bundle' "$TMP/dmg.log"
printf '%s\n' '✓ release packaging rejects the development bundle'
