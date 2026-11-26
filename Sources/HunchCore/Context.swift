import CoreGraphics
import Foundation

/// Monotonic identity of one completion request. Newer requests supersede older ones.
public struct RequestID: Hashable, Comparable, Sendable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public static func < (lhs: RequestID, rhs: RequestID) -> Bool { lhs.raw < rhs.raw }
}

/// Identity of one focused text field within one focus session.
/// `generation` increments whenever focus leaves and returns, so stale results never match.
public struct FieldID: Hashable, Sendable {
    public let pid: pid_t
    public let elementHash: Int
    public let generation: UInt32
    public init(pid: pid_t, elementHash: Int, generation: UInt32) {
        self.pid = pid
        self.elementHash = elementHash
        self.generation = generation
    }
}

public struct AppIdentity: Hashable, Sendable {
    public let bundleID: String
    public let pid: pid_t
    public let localizedName: String?
    public init(bundleID: String, pid: pid_t, localizedName: String?) {
        self.bundleID = bundleID
        self.pid = pid
        self.localizedName = localizedName
    }
}

/// What kind of writing surface the field is. Sent to the prompt instead of raw app/window names.
public enum SurfaceKind: String, Codable, Sendable, CaseIterable {
    case email, chat, document, note, search, form, code, terminal, agentPrompt, shell, unknown
}

public struct FieldMetadata: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var placeholder: String?
    public var label: String?
    public var isMultiline: Bool
    public var surface: SurfaceKind
    /// At a shell prompt (`.shell`): the command typed after the prompt so far. `before` ends with it.
    public var typedCommand: String?
    /// A code editor's AI chat or composer box. Suggestions treat it as any prose field; Write for me
    /// writes prompts there.
    public var isAIChatInput: Bool
    public init(role: String? = nil, subrole: String? = nil, placeholder: String? = nil, label: String? = nil,
                isMultiline: Bool = false, surface: SurfaceKind = .unknown, typedCommand: String? = nil,
                isAIChatInput: Bool = false) {
        self.typedCommand = typedCommand
        self.isAIChatInput = isAIChatInput
        self.role = role
        self.subrole = subrole
        self.placeholder = placeholder
        self.label = label
        self.isMultiline = isMultiline
        self.surface = surface
    }
}

/// Text around the caret, read only after the secure gate passed. Never logged.
public struct TextContext: Sendable, Equatable {
    public var app: AppIdentity
    public var field: FieldID
    public var urlHost: String?
    /// Title of the field's window (AXTitle), sanitized by HunchFocus. Metadata, not field text.
    public var windowTitle: String?
    /// Bounded, caret-adjacent tail of the text before the caret.
    public var before: String
    /// Bounded, caret-adjacent head of the text after the caret.
    public var after: String
    public var selectionLength: Int
    /// The selected text itself (empty without a selection or when it is very long). Not part of
    /// `contentSignature`'s inputs beyond its length.
    public var selectedText: String
    public var hasMarkedText: Bool
    /// `before` was cut short (the read window), so the field has more text before it.
    public var beforeIsCut = false
    /// `after` was cut short, so the field has more text after it.
    public var afterIsCut = false
    public var caretAtLineEnd: Bool
    public var metadata: FieldMetadata
    /// Hash of before/after/selection. Safe to log; the text itself is not.
    public var contentSignature: UInt64
    public var capturedAt: ContinuousClock.Instant

    public init(app: AppIdentity, field: FieldID, urlHost: String? = nil, before: String, after: String,
                selectionLength: Int = 0, hasMarkedText: Bool = false, caretAtLineEnd: Bool = true,
                metadata: FieldMetadata = FieldMetadata(), contentSignature: UInt64,
                capturedAt: ContinuousClock.Instant = .now, windowTitle: String? = nil, selectedText: String = "") {
        self.selectedText = selectedText
        self.windowTitle = windowTitle
        self.app = app
        self.field = field
        self.urlHost = urlHost
        self.before = before
        self.after = after
        self.selectionLength = selectionLength
        self.hasMarkedText = hasMarkedText
        self.caretAtLineEnd = caretAtLineEnd
        self.metadata = metadata
        self.contentSignature = contentSignature
        self.capturedAt = capturedAt
    }
}

/// How trustworthy a caret rectangle is. Presentation picks inline vs card from this.
public enum GeometryQuality: Int, Comparable, Sendable {
    case none, estimated, derived, exact
    public static func < (lhs: GeometryQuality, rhs: GeometryQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// sRGB-ish color components as reported by the host (`AXForegroundColor`), 0...1.
public struct RGBAColor: Sendable, Equatable {
    public var red, green, blue, alpha: CGFloat
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    /// Relative luminance approximation (Rec. 709 weights, no gamma correction).
    public var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

public struct FontHint: Sendable, Equatable {
    public var family: String?
    /// PostScript-style font name when the host reports one (e.g. "HelveticaNeue").
    public var name: String?
    public var pointSize: CGFloat?
    public var isMonospaced: Bool
    /// Color of the typed text next to the caret, when the host reports it.
    public var textColor: RGBAColor?
    /// Background of the typed text (`AXBackgroundColor`), when the host reports one.
    public var backgroundColor: RGBAColor?
    /// Installed face picked from on-screen measurement when the host's font can't be loaded
    /// (`FaceChoiceBook`); drawn after a known stand-in, before the system face.
    public var measuredFamily: String?
    /// Confirmed size correction from on-screen measurement for a host font that loads (1 = none).
    public var sizeFactor: CGFloat = 1
    public init(family: String? = nil, name: String? = nil, pointSize: CGFloat? = nil, isMonospaced: Bool = false,
                textColor: RGBAColor? = nil, backgroundColor: RGBAColor? = nil) {
        self.family = family
        self.name = name
        self.pointSize = pointSize
        self.isMonospaced = isMonospaced
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
}

public struct CaretGeometry: Sendable, Equatable {
    /// Global AppKit coordinates (origin bottom-left of the main screen).
    public var caretRect: CGRect
    public var fieldFrame: CGRect?
    public var font: FontHint?
    public var quality: GeometryQuality
    /// Host text width ÷ the same text's width in the system font at the reported size, learned
    /// from exact caret positions while typing. Nil until enough samples agree.
    public var widthScale: CGFloat?
    /// Global x of the first character on the caret's line, from that character's own bounds. Nil
    /// when unknown or untrustworthy (an empty or soft-wrapped line, a field scrolled sideways); read
    /// only for apps that mirror.
    public var lineStartX: CGFloat?
    public init(caretRect: CGRect, fieldFrame: CGRect? = nil, font: FontHint? = nil, quality: GeometryQuality,
                widthScale: CGFloat? = nil, lineStartX: CGFloat? = nil) {
        self.caretRect = caretRect
        self.fieldFrame = fieldFrame
        self.font = font
        self.quality = quality
        self.widthScale = widthScale
        self.lineStartX = lineStartX
    }
}

/// Why Hunch refused to act in the current field. Blocking happens before any text is read.
public enum BlockReason: Sendable, Equatable {
    case secureEventInput(ownerPID: pid_t?)
    case globallyDisabled, appDisabled, secureExcludedApp
    case secureRole, sensitiveMarker, protectedContent, ownProcess, trackingPaused
    case markedText, selectionActive, midLineDisallowed, notEditable
    /// A search field in an app or site whose policy excludes them (`AppPolicy.excludeSearchFields`).
    case searchField
    /// A terminal that draws its text without exposing it to Accessibility (kitty, Alacritty,
    /// WezTerm): nothing can be read there.
    case hostExposesNoText
}
