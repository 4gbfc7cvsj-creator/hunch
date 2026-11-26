import CoreGraphics
import Foundation

/// One recognized line of text. `rect` is in global screen points with a top-left origin
/// (the same space as Accessibility frames and the caret rect).
public struct OCRLine: Sendable, Equatable {
    public var text: String
    public var confidence: Float
    public var rect: CGRect
    public init(text: String, confidence: Float, rect: CGRect) {
        self.text = text
        self.confidence = confidence
        self.rect = rect
    }
}
