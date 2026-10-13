import AppKit
import PlumeKit

extension NSColor {
    /// `#rgb` or `#rrggbb`, which is what `Settings.accent` holds because the value's other consumer
    /// is CSS.
    convenience init?(hex: String) {
        var digits = Substring(hex)
        guard digits.first == "#" else { return nil }
        digits = digits.dropFirst()

        if digits.count == 3 {
            digits = Substring(digits.flatMap { [$0, $0] })
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }

        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
