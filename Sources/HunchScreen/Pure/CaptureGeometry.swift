import CoreGraphics

public enum CaptureGeometry {
    /// Band around the field (or caret when the field frame is unknown), expanded vertically by
    /// `margin` and clamped to `container` (a display or window frame). Horizontally spans the container.
    public static func band(fieldFrame: CGRect?, caretRect: CGRect, container: CGRect,
                            margin: CGFloat = 600) -> CGRect? {
        let anchor = (fieldFrame?.isEmpty == false ? fieldFrame! : caretRect)
        guard !container.isEmpty, anchor.minY.isFinite, anchor.maxY.isFinite else { return nil }
        let band = CGRect(x: container.minX, y: anchor.minY - margin, width: container.width,
                          height: anchor.height + 2 * margin).intersection(container)
        return band.isNull || band.isEmpty ? nil : band
    }

    /// A stand-in for the field's column when the field's frame is unknown (the app didn't give one,
    /// or not yet: a Messages read right after switching conversations had none, so the sidebar's
    /// previews were interleaved with the chat and nothing was labeled). Only when the caret is at
    /// the start of its line (an empty field, a new line), where the caret's x is the field's left
    /// edge: from just left of the caret to the window's right edge. Nil otherwise (mid-line, the
    /// caret's x says nothing about where the field starts).
    public static let caretColumnSlack: CGFloat = 40

    public static func caretColumn(caret: CGRect, window: CGRect, lineBefore: String) -> CGRect? {
        let line = lineBefore.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        guard line.allSatisfy(\.isWhitespace), !window.isEmpty, caret.minX.isFinite, caret.minY.isFinite,
              caret.minX >= window.minX, caret.minX < window.maxX else { return nil }
        let left = max(window.minX, caret.minX - caretColumnSlack)
        return CGRect(x: left, y: caret.minY, width: window.maxX - left, height: max(caret.height, 1))
    }

    /// Converts a Vision normalized box (origin bottom-left) into screen points (origin top-left).
    public static func screenRect(normalized box: CGRect, in band: CGRect) -> CGRect {
        CGRect(x: band.minX + box.minX * band.width,
               y: band.minY + (1 - box.maxY) * band.height,
               width: box.width * band.width, height: box.height * band.height)
    }
}
