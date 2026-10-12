#!/usr/bin/env swift
import AppKit
import Foundation

// A shared process name is not an identity. Restrict rebuilds to this checkout's dev bundle,
// with a legacy scratch exception so the first rebuild can retire the old build/Plume.app safely.
func isDevelopmentInstance(
    path: String, identifier: String?, scratchFlag: Bool, developmentPath: String, legacyPath: String
) -> Bool {
    if path == developmentPath { return identifier == "com.tiylabs.plume.dev" }
    return path == legacyPath && identifier == "com.tiylabs.plume" && scratchFlag
}

func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--test" {
    let development = "/checkout/build/Plume Dev.app"
    let legacy = "/checkout/build/Plume.app"
    let cases: [(String, String?, Bool, Bool)] = [
        (development, "com.tiylabs.plume.dev", true, true),
        (development, "com.tiylabs.plume", false, false),
        ("/Applications/Plume.app", "com.tiylabs.plume", false, false),
        ("/other/build/Plume Dev.app", "com.tiylabs.plume.dev", true, false),
        (legacy, "com.tiylabs.plume", true, true),
        (legacy, "com.tiylabs.plume", false, false),
        (legacy, nil, true, false),
    ]
    for (path, identifier, scratch, expected) in cases {
        guard isDevelopmentInstance(
            path: path, identifier: identifier, scratchFlag: scratch,
            developmentPath: development, legacyPath: legacy
        ) == expected else { fail("unsafe development instance selection: \(path)") }
    }
    print("✓ development restart selects only this checkout's dev or legacy scratch instance")
    exit(0)
}

guard arguments.count == 4, ["stop", "inspect"].contains(arguments[1]) else {
    fail("usage: swift Scripts/dev-app.swift stop|inspect <Plume Dev.app> <legacy Plume.app>")
}
let developmentPath = canonicalPath(URL(fileURLWithPath: arguments[2]))
let legacyPath = canonicalPath(URL(fileURLWithPath: arguments[3]))
let applications = NSWorkspace.shared.runningApplications.filter { application in
    guard let url = application.bundleURL else { return false }
    let scratch = Bundle(url: url)?.object(forInfoDictionaryKey: "PlumeScratchBuild") as? Bool ?? false
    return isDevelopmentInstance(
        path: canonicalPath(url), identifier: application.bundleIdentifier, scratchFlag: scratch,
        developmentPath: developmentPath, legacyPath: legacyPath
    )
}
for application in applications {
    print("\(arguments[1]): \(application.bundleURL?.path ?? "") (pid \(application.processIdentifier))")
    if arguments[1] == "stop", !application.terminate() {
        fail("development app refused to quit; leaving its bundle and every release instance alone")
    }
}
if arguments[1] == "stop" {
    // Normal AppKit termination runs the note flush and drains the vault queue. Never force-kill.
    let deadline = Date().addingTimeInterval(10)
    while applications.contains(where: { !$0.isTerminated }) {
        guard Date() < deadline else {
            fail("development app did not quit within 10 seconds; rebuild aborted without force-killing")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
