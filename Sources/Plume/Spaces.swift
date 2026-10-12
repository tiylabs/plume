import AppKit

/// Which desktop is which — read from SkyLight, because macOS has no public API for any of it.
///
/// `Settings.SpaceAssignment.oneSpace` needs three answers AppKit cannot give: the desktop being
/// looked at, the desktop the panel is on, and whether a desktop chosen yesterday still exists.
/// `NSWindow.isOnActiveSpace` is the only public fact in this area, and it cannot name a desktop.
///
/// **Read-only, and every answer optional.** The symbols are looked up at runtime, so a release that
/// renames or removes them costs the feature — `oneSpace` reads as `unassigned` and the notice loses
/// its number — rather than the launch. The same bargain the glass's `_variant` makes. Nothing here
/// moves a window: placing the panel is still `orderOut` and an order back in, which AppKit owns.
///
/// Numbered the way Mission Control labels them: desktops only, fullscreen apps skipped, counted
/// from 1 along each display's row.
@MainActor
enum Spaces {

    struct Desktop: Equatable {
        /// The UUID macOS files Dock bindings under, and the one `Settings.assignedSpace` holds.
        let uuid: String
        /// "Desktop 3" in Mission Control.
        let number: Int
    }

    /// Whether the symbols resolved. When they did not, `oneSpace` is not offered.
    static var isAvailable: Bool { functions != nil }

    /// The desktop being looked at: on the display under the pointer, which is where a summon puts
    /// the panel, when each display has its own Spaces.
    static func active() -> Desktop? {
        guard let functions else { return nil }
        let displays = managedDisplays(functions)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
        let identifier = screen.flatMap(displayIdentifier)
        let display = displays.first { ($0["Display Identifier"] as? String) == identifier }
            ?? (displays.count == 1 ? displays.first : nil)
        let current = (display?["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            ?? Int(functions.activeSpace(functions.connection))
        return desktop(id: current, in: displays)
    }

    /// The desktop a window is on. Nil for a window on every Space, which has no one answer.
    static func of(windowNumber: Int) -> Desktop? {
        guard let functions,
              let ids = functions.spacesForWindows(functions.connection, 7, [windowNumber] as CFArray)?
                .takeRetainedValue() as? [Int],
              ids.count == 1
        else { return nil }
        return desktop(id: ids[0], in: managedDisplays(functions))
    }

    /// The desktop with this UUID, if it still exists — and its number now, which moves when the
    /// desktops before it are removed or reordered.
    static func desktop(uuid: String) -> Desktop? {
        guard let functions else { return nil }
        return numbered(managedDisplays(functions)).first { $0.desktop.uuid == uuid }?.desktop
    }

    /// Whether a desktop is known to be gone. False when SkyLight cannot say, so a lookup that failed
    /// is never mistaken for a desktop that was removed — which would quietly drop the setting.
    static func isGone(_ uuid: String) -> Bool {
        guard let functions else { return false }
        let all = numbered(managedDisplays(functions))
        return !all.isEmpty && !all.contains { $0.desktop.uuid == uuid }
    }

    // MARK: - SkyLight

    private struct Functions {
        let connection: Int32
        let activeSpace: @convention(c) (Int32) -> UInt64
        let managedDisplaySpaces: @convention(c) (Int32) -> Unmanaged<CFArray>?
        let spacesForWindows: @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    }

    private static let functions: Functions? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(skyLight, name).map { unsafeBitCast($0, to: type) }
        }
        guard let mainConnection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let activeSpace = symbol("SLSGetActiveSpace", as: (@convention(c) (Int32) -> UInt64).self),
              let displays = symbol(
                  "SLSCopyManagedDisplaySpaces", as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self
              ),
              let spaces = symbol(
                  "SLSCopySpacesForWindows",
                  as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self
              )
        else { return nil }
        return Functions(
            connection: mainConnection(),
            activeSpace: activeSpace,
            managedDisplaySpaces: displays,
            spacesForWindows: spaces
        )
    }()

    private static func managedDisplays(_ functions: Functions) -> [[String: Any]] {
        functions.managedDisplaySpaces(functions.connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// Every desktop, numbered along its display's row, with SkyLight's ID for it.
    private static func numbered(_ displays: [[String: Any]]) -> [(desktop: Desktop, id: Int)] {
        displays.flatMap { display -> [(desktop: Desktop, id: Int)] in
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }
            return spaces.enumerated().compactMap { index, space in
                guard let id = space["ManagedSpaceID"] as? Int else { return nil }
                // The first desktop of a fresh account can carry an empty UUID; the ID is the only
                // name it has, and it is stable for as long as the desktop is.
                let uuid = (space["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "id:\(id)"
                return (Desktop(uuid: uuid, number: index + 1), id)
            }
        }
    }

    private static func desktop(id: Int, in displays: [[String: Any]]) -> Desktop? {
        numbered(displays).first { $0.id == id }?.desktop
    }

    /// SkyLight names a display by the UUID string of its `CGDirectDisplayID`.
    private static func displayIdentifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
