import CoreGraphics
import Foundation
import PlumeKit

/// The bridge between Swift and the page, checked from both ends.
///
/// The two sides are written in different languages and nothing compiles one against the other, so a
/// message the page stops sending, or a method Swift calls that the page no longer has, would be a
/// silent no-op in a web view. These tests read `Editor/src/bridge/protocol.ts` as text — the same
/// approach `LocalizationTests` takes to the catalogs — and fail when it and PlumeKit disagree:
///
///   page → Swift   `OutboundMessage` in protocol.ts      ⇄   `BridgeMessage` (names and fields)
///   Swift → page   `HostAPI` in protocol.ts              ⇄   `EditorCommand` (names and argument counts)
///
/// The repository root is found from this file's own path, as `CompatibilityTests` finds its fixtures.
private let protocolSource: String? = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent("Editor/src/bridge/protocol.ts"), encoding: .utf8)
}()

/// The text between `start` and the first line that is exactly `end`.
private func section(_ source: String, from start: String, until end: String = "\n;") -> String {
    guard let lower = source.range(of: start) else { return "" }
    let rest = source[lower.upperBound...]
    guard let upper = rest.range(of: end) else { return String(rest) }
    return String(rest[..<upper.lowerBound])
}

private func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
        (0..<match.numberOfRanges).map { i in
            match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i))
        }
    }
}

