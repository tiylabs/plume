import Foundation
import PlumeKit

func runSettingsTests() {
    Check.suite("Accent palette") {
        func luminance(_ hex: String) -> Double {
            let value = UInt32(hex.dropFirst(), radix: 16)!
            let channels = [value >> 16, (value >> 8) & 255, value & 255].map {
                let channel = Double($0) / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }

        func contrast(_ foreground: String, _ background: String) -> Double {
            let a = luminance(foreground), b = luminance(background)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        Check.test("all seven tones remain readable on panel and selected row surfaces") {
            Check.equal(Settings.accentOptions.count, 7)
            Check.equal(Set(Settings.accentOptions.map(\.hex)).count, 7)
            for option in Settings.accentOptions {
                for background in ["#ffffff", "#f2f2f4", "#e2e2e4"] {
                    Check.expect(contrast(option.hex, background) >= 4.5, "\(option.id) light on \(background)")
                }
                for background in ["#1a1a1c", "#242428", "#26262a", "#353539"] {
                    Check.expect(contrast(option.darkHex, background) >= 4.5, "\(option.id) dark on \(background)")
                }
            }
        }

        Check.test("old presets resolve to new pairs and custom colours survive") {
            for (hex, id) in [("#c98a1f", "amber"), ("#5b67d8", "indigo"), ("#2f9e8f", "teal"), ("#6e7480", "graphite")] {
                let option = Settings.accentOptions.first { $0.id == id }!
                let colours = Settings.accentColours(for: hex.uppercased())
                Check.equal(colours.light, option.hex)
                Check.equal(colours.dark, option.darkHex)
            }
            let custom = Settings.accentColours(for: "#abc")
            Check.equal(custom.light, "#abc")
            Check.equal(custom.dark, "#abc")
        }
    }

    Check.suite("Menu key equivalents") {

        func check(_ binding: String, _ key: String, _ modifiers: Set<Settings.Modifier>) {
            let combo = Settings.menuKeyEquivalent(for: binding)
            Check.equal(combo?.key, key)
            Check.equal(combo?.modifiers, modifiers)
        }

        // The File menu reads these from the same table the Shortcuts tab records into, so a
        // rebound New Note moves the menu's key with it. They used to be literals in AppDelegate,
        // which made ⌘N and ⌘P the two rebindable actions that could not be rebound.
        Check.test("plain command") { check("Mod-n", "n", [.command]) }
        Check.test("shift and command") { check("Shift-Mod-p", "p", [.command, .shift]) }
        Check.test("control alone") { check("Ctrl-x", "x", [.control]) }
        Check.test("option and command") { check("Alt-Mod-,", ",", [.option, .command]) }
        Check.test("punctuation key") { check("Shift-Mod-/", "/", [.command, .shift]) }
        Check.test("bracket key") { check("Mod-[", "[", [.command]) }

        // Anything it cannot express returns nil, and the item drops its key rather than
        // advertising one that is not what the editor is bound to.
        Check.test("named keys are declined") {
            Check.equal(Settings.menuKeyEquivalent(for: "Mod-Enter") == nil, true)
        }
        Check.test("an empty binding is declined") {
            Check.equal(Settings.menuKeyEquivalent(for: "") == nil, true)
        }
        Check.test("an unknown modifier is declined") {
            Check.equal(Settings.menuKeyEquivalent(for: "Hyper-n") == nil, true)
        }

        // Every shipped default has to survive the round trip, or a menu item silently loses its key.
        // `allShortcuts`, not `shortcutActions`: the File menu carries New Note and Browse Notes,
        // and both are fixed rather than recordable — which table a key lives in has nothing to do
        // with whether a menu item can express it.
        Check.test("every shipped binding is expressible") {
            for action in Settings.allShortcuts {
                Check.equal(
                    Settings.menuKeyEquivalent(for: action.standard) != nil,
                    true,
                    "\(action.key) → \(action.standard)"
                )
            }
        }

        // The two tables must not overlap, and between them must bind every action the app runs.
        // A key in both would take a recorder row *and* be documented as fixed; a key in neither
        // would be an action with no shipped binding, which decision 31 calls a worse lie than an
        // absent row.
        Check.test("no action is in both tables") {
            let recordable = Set(Settings.shortcutActions.map(\.key))
            let fixed = Set(Settings.fixedShortcuts.map(\.key))
            Check.equal(recordable.intersection(fixed).isEmpty, true)
        }
        Check.test("every action resolves to a binding") {
            for action in Settings.allShortcuts {
                Check.equal(Settings.standardShortcuts[action.key]?.isEmpty == false, true, action.key)
            }
        }
    }

    Check.suite("Keep on top setting") {
        func decode(_ json: String) -> Settings? {
            try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }

        Check.test("off by default, including for settings files that predate it") {
            Check.equal(Settings().keepOnTop, false)
            Check.equal(decode("{}")?.keepOnTop, false)
        }

        Check.test("the choice survives a round trip") {
            var settings = Settings()
            settings.keepOnTop = true
            let data = try? JSONEncoder().encode(settings)
            let back = data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            Check.equal(back?.keepOnTop, true)
        }
    }

    Check.suite("Space assignment setting") {
        func decode(_ json: String) -> Settings? {
            try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }

        Check.test("unassigned by default, including for settings files that predate it") {
            Check.equal(Settings().spaceAssignment, .unassigned)
            Check.equal(decode("{}")?.spaceAssignment, .unassigned)
            Check.equal(decode("{}")?.assignedSpace, nil)
        }

        Check.test("the old every-Space Bool reads as All Desktops or None") {
            Check.equal(decode(#"{"showOnEverySpace": true}"#)?.spaceAssignment, .everySpace)
            Check.equal(decode(#"{"showOnEverySpace": false}"#)?.spaceAssignment, .unassigned)
        }

        Check.test("the new key wins over the old one") {
            let json = #"{"showOnEverySpace": true, "spaceAssignment": "unassigned"}"#
            Check.equal(decode(json)?.spaceAssignment, .unassigned)
        }

        Check.test("one desktop survives a round trip with its Space") {
            var settings = Settings()
            settings.spaceAssignment = .oneSpace
            settings.assignedSpace = "53C42C34-D8AE-423A-A0DE-6688E8B3A4B7"
            let data = try? JSONEncoder().encode(settings)
            let back = data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            Check.equal(back?.spaceAssignment, .oneSpace)
            Check.equal(back?.assignedSpace, "53C42C34-D8AE-423A-A0DE-6688E8B3A4B7")
            Check.equal(String(data: data ?? Data(), encoding: .utf8)?.contains("showOnEverySpace"), false)
        }

        Check.test("one desktop with no Space to keep to reads as None") {
            Check.equal(decode(#"{"spaceAssignment": "oneSpace"}"#)?.spaceAssignment, .unassigned)
            Check.equal(decode(#"{"spaceAssignment": "oneSpace", "assignedSpace": ""}"#)?.spaceAssignment, .unassigned)
        }

        Check.test("a Space is only kept alongside one desktop") {
            let json = #"{"spaceAssignment": "everySpace", "assignedSpace": "53C42C34"}"#
            Check.equal(decode(json)?.assignedSpace, nil)
        }

        Check.test("an unknown value costs the field, not the file") {
            Check.equal(decode(#"{"spaceAssignment": "somewhere", "keepOnTop": true}"#)?.spaceAssignment, .unassigned)
            Check.equal(decode(#"{"spaceAssignment": "somewhere", "keepOnTop": true}"#)?.keepOnTop, true)
        }
    }

    Check.suite("Panel opacity setting") {
        func decode(_ json: String) -> Settings? {
            try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }

        Check.test("old translucency choices retain their appearance") {
            Check.equal(decode("{}")?.panelOpacity, Settings.defaultPanelOpacity)
            Check.equal(decode(#"{"translucentPanes":true}"#)?.panelOpacity, 0.75)
            Check.equal(decode(#"{"translucentPanes":false}"#)?.panelOpacity, 1)
        }

        Check.test("opacity takes precedence over the old switch") {
            Check.equal(decode(#"{"translucentPanes":false,"panelOpacity":0.6}"#)?.panelOpacity, 0.6)
        }

        Check.test("clamps hand-edited opacity without losing other settings") {
            Check.equal(decode(#"{"panelOpacity":-1,"textSize":21}"#)?.panelOpacity, 0.5)
            Check.equal(decode(#"{"panelOpacity":0.2}"#)?.panelOpacity, 0.5)
            let high = decode(#"{"panelOpacity":2,"textSize":21}"#)
            Check.equal(high?.panelOpacity, 1)
            Check.equal(high?.textSize, 21)
        }

        Check.test("transparency survives saving and reopening at both ends and in between") {
            for opacity in [0.5, 0.6, Settings.defaultPanelOpacity, 1.0] {
                let settings = Settings(panelOpacity: opacity)
                let data = try! JSONEncoder().encode(settings)
                Check.equal(try! JSONDecoder().decode(Settings.self, from: data).panelOpacity, opacity)
                let file = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                Check.expect(file["translucentPanes"] == nil, "save only the new setting")
            }
        }
    }

    Check.suite("Panel transparency slider") {
        Check.test("the default is fully opaque, the slider's zero") {
            Check.equal(Settings.defaultPanelOpacity, 1)
            Check.equal(Settings.transparencySliderValue(forOpacity: Settings.defaultPanelOpacity), 0)
        }

        Check.test("the slider's ends are the ends of the opacity range") {
            Check.equal(Settings.transparencySliderValue(forOpacity: 1), 0)
            Check.equal(Settings.transparencySliderValue(forOpacity: 0.5), 100)
            Check.equal(Settings.opacity(forTransparencySliderValue: 0), 1)
            Check.equal(Settings.opacity(forTransparencySliderValue: 100), 0.5)
        }

        Check.test("every whole slider position survives the round trip") {
            for position in 0...100 {
                let opacity = Settings.opacity(forTransparencySliderValue: Double(position))
                Check.equal(Settings.transparencySliderValue(forOpacity: opacity).rounded(), Double(position))
            }
        }
    }

    Check.suite("Footer count setting") {

        func decode(_ json: String) -> Settings? {
            try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }

        Check.test("round-trips through the file") {
            for count in Settings.FooterCount.allCases {
                var settings = Settings()
                settings.footerCount = count
                let data = try! JSONEncoder().encode(settings)
                Check.equal(try! JSONDecoder().decode(Settings.self, from: data).footerCount, count)
            }
        }

        Check.test("an unknown value costs that field, not the file") {
            let s = decode(#"{"footerCount": "syllables", "textSize": 21}"#)
            Check.equal(s?.footerCount, .words)
            Check.equal(s?.textSize, 21)
        }

        Check.test("a file written before this setting existed counts words") {
            Check.equal(decode(#"{"textSize": 15}"#)?.footerCount, .words)
        }

        Check.test("the other one is the other one, both ways") {
            Check.equal(Settings.FooterCount.words.other, .characters)
            Check.equal(Settings.FooterCount.characters.other, .words)
        }
    }

    Check.suite("Switcher order setting") {

        func decode(_ json: String) -> Settings? {
            try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }

        Check.test("round-trips through the file") {
            for order in Settings.NoteOrder.allCases {
                var settings = Settings()
                settings.noteOrder = order
                let data = try! JSONEncoder().encode(settings)
                Check.equal(try! JSONDecoder().decode(Settings.self, from: data).noteOrder, order)
            }
        }

        Check.test("an unknown order costs that field, not the file") {
            // Decoded as a string and mapped for exactly this: `decodeIfPresent(NoteOrder.self,…)`
            // throws, and a throw here takes every other setting in the file down with it.
            let s = decode(#"{"noteOrder": "byVibes", "textSize": 21}"#)
            Check.equal(s?.noteOrder, .modified)
            Check.equal(s?.textSize, 21)
        }

        Check.test("a file written before this setting existed reads as the default") {
            Check.equal(decode(#"{"textSize": 15}"#)?.noteOrder, .modified)
        }

        Check.test("every mode has a label, and they are distinct") {
            let labels = Settings.NoteOrder.allCases.map(\.label)
            Check.equal(labels.allSatisfy { !$0.isEmpty }, true)
            Check.equal(Set(labels).count, labels.count)
        }
    }
}
