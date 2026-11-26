import AppKit
import HunchCore

/// The menu bar icon, one of the glyphs in `MenuBarIconChoice` (Settings → Appearance → Icons), and
/// the dictation pill's cat face. Menu bar glyphs are template images, so macOS tints them for light
/// and dark menu bars and the highlighted state; the status button's `appearsDisabled` fades them
/// while Hunch is paused or off. Drawn as vectors in an 18-point square, so they are crisp at any
/// scale, and shape only, so they fit whichever app icon is picked.
public enum MenuBarIcon {
    public static let size = NSSize(width: 18, height: 18)

    public static func image(_ choice: MenuBarIconChoice = .cat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(choice, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hunch"
        return image
    }

    /// Draws `choice` in `color` into the current context, filling the 18-point square.
    public static func draw(_ choice: MenuBarIconChoice, color: NSColor) {
        color.setFill()
        switch choice {
        case .cat: catPath().fill()
        case .slimCat: slimCatPath().fill()
        case .letterH: letterH()
        case .face: drawFace(color: color)
        case .paw: pawPath().fill()
        }
    }

    // MARK: Cat: the app icon's cat, traced

    /// The outline of the app icon's white cat, cut from its artwork and fitted to the square
    /// (origin bottom-left), starting at the tail tip and running down the back of the tail. The
    /// head is redrawn by hand, since the artwork's is too small to trace cleanly.
    static let catOutline: [(CGFloat, CGFloat)] = [
        (3.46, 17.62), (2.21, 16.47), (1.83, 15.49), (1.50, 15.22), (1.28, 13.25), (1.12, 13.04), (1.50, 11.40), (1.39, 10.96),
        (1.83, 9.98), (1.72, 9.38), (2.05, 8.13), (2.10, 6.60), (1.94, 5.95), (1.99, 4.53), (1.77, 3.87), (1.77, 2.18),
        (2.10, 0.49), (2.43, 0.16), (2.97, 0.00), (4.01, 0.00), (5.75, 0.38), (5.86, 0.76), (5.37, 1.53), (5.37, 2.29),
        (6.41, 4.36), (6.79, 6.82), (7.66, 7.58), (8.43, 7.85), (9.14, 7.85), (9.68, 7.64), (10.45, 6.71), (10.77, 5.51),
        (10.94, 2.07), (11.32, 0.44), (11.92, 0.05), (13.06, 0.05), (14.59, 0.33), (14.70, 0.93), (14.37, 1.25), (14.21, 1.80),
        (14.26, 4.15), (14.54, 4.53), (15.50, 4.70), (16.70, 5.30), (17.30, 6.40), (17.50, 7.60), (17.70, 10.40), (16.10, 9.30),
        (14.90, 9.60), (14.20, 11.00), (13.40, 10.60), (12.41, 11.73), (11.97, 11.84), (11.10, 12.55), (10.55, 12.49), (9.95, 12.76),
        (9.46, 12.65), (8.97, 12.87), (8.05, 12.44), (7.28, 12.38), (5.15, 11.07), (5.10, 11.67), (5.32, 12.27), (5.21, 13.31),
        (5.48, 14.02), (5.43, 14.62), (5.75, 15.00), (6.19, 16.15), (5.81, 17.18), (5.92, 17.62), (5.15, 18.00), (4.39, 17.95)
    ]
    /// Points kept sharp: the ear tips and the dip between them.
    static let catCorners: Set<Int> = [46, 47, 49]

    /// The traced cat, smoothed into curves through its points.
    static func catPath(_ transform: AffineTransform = .identity) -> NSBezierPath {
        let path = smoothClosed(catOutline.map { NSPoint(x: $0.0, y: $0.1) }, corners: catCorners)
        path.transform(using: transform)
        return path
    }

    /// A closed curve through `points` (Catmull-Rom as cubic Béziers); points in `corners` stay sharp.
    static func smoothClosed(_ points: [NSPoint], corners: Set<Int>) -> NSBezierPath {
        let n = points.count
        let path = NSBezierPath()
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            let c1 = corners.contains(i) ? p1 : NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = corners.contains((i + 1) % n) ? p2
                : NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        path.close()
        return path
    }

    // MARK: Slim cat

    /// The arched cat simplified: the tail is the h's tall stroke, the back legs its stem, the arched
    /// back its shoulder, the front legs the short stroke; a small head with two ears sits low at the
    /// right, below the top of the back, as in the app icon.
    static func slimCatPath() -> NSBezierPath {
        let b = NSBezierPath()
        b.move(to: NSPoint(x: 2.0, y: 0))
        b.line(to: NSPoint(x: 2.0, y: 8.0))
        // Outer edge of the tail up to its tip, then its inner edge down into the rump.
        b.curve(to: NSPoint(x: 5.4, y: 18.0), controlPoint1: NSPoint(x: 1.6, y: 12.8), controlPoint2: NSPoint(x: 2.8, y: 17.4))
        b.curve(to: NSPoint(x: 5.0, y: 11.6), controlPoint1: NSPoint(x: 4.9, y: 16.0), controlPoint2: NSPoint(x: 4.4, y: 13.6))
        // The arched back, down to the back of the head.
        b.curve(to: NSPoint(x: 12.9, y: 9.7), controlPoint1: NSPoint(x: 7.0, y: 13.2), controlPoint2: NSPoint(x: 11.3, y: 13.0))
        // Ears.
        b.line(to: NSPoint(x: 13.2, y: 12.3))
        b.line(to: NSPoint(x: 14.8, y: 11.0))
        b.line(to: NSPoint(x: 16.8, y: 12.1))
        // Forehead and muzzle to the chin, the chest into the front legs.
        b.curve(to: NSPoint(x: 16.6, y: 7.7), controlPoint1: NSPoint(x: 17.3, y: 10.4), controlPoint2: NSPoint(x: 17.3, y: 8.6))
        b.curve(to: NSPoint(x: 14.2, y: 5.6), controlPoint1: NSPoint(x: 16.0, y: 6.5), controlPoint2: NSPoint(x: 15.0, y: 5.8))
        b.line(to: NSPoint(x: 14.2, y: 0))
        b.line(to: NSPoint(x: 11.8, y: 0))
        b.line(to: NSPoint(x: 11.8, y: 4.8))
        // The tall arch under the belly.
        b.curve(to: NSPoint(x: 4.4, y: 4.8), controlPoint1: NSPoint(x: 11.8, y: 10.6), controlPoint2: NSPoint(x: 4.4, y: 10.6))
        b.line(to: NSPoint(x: 4.4, y: 0))
        b.close()
        return b
    }

    // MARK: Letter h

    /// The system font's semibold lowercase h, 15 points tall on the bottom edge, with two cat ears on
    /// its shoulder above the short stroke.
    static func letterH() {
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold) as CTFont
        var character = UniChar(UInt8(ascii: "h"))
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let outline = CTFontCreatePathForGlyph(font, glyph, nil),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let box = outline.boundingBoxOfPath
        let scale = 15 / box.height
        // Centered, nudged left so the ears' overhang stays inside the square.
        let dx = 9 - box.midX * scale - 1.2
        var transform = CGAffineTransform(translationX: dx, y: -box.minY * scale).scaledBy(x: scale, y: scale)
        guard let placed = outline.copy(using: &transform) else { return }
        context.addPath(placed)
        context.fillPath()
        let right = dx + box.maxX * scale
        let top = CTFontGetXHeight(font) * scale
        let ears = NSBezierPath()
        ears.move(to: NSPoint(x: right - 5.6, y: top - 1.0))
        ears.line(to: NSPoint(x: right - 4.9, y: top + 3.0))
        ears.line(to: NSPoint(x: right - 2.7, y: top + 0.2))
        ears.close()
        ears.move(to: NSPoint(x: right - 2.9, y: top + 0.2))
        ears.line(to: NSPoint(x: right - 0.2, y: top + 3.0))
        ears.line(to: NSPoint(x: right, y: top - 1.8))
        ears.close()
        ears.fill()
    }

