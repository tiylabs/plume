# Homebrew cask for Plume.
#
# This file is the source copy. The one Homebrew actually reads lives in the tap repo
# `tiylabs/homebrew-tap` as `Casks/plume.rb`; publishing a release makes the workflow copy this there
# with the version and sha256 rewritten (the two lines starting `version` and `sha256`, which the
# workflow matches by shape — keep them as single lines). Keeping a copy here means the caveat text
# and the cask's shape are reviewed in the same pull request as the code they describe, instead of
# drifting in a repo nobody opens.

cask "plume" do
  # Placeholders: the release workflow overwrites both values when it publishes to the tap, so they
  # are never the current release. Do not bump them by hand.
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/tiylabs/plume/releases/download/v#{version}/Plume-#{version}.dmg"
  name "Plume"
  desc "Hotkey-summoned notes panel backed by a folder of markdown files you own"
  homepage "https://github.com/tiylabs/plume"

  depends_on macos: :sonoma

  app "Plume.app"

  # Enumerated rather than trashing the whole support directory, because it is no longer only the
  # app's own leavings. "Recently Deleted" lives in there — up to 30 days of notes the user
  # deleted and can still get back — so `--zap` would have swept away recoverable documents as a side
  # effect of uninstalling. Anything added here later has to answer the same question: is it Plume's,
  # or is it the user's?
  zap trash: [
    "~/Library/Application Support/Plume/settings.json",
    "~/Library/Application Support/Plume/state.json",
    "~/Library/Application Support/Plume/Themes",
  ]

  # Deliberately NOT listing the vault, and no longer the Recently Deleted folder either. `zap` is
  # for the app's own leavings, and both of those are the user's documents — the entire premise of
  # the product is that those files are theirs and outlive the app. Uninstalling Plume must never be
  # a way to lose them.

  caveats <<~EOS
    Plume requests no privacy permissions at all: the global hotkey goes through
    RegisterEventHotKey, which needs no Accessibility access. The only request it
    ever makes to the network is asking GitHub whether a newer release exists --
    when you press the button under Settings > About, and once a day when you
    summon the panel. It downloads and installs nothing, and sends nothing about
    you. Switch the daily one off under Settings > General. Your notes are plain
    .md files in ~/Documents/Plume.
  EOS
end
