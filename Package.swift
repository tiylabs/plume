// swift-tools-version:6.0
import PackageDescription

// Plume is built with SwiftPM rather than an Xcode project: the app is a single executable plus a
// web bundle, and `swift build` works with only the Command Line Tools installed. `Scripts/build-app.sh`
// assembles the .app around the binary.
//
// The split is deliberate. PlumeKit holds everything that is pure Foundation — filenames, hashing,
// the write model, the note session, the bridge message types, the vault watcher, state persistence,
// Git sync, geometry arithmetic, switcher ordering — so it can be unit-tested without a window server. Plume holds only what genuinely needs AppKit, WebKit
// or Carbon.
let package = Package(
    name: "Plume",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Plume", targets: ["Plume"]),
        .library(name: "PlumeKit", targets: ["PlumeKit"]),
        // The helper an agent starts (`plume-agent mcp`) or a shell runs (`plume-agent notes …`). It
        // ships inside Plume.app at Contents/MacOS/plume-agent and talks to the running app over a
        // local socket; it never touches the vault itself.
        .executable(name: "plume-agent", targets: ["PlumeAgentHelper"]),
    ],
    targets: [
        .target(name: "PlumeKit"),
        .executableTarget(name: "Plume", dependencies: ["PlumeKit"]),
        .executableTarget(name: "DockSpaceProbe", dependencies: ["PlumeKit"], path: "Sources/DockSpaceProbe"),

        // The helper is split so its logic can be tested: `PlumeAgent` holds the MCP server, the CLI
        // and the IPC client (Foundation only, like PlumeKit), and `PlumeAgentHelper` is the
        // three-line entry point. The MCP adapter lives here and never in PlumeKit, which the app and
        // the helper both link.
        .target(name: "PlumeAgent", dependencies: ["PlumeKit"]),
        .executableTarget(name: "PlumeAgentHelper", dependencies: ["PlumeAgent"]),

        // Not a .testTarget: neither XCTest nor swift-testing ships with the Command Line Tools, so
        // `swift test` cannot run without Xcode installed. The suite is an executable instead —
        // `Scripts/test.sh` — which runs anywhere `swift build` does.
        .executableTarget(
            name: "PlumeKitTests", dependencies: ["PlumeKit", "PlumeAgent"], path: "Tests/PlumeKitTests", exclude: ["Fixtures"]
        ),
    ]
)