    // MARK: Paw

    /// The Paws effect's print (`PopIn.pawPads`) pointing up, filling the square.
    static func pawPath() -> NSBezierPath {
        let path = NSBezierPath()
        let s = Double(size.width)
        for pad in PopIn.pawPads(size: s) {
            path.appendOval(in: NSRect(x: 9 + pad.x - pad.rx, y: 9 - 0.03 * s + pad.y - pad.ry,
                                       width: 2 * pad.rx, height: 2 * pad.ry))
        }
        return path
    }

    /// Fills with clear whatever `draw` paints, erasing what is under it.
    private static func erase(_ draw: () -> Void) {
        let context = NSGraphicsContext.current
        context?.saveGraphicsState()
        context?.compositingOperation = .clear
        draw()
        context?.restoreGraphicsState()
    }

    // MARK: Front-facing cat face (the dictation pill)

    /// A cat's head seen from the front, filling the 18-point square: a broad rounded head wider
    /// than tall, two ears with rounded tips at the top corners. Outline only; `drawFace` cuts
    /// the eyes and mouth. Origin bottom-left, transformed by `transform`.
    static func faceOutline(_ transform: AffineTransform = .identity) -> NSBezierPath {
        let face = NSBezierPath()
        face.move(to: NSPoint(x: 0.7, y: 6.6))
        // Left side up to the ear, the ear's rounded tip, down its inner edge.
        face.curve(to: NSPoint(x: 1.5, y: 11.4), controlPoint1: NSPoint(x: 0.7, y: 8.6), controlPoint2: NSPoint(x: 1.0, y: 10.2))
        face.curve(to: NSPoint(x: 2.3, y: 16.1), controlPoint1: NSPoint(x: 1.3, y: 13.2), controlPoint2: NSPoint(x: 1.5, y: 15.4))
        face.curve(to: NSPoint(x: 3.9, y: 16.2), controlPoint1: NSPoint(x: 2.7, y: 16.6), controlPoint2: NSPoint(x: 3.4, y: 16.6))
        face.line(to: NSPoint(x: 6.6, y: 13.6))
        // The crown between the ears.
        face.curve(to: NSPoint(x: 11.4, y: 13.6), controlPoint1: NSPoint(x: 8.2, y: 14.0), controlPoint2: NSPoint(x: 9.8, y: 14.0))
        // Right ear, then down the right side.
        face.line(to: NSPoint(x: 14.1, y: 16.2))
        face.curve(to: NSPoint(x: 15.7, y: 16.1), controlPoint1: NSPoint(x: 14.6, y: 16.6), controlPoint2: NSPoint(x: 15.3, y: 16.6))
        face.curve(to: NSPoint(x: 16.5, y: 11.4), controlPoint1: NSPoint(x: 16.5, y: 15.4), controlPoint2: NSPoint(x: 16.7, y: 13.2))
        face.curve(to: NSPoint(x: 17.3, y: 6.6), controlPoint1: NSPoint(x: 17.0, y: 10.2), controlPoint2: NSPoint(x: 17.3, y: 8.6))
        // The wide jaw.
        face.curve(to: NSPoint(x: 9.0, y: 1.2), controlPoint1: NSPoint(x: 17.3, y: 2.8), controlPoint2: NSPoint(x: 13.4, y: 1.2))
        face.curve(to: NSPoint(x: 0.7, y: 6.6), controlPoint1: NSPoint(x: 4.6, y: 1.2), controlPoint2: NSPoint(x: 0.7, y: 2.8))
        face.close()
        face.transform(using: transform)
        return face
    }

