import AppKit

extension NSImage {
    /// A disc that empties clockwise from 12 o'clock as `fraction` falls from 1 to 0. The elapsed part
    /// stays faintly visible so the icon can still be found. Being a template, macOS tints it to suit
    /// the menu bar: white on a dark one, black on a light one.
    static func depletingCircle(_ fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            let disc = bounds.insetBy(dx: 1, dy: 1)
            NSColor(white: 0, alpha: 0.25).setFill()
            NSBezierPath(ovalIn: disc).fill()
            NSColor.black.setFill()
            if fraction >= 1 {
                NSBezierPath(ovalIn: disc).fill()
            } else if fraction > 0 {
                // Angles run counterclockwise from 3 o'clock, so sweeping counterclockwise from 12
                // leaves the elapsed part as a gap that grows clockwise.
                let center = NSPoint(x: disc.midX, y: disc.midY)
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(
                    withCenter: center, radius: disc.width / 2,
                    startAngle: 90, endAngle: 90 + 360 * fraction, clockwise: false
                )
                wedge.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
