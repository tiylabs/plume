import AppKit
import PlumeKit

extension Settings.Appearance {
    /// `nil` means "follow the system", which is what `NSWindow.appearance` does when unset.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