/// `{ type: "edited"; text: string; caret: number }` → ("edited", ["text", "caret"]).
private func outboundMessages(_ source: String) -> [String: [String]] {
    let union = section(source, from: "export type OutboundMessage =", until: "\n\n")
    var result: [String: [String]] = [:]
    for m in matches(#"\{\s*type:\s*"(\w+)"([^}]*)\}"#, in: union) {
        let fields = matches(#"(\w+)\??:"#, in: m[2]).map { $0[1] }
        result[m[1]] = fields
    }
    return result
}

/// `loadNote(filename: string, text: string, caret: number, pinned: boolean): void;` → ("loadNote", 4).
private func hostMethods(_ source: String) -> [String: Int] {
    let body = section(source, from: "export interface HostAPI {", until: "\n}")
    var result: [String: Int] = [:]
    for m in matches(#"^  (\w+)\(([^)]*)\):\s*void;"#, in: body) {
        let params = m[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result[m[1]] = params.count
    }
    return result
}

func runBridgeContractTests() {
    guard let source = protocolSource else {
        Check.suite("Bridge contract") {
            Check.test("protocol.ts is found") { Check.expect(false, "Editor/src/bridge/protocol.ts not found beside the checkout") }
        }
        return
    }
    let outbound = outboundMessages(source)
    let host = hostMethods(source)

    Check.suite("Bridge contract") {

        Check.test("the TypeScript protocol was actually parsed") {
            Check.expect(outbound.count >= 31, "found only \(outbound.count) message types")
            Check.expect(host.count >= 23, "found only \(host.count) host methods")
        }

        Check.test("page → Swift: BridgeMessage decodes exactly the messages the page can send") {
            let swift = BridgeMessage.knownTypes
            let page = Set(outbound.keys)
            Check.equal(swift.subtracting(page), [], "Swift decodes types the page never sends")
            Check.equal(page.subtracting(swift), [], "the page sends types Swift does not decode")
        }

        Check.test("page → Swift: every message the page can send decodes to its own case") {
            for (type, fields) in outbound.sorted(by: { $0.key < $1.key }) {
                var body: [String: Any] = ["type": type]
                for field in fields { body[field] = sample(for: field) }
                guard let message = BridgeMessage(body: body) else {
                    Check.expect(false, "\(type) did not decode"); continue
                }
                Check.equal(message.kind.rawValue, type, "\(type) decoded to the wrong case")
            }
        }

        Check.test("page → Swift: every field the page sends is read, under the name the page uses") {
            for (type, fields) in outbound.sorted(by: { $0.key < $1.key }) {
                guard let blank = BridgeMessage(body: ["type": type]) else {
                    Check.expect(false, "\(type) did not decode with no fields"); continue
                }
                // One field at a time, so a misspelled field cannot hide behind a correct one. Each
                // sample differs from what a missing field decodes to; if the decoded message is
                // still the blank one, the Swift side never looked at that key.
                for field in fields {
                    let with = BridgeMessage(body: ["type": type, field: sample(for: field)])
                    Check.expect(with != nil && with != blank,
                                 "\(type).\(field) is sent by the page but ignored by BridgeMessage")
                }
            }
        }

        Check.test("page → Swift: an unknown or malformed message is dropped, not guessed at") {
            Check.expect(BridgeMessage(body: ["type": "nope"]) == nil)
            Check.expect(BridgeMessage(body: ["text": "x"]) == nil)
            Check.expect(BridgeMessage(body: "edited") == nil)
            Check.expect(BridgeMessage(body: 3) == nil)
            Check.expect(BridgeMessage(body: [Any]()) == nil)
        }

        Check.test("page → Swift: missing fields read as their zero value, as they always did") {
            Check.equal(BridgeMessage(body: ["type": "edited"]), .edited(text: "", caret: 0))
            Check.equal(BridgeMessage(body: ["type": "navigate"]), .navigate(back: true), "the one default that is not zero")
            Check.equal(BridgeMessage(body: ["type": "togglePin"]), .togglePin(filename: nil))
            Check.equal(BridgeMessage(body: ["type": "switcherOpen", "height": "tall"]),
                        .switcherOpen(open: false, height: 0), "a wrong-typed field is a zero, not a dropped message")
        }

        Check.test("page → Swift: rectangles, lists of rectangles and nulls decode") {
            let rect: [String: Any] = ["x": 1, "y": 2, "width": 30.5, "height": 4]
            let drag = BridgeMessage(body: ["type": "dragRegions", "titleBar": rect, "exclusions": [rect, rect], "close": rect])
            let expected = CGRect(x: 1, y: 2, width: 30.5, height: 4)
            Check.equal(drag, .dragRegions(titleBar: expected, exclusions: [expected, expected], close: expected))
            Check.equal(BridgeMessage(body: ["type": "headingMenu", "button": rect, "level": NSNull()]),
                        .headingMenu(button: expected, level: nil))
            Check.equal(BridgeMessage(body: ["type": "headingMenu", "button": rect, "level": 2]),
                        .headingMenu(button: expected, level: 2))
        }

        Check.test("page → Swift: the same bytes the page produces decode, via JSON") {
            let json = #"{"type":"edited","text":"a `b` </script>\n","caret":7}"#
            let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
            Check.equal(BridgeMessage(body: object), .edited(text: "a `b` </script>\n", caret: 7))
        }

        Check.test("Swift → page: EditorCommand has a case for every HostAPI method, and no others") {
            let swift = EditorCommand.allMethods
            let page = Set(host.keys)
            Check.equal(swift.subtracting(page), [], "Swift calls methods the page does not have")
            Check.equal(page.subtracting(swift), [], "the page has methods Swift has no command for")
        }

        Check.test("Swift → page: each command passes the argument count the page declares") {
            for command in EditorCommand.samples {
                let declared = host[command.method]
                let passed = command.encodedArguments().count
                switch command {
                case .showToast:
                    // `dwell?` is optional in TypeScript: one or two arguments are both fine.
                    Check.expect(passed == 1 || passed == 2, "showToast passed \(passed)")
                    Check.equal(declared, 2)
                default:
                    Check.equal(passed, declared, "\(command.method): Swift passes \(passed), the page takes \(declared ?? -1)")
                }
            }
        }

        Check.test("Swift → page: a command is one well-formed call on window.plumeHost") {
            let script = EditorCommand.loadNote(filename: "a.md", text: "x", caret: 3, pinned: true).script
            Check.equal(script, #"window.plumeHost && window.plumeHost.loadNote("a.md", "x", 3, true);"#)
            Check.equal(EditorCommand.openSwitcher.script, "window.plumeHost && window.plumeHost.openSwitcher();")
        }

        Check.test("Swift → page: text that would break a JavaScript string is encoded, never interpolated") {
            let nasty = "line1\nline2 `tick` \"quote\" \\ back </script> \u{2028} \u{1F600}"
            let args = EditorCommand.showToast(nasty).encodedArguments()
            guard let literal = args.first, let data = literal.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
            else { Check.expect(false, "not valid JSON: \(args)"); return }
            Check.equal(decoded, nasty, "the argument survives a round trip")
            Check.expect(!literal.contains("\n"), "no raw newline reaches the script")
            Check.expect(!literal.contains("</script>"), "</script> is escaped")
        }

        Check.test("Swift → page: absent values cross as null, and switcher rows as the objects the page reads") {
            Check.equal(EditorCommand.setSpaceAssignment(mode: "oneSpace", desktop: nil, canKeepToOne: true).encodedArguments(),
                        [#""oneSpace""#, "null", "true"])
            Check.equal(EditorCommand.setSpaceAssignment(mode: "oneSpace", desktop: 2, canKeepToOne: true).encodedArguments()[1], "2")
            let row = SwitcherRow(filename: "a.md", title: "A", time: "now", preview: "p", pinned: true)
            let args = EditorCommand.showNotes([row], total: 9, query: "q").encodedArguments()
            Check.equal(args.count, 3)
            Check.expect(args[0].contains(#""filename":"a.md""#) && args[0].contains(#""pinned":true"#))
            Check.equal(args[1], "9")
            Check.equal(args[2], #""q""#)
            Check.expect(!args[0].contains("band"), "an absent optional is omitted, not null")
        }

        Check.test("Swift → page: applySettings carries exactly the keys the page reads") {
            let payload = PanelSettingsPayload(
                appearance: "dark", accent: "#fff", accentDark: "#000", textSize: 16, footerCount: "words",
                panelOpacity: 0.5, glass: true, shortcuts: ["a": "b"], themeCSS: "x{}", language: "en"
            )
            guard let json = EditorCommand.applySettings(payload).encodedArguments().first,
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            else { Check.expect(false, "applySettings did not encode an object"); return }
            let declared = Set(matches(#"^  (\w+)\?:"#, in: section(source, from: "export interface PanelSettings {", until: "\n}")).map { $0[1] })
            Check.equal(Set(object.keys), declared, "PanelSettingsPayload and PanelSettings disagree")
        }
    }
}

/// A JSON value of a type that suits the field's name, and different from what a missing field
/// decodes to: `true` where the zero value is false, `false` where the default is true.
private func sample(for field: String) -> Any {
    switch field {
    case "caret", "scrollLine", "height", "level": return 7
    case "open": return true
    case "back": return false
    case "titleBar", "close", "button": return ["x": 1, "y": 2, "width": 3, "height": 4]
    case "exclusions": return [["x": 1, "y": 2, "width": 3, "height": 4]]
    case "action": return "in"
    default: return "value-of-\(field)"
    }
}
