import AppKit

/// Template tombstone glyph for the menu bar: outlined when idle, filled with the prompt cut out when something listens.
enum MenuBarIcon {
    static let idle = make(filled: false)
    static let active = make(filled: true)

    private static func make(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let stone = NSBezierPath()
            stone.move(to: NSPoint(x: 3.5, y: 16))
            stone.line(to: NSPoint(x: 3.5, y: 8))
            stone.appendArc(withCenter: NSPoint(x: 9, y: 8), radius: 5.5, startAngle: 180, endAngle: 0, clockwise: false)
            stone.line(to: NSPoint(x: 14.5, y: 16))
            stone.close()

            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: 6, y: 8.5))
            prompt.line(to: NSPoint(x: 8, y: 10.5))
            prompt.line(to: NSPoint(x: 6, y: 12.5))
            prompt.move(to: NSPoint(x: 9.25, y: 12.75))
            prompt.line(to: NSPoint(x: 12, y: 12.75))
            prompt.lineWidth = 1.5
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round

            NSColor.black.set()
            if filled {
                stone.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                prompt.stroke()
            } else {
                stone.lineWidth = 1.4
                stone.stroke()
                prompt.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
