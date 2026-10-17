import AppKit

/// The Model Context Protocol mark, for the MCP tab's toolbar button.
///
/// SF Symbols has no MCP glyph, and the tab should carry the mark people see on their agent's MCP
/// settings, so it is drawn here from the three strokes of the official logo
/// (`modelcontextprotocol/modelcontextprotocol`, `docs/logo/light.svg`, the part left of the
/// wordmark), coordinates unchanged. Drawn rather than shipped as an image file: it stays sharp at
/// any scale, and as a template image it takes the toolbar's own tint — grey, and the accent
/// colour when selected — exactly like the SF Symbols on the other five tabs.
enum MCPMark {

    /// The logo's strokes, in the SVG's own coordinate space (y down).
    private static func strokes() -> NSBezierPath {
        let path = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

        path.move(to: p(25, 97.8528))
        path.line(to: p(92.8822, 29.9706))
        path.curve(to: p(126.823, 29.9706), controlPoint1: p(102.255, 20.598), controlPoint2: p(117.451, 20.598))
        path.curve(to: p(126.823, 63.9117), controlPoint1: p(136.196, 39.3431), controlPoint2: p(136.196, 54.5391))
        path.line(to: p(75.5581, 115.177))

        path.move(to: p(76.2652, 114.47))
        path.line(to: p(126.823, 63.9117))
        path.curve(to: p(160.765, 63.9117), controlPoint1: p(136.196, 54.5391), controlPoint2: p(151.392, 54.5391))
        path.line(to: p(161.118, 64.2652))
        path.curve(to: p(161.118, 98.2063), controlPoint1: p(170.491, 73.6378), controlPoint2: p(170.491, 88.8338))
        path.line(to: p(99.7248, 159.6))
        path.curve(to: p(99.7248, 170.913), controlPoint1: p(96.6006, 162.724), controlPoint2: p(96.6006, 167.789))
        path.line(to: p(112.331, 183.52))

        path.move(to: p(109.853, 46.9411))
        path.line(to: p(59.6482, 97.1457))
        path.curve(to: p(59.6482, 131.087), controlPoint1: p(50.2756, 106.518), controlPoint2: p(50.2756, 121.714))
        path.curve(to: p(93.5893, 131.087), controlPoint1: p(69.0208, 140.459), controlPoint2: p(84.2167, 140.459))
        path.line(to: p(143.794, 80.8822))
        return path
    }

    /// The strokes' extent with their 12-unit width and round caps, measured from the paths above.
    private static let artBox = NSRect(x: 18, y: 16, width: 158, height: 175)
    private static let artStroke: CGFloat = 12

    /// How much of the image the strokes fill; the rest is margin.
    ///
    /// The preference toolbar scales a plain image to its full button height, while an SF Symbol
    /// keeps the optical margin its design carries. Filling the box therefore drew the mark half as
    /// big again as its neighbours: measured in a 2x screenshot, 58 px of ink against 41 for
    /// `gearshape` and 39 for `info.circle`. 0.7 still left it 22 px tall at 1x against the gear's
    /// 20; at 0.64 it matches the gear's height.
    private static let inkFraction: CGFloat = 0.64

    /// A square template image with a stroke close to the SF Symbols' regular weight.
    static func image(side: CGFloat = 17, accessibilityDescription: String?) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let scale = min(rect.width / artBox.width, rect.height / artBox.height) * inkFraction
            let drawn = NSSize(width: artBox.width * scale, height: artBox.height * scale)
            let transform = NSAffineTransform()
            transform.translateX(by: (rect.width - drawn.width) / 2, yBy: (rect.height - drawn.height) / 2)
            transform.scale(by: scale)
            transform.translateX(by: -artBox.minX, yBy: -artBox.minY)
            let path = transform.transform(strokes())
            // The logo's 12 units scale to under a point here, thinner than the symbols beside it,
            // so the stroke has a floor. In image points: the toolbar scales the image up, and 1.0
            // comes out at about the symbols' regular weight there.
            path.lineWidth = max(artStroke * scale, 1.0)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
