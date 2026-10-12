import Foundation
import PlumeKit

func runDockSpaceAssignmentTests() {
    Check.suite("Effective Space assignment policy") {
        let systemUUID = "53C42C34-D8AE-423A-A0DE-6688E8B3A4B7"
        Check.test("Dock desktop removes Plume's all-Space behaviour") {
            let settings = Settings(spaceAssignment: .everySpace)
            let policy = SpaceAssignmentPolicy.resolve(settings: settings, dock: .oneSpace(uuid: systemUUID))
            Check.equal(policy.mode, .oneSpace)
            Check.equal(policy.showsOnEverySpace, false)
            Check.equal(policy.desktopUUID, systemUUID)
            Check.equal(policy.isSystemManaged, true)
            Check.equal(settings.spaceAssignment, .everySpace)
        }
        Check.test("explicit Dock choices override every Plume choice") {
            for mode in Settings.SpaceAssignment.allCases {
                let settings = Settings(spaceAssignment: mode, assignedSpace: "plume-desktop")
                let one = SpaceAssignmentPolicy.resolve(settings: settings, dock: .oneSpace(uuid: systemUUID))
                Check.equal(one.desktopUUID, systemUUID)
                Check.equal(one.showsOnEverySpace, false)
                let all = SpaceAssignmentPolicy.resolve(settings: settings, dock: .everySpace)
                Check.equal(all.mode, .everySpace)
                Check.equal(all.showsOnEverySpace, true)
                Check.equal(all.desktopUUID, nil)
            }
        }
        Check.test("read failures preserve the last confirmed system policy") {
            let settings = Settings(spaceAssignment: .everySpace)
            let one = SpaceAssignmentPolicy.resolve(settings: settings, dock: .oneSpace(uuid: systemUUID))
            for reason in [DockSpaceAssignment.UnknownReason.preferencesUnreadable, .bindingsUnavailable, .invalidPropertyList] {
                let next = SpaceAssignmentPolicy.resolve(settings: settings, dock: .unknown(reason), previous: one)
                Check.equal(next, one)
                Check.equal(next.showsOnEverySpace, false)
            }
        }
        Check.test("confirmed cancellation restores saved Plume behaviour") {
            for mode in Settings.SpaceAssignment.allCases {
                let settings = Settings(spaceAssignment: mode, assignedSpace: "plume-desktop")
                let one = SpaceAssignmentPolicy.resolve(settings: settings, dock: .oneSpace(uuid: systemUUID))
                let restored = SpaceAssignmentPolicy.resolve(settings: settings, dock: .unassigned, previous: one)
                Check.equal(restored.mode, mode)
                Check.equal(restored.isSystemManaged, false)
                Check.equal(restored.desktopUUID, mode == .oneSpace ? "plume-desktop" : nil)
            }
        }
        Check.test("without a confirmed system policy unknown retains Plume preference") {
            let settings = Settings(spaceAssignment: .everySpace)
            let policy = SpaceAssignmentPolicy.resolve(settings: settings, dock: .unknown(.notReadYet))
            Check.equal(policy.showsOnEverySpace, true)
            Check.equal(policy.isSystemManaged, false)
        }
    }

    Check.suite("Dock Space assignment detection") {
        let bundle = "com.tiylabs.plume.dev"
        let uuid = "53C42C34-D8AE-423A-A0DE-6688E8B3A4B7"

        Check.test("recognises the observed AllSpaces and UUID formats") {
            Check.equal(DockSpaceAssignment.parse(
                propertyList: ["app-bindings": [bundle: "AllSpaces"]], bundleIdentifier: bundle
            ), .everySpace)
            Check.equal(DockSpaceAssignment.parse(
                propertyList: ["app-bindings": [bundle: uuid.lowercased()]], bundleIdentifier: bundle
            ), .oneSpace(uuid: uuid))
        }

        Check.test("absence is None only inside a valid bindings table") {
            Check.equal(DockSpaceAssignment.parse(
                propertyList: ["app-bindings": [String: String]()], bundleIdentifier: bundle
            ), .unassigned)
            for preferences: [String: Any] in [[:], ["app-bindings": []], ["workspaces-app-bindings": [bundle: uuid]]] {
                Check.equal(DockSpaceAssignment.parse(
                    propertyList: preferences, bundleIdentifier: bundle
                ), .unknown(.bindingsUnavailable))
            }
        }

        Check.test("development and release bindings are independent") {
            let preferences = ["app-bindings": [bundle: "AllSpaces", "com.tiylabs.plume": uuid]]
            Check.equal(DockSpaceAssignment.parse(propertyList: preferences, bundleIdentifier: bundle), .everySpace)
            Check.equal(DockSpaceAssignment.parse(
                propertyList: preferences, bundleIdentifier: "com.tiylabs.plume"
            ), .oneSpace(uuid: uuid))
            Check.equal(DockSpaceAssignment.parse(
                propertyList: preferences, bundleIdentifier: "com.tiylabs.other"
            ), .unassigned)
        }

        Check.test("unknown values never masquerade as None or a desktop") {
            for value: Any in ["", "None", "allspaces", "id:7", "not-a-uuid", 7, true, ["uuid": uuid]] {
                Check.equal(DockSpaceAssignment.parse(
                    propertyList: ["app-bindings": [bundle: value]], bundleIdentifier: bundle
                ), .unknown(.unrecognisedBinding))
            }
            Check.equal(DockSpaceAssignment.parse(propertyList: [], bundleIdentifier: bundle), .unknown(.invalidPropertyList))
            for identifier in [nil, ""] as [String?] {
                Check.equal(DockSpaceAssignment.parse(
                    propertyList: ["app-bindings": [bundle: uuid]], bundleIdentifier: identifier
                ), .unknown(.missingBundleIdentifier))
            }
        }

        Check.test("reader follows atomic replacements and never modifies preferences") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("com.apple.spaces.plist")
            let reader = DockSpaceAssignmentReader(bundleIdentifier: bundle, preferencesURL: url)
            Check.equal(reader.read(), .unknown(.preferencesUnreadable))
            Check.expect(!FileManager.default.fileExists(atPath: url.path))

            for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
                for (bindings, expected) in [
                    ([bundle: "AllSpaces"], DockSpaceAssignment.everySpace),
                    ([bundle: uuid], .oneSpace(uuid: uuid)),
                    ([:], .unassigned),
                ] {
                    let data = try! PropertyListSerialization.data(
                        fromPropertyList: ["app-bindings": bindings], format: format, options: 0
                    )
                    try! data.write(to: url, options: .atomic)
                    Check.equal(reader.read(), expected)
                    Check.equal(try! Data(contentsOf: url), data)
                }
            }
            try! Data("invalid plist".utf8).write(to: url, options: .atomic)
            Check.equal(reader.read(), .unknown(.invalidPropertyList))
            let unsupported = try! PropertyListSerialization.data(fromPropertyList: ["other": 1], format: .binary, options: 0)
            try! unsupported.write(to: url, options: .atomic)
            Check.equal(reader.read(), .unknown(.bindingsUnavailable))
        }
    }
}