    /// Draws the face in `color`, transformed by `transform`, with the eyes and a small
    /// "w" mouth cut out.
    static func drawFace(color: NSColor, transform: AffineTransform) {
        color.setFill()
        faceOutline(transform).fill()
        erase {
            for x in [5.3, 12.7] as [CGFloat] {
                let eye = NSBezierPath(ovalIn: NSRect(x: x - 1.0, y: 5.6, width: 2.0, height: 3.0))
                eye.transform(using: transform)
                eye.fill()
            }
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: 7.4, y: 4.6))
            mouth.curve(to: NSPoint(x: 9.0, y: 4.6), controlPoint1: NSPoint(x: 7.6, y: 3.6), controlPoint2: NSPoint(x: 8.8, y: 3.6))
            mouth.curve(to: NSPoint(x: 10.6, y: 4.6), controlPoint1: NSPoint(x: 9.2, y: 3.6), controlPoint2: NSPoint(x: 10.4, y: 3.6))
            mouth.transform(using: transform)
            mouth.lineWidth = 0.9 * transform.m11
            mouth.lineCapStyle = .round
            mouth.lineJoinStyle = .round
            mouth.stroke()
        }
    }

    /// The face alone, filling the square.
    public static func drawFace(color: NSColor) {
        drawFace(color: color, transform: .identity)
    }

    /// The face, a little smaller at the bottom left, so the top right corner is free for a badge.
    static let badgedFace = AffineTransform(scaleByX: 0.88, byY: 0.88)

    /// Draws `badge` over the face's top right corner, clearing a thin gap around it first.
    static func drawBadged(color: NSColor, badge: () -> [NSBezierPath], strokes: [NSBezierPath] = []) {
        drawFace(color: color, transform: badgedFace)
        let gap: CGFloat = 0.8
        erase {
            for path in badge() {
                let outline = path.copy() as! NSBezierPath
                outline.lineWidth = gap * 2
                outline.lineJoinStyle = .round
                outline.stroke()
                outline.fill()
            }
            for path in strokes {
                let outline = path.copy() as! NSBezierPath
                outline.lineWidth = path.lineWidth + gap * 2
                outline.lineCapStyle = .round
                outline.stroke()
            }
        }
        color.setFill()
        color.setStroke()
        for path in badge() { path.fill() }
        for path in strokes { path.stroke() }
    }

    /// The face with a small microphone over its top right corner: dictating and transcribing.
    public static func drawFaceMicrophone(color: NSColor) {
        let capsule = NSRect(x: 13.9, y: 10.2, width: 2.6, height: 4.6)
        let holder = NSBezierPath()
        holder.appendArc(withCenter: NSPoint(x: capsule.midX, y: capsule.minY + 1.5), radius: 2.3,
                         startAngle: 200, endAngle: 340, clockwise: false)
        holder.move(to: NSPoint(x: capsule.midX, y: capsule.minY - 0.8))
        holder.line(to: NSPoint(x: capsule.midX, y: capsule.minY - 2.4))
        holder.lineWidth = 1.0
        holder.lineCapStyle = .round
        drawBadged(color: color, badge: {
            [NSBezierPath(roundedRect: capsule, xRadius: capsule.width / 2, yRadius: capsule.width / 2)]
        }, strokes: [holder])
    }

    /// The face with two sparkles over its top right corner: offering Polish.
    public static func drawFaceSparkle(color: NSColor) {
        drawBadged(color: color, badge: {
            [sparkle(center: NSPoint(x: 14.9, y: 14.6), radius: 3.0),
             sparkle(center: NSPoint(x: 11.6, y: 16.6), radius: 1.4)]
        })
    }

    /// A four-point star with inward-curving sides.
    static func sparkle(center c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y),
                    NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
        let pull = r * 0.2
        let path = NSBezierPath()
        path.move(to: tips[0])
        for i in 0..<4 {
            let a = tips[i], b = tips[(i + 1) % 4]
            // Control point near the center, in the quadrant between the two tips.
            let control = NSPoint(x: c.x + (a.x - c.x + b.x - c.x).sign(pull),
                                  y: c.y + (a.y - c.y + b.y - c.y).sign(pull))
            path.curve(to: b, controlPoint1: control, controlPoint2: control)
        }
        path.close()
        return path
    }
}

private extension CGFloat {
    /// `magnitude` with this value's sign.
    func sign(_ magnitude: CGFloat) -> CGFloat { self < 0 ? -magnitude : magnitude }
}
