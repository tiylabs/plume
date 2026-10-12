import Foundation
import PlumeKit

// A diagnostic executable, so testing Dock assignments does not launch Plume or open a real note.
// Usage: swift run DockSpaceProbe [--bundle ID] [--watch] [--preferences PATH]
var bundleIdentifiers = [BuildProfile.release.bundleIdentifier, BuildProfile.scratch.bundleIdentifier]
var preferencesURL: URL?
var watch = false
var arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("Usage: swift run DockSpaceProbe [--bundle ID] [--watch] [--preferences PATH]")
    exit(2)
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--bundle":
        guard !arguments.isEmpty, !arguments[0].isEmpty, !arguments[0].hasPrefix("--") else { usage() }
        bundleIdentifiers = [arguments.removeFirst()]
    case "--preferences":
        guard !arguments.isEmpty, !arguments[0].hasPrefix("--") else { usage() }
        preferencesURL = URL(fileURLWithPath: arguments.removeFirst())
    case "--watch": watch = true
    default: usage()
    }
}

var previous: [String: DockSpaceAssignment] = [:]
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let timestamp = ISO8601DateFormatter()
var hasUnknown = false

repeat {
    hasUnknown = false
    for identifier in bundleIdentifiers {
        let reader = preferencesURL.map {
            DockSpaceAssignmentReader(bundleIdentifier: identifier, preferencesURL: $0)
        } ?? DockSpaceAssignmentReader(bundleIdentifier: identifier)
        let assignment = reader.read()
        if case .unknown = assignment { hasUnknown = true }
        if previous[identifier] != assignment {
            let row = [
                "checkedAt": timestamp.string(from: Date()),
                "bundleIdentifier": identifier,
                "assignment": assignment.diagnosticValue,
                "source": reader.preferencesURL.path,
            ]
            do {
                let data = try encoder.encode(row)
                FileHandle.standardOutput.write(data + Data([0x0a]))
            } catch {
                FileHandle.standardError.write(Data("Could not encode diagnostic output: \(error)\n".utf8))
                exit(2)
            }
            previous[identifier] = assignment
        }
    }
    if watch { Thread.sleep(forTimeInterval: 2) }
} while watch

exit(hasUnknown ? 1 : 0)
