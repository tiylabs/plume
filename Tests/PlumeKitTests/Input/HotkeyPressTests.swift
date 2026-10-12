import Foundation
import PlumeKit

/// Decision 180: one press of the summon hotkey, as a table over the panel's three facts and the
/// dismiss setting.
func runHotkeyPressTests() {
    Check.suite("Hotkey press") {
        let modes: [Settings.DismissMode] = [.sameHotkeyToggles, .escapeOnly]

        Check.test("a parked panel is summoned, whatever else is true") {
            for mode in modes {
                for space in [true, false] {
                    for focus in [true, false] {
                        Check.equal(
                            HotkeyPress.resolve(isUp: false, onActiveSpace: space, hasFocus: focus, dismissMode: mode),
                            .summon
                        )
                    }
                }
            }
        }

        Check.test("a panel up on another Space comes here rather than hiding where you cannot see it") {
            for mode in modes {
                for focus in [true, false] {
                    Check.equal(
                        HotkeyPress.resolve(isUp: true, onActiveSpace: false, hasFocus: focus, dismissMode: mode),
                        .bringHere
                    )
                }
            }
        }

        Check.test("issue 4: a panel that lost the focus gets it back, in both modes") {
            for mode in modes {
                Check.equal(
                    HotkeyPress.resolve(isUp: true, onActiveSpace: true, hasFocus: false, dismissMode: mode),
                    .focus
                )
            }
        }

        Check.test("a focused panel hides when the hotkey toggles") {
            Check.equal(
                HotkeyPress.resolve(isUp: true, onActiveSpace: true, hasFocus: true, dismissMode: .sameHotkeyToggles),
                .dismiss
            )
        }

        Check.test("a panel kept to another desktop stays there, whatever else is true") {
            for mode in modes {
                for up in [true, false] {
                    for space in [true, false] {
                        for focus in [true, false] {
                            Check.equal(
                                HotkeyPress.resolve(
                                    isUp: up, onActiveSpace: space, hasFocus: focus, dismissMode: mode,
                                    keptElsewhere: true
                                ),
                                .elsewhere
                            )
                        }
                    }
                }
            }
        }

        Check.test("Esc only: the hotkey never hides the panel") {
            Check.equal(
                HotkeyPress.resolve(isUp: true, onActiveSpace: true, hasFocus: true, dismissMode: .escapeOnly),
                .focus
            )
        }
    }
}
