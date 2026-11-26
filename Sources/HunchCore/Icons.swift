import Foundation

/// The menu bar icon (Settings → Appearance → Icons). Each is a template glyph drawn by
/// `MenuBarIcon` in HunchOverlay.
public enum MenuBarIconChoice: String, Codable, Sendable, CaseIterable {
    /// The app icon's arched cat, traced closely: plume tail, arched back, small head low at the right.
    case cat
    /// The arched cat simplified: smooth outline, slimmer legs.
    case slimCat
    /// A plain lowercase h from the system font with cat ears.
    case letterH
    /// The dictation pill's cat face.
    case face
    /// An upward paw print, the Paws effect's print.
    case paw

    public var title: String {
        switch self {
        case .cat: "Cat"
        case .slimCat: "Slim cat"
        case .letterH: "Letter h"
        case .face: "Cat face"
        case .paw: "Paw"
        }
    }
}

/// The app icon (Settings → Appearance → Icons): one of the saved cat-and-color icons. The raw value
/// is the image's file name in the app's `AppIcons` resources folder.
public enum AppIconChoice: String, Codable, Sendable, CaseIterable {
    /// The icon the app ships with (`AppIcon.icns`).
    case whiteSage = "white-abb79f"
    case whiteLavender = "white-baaac6"
    case whiteBlue = "white-a6b7d1"
    case siameseSage = "siamese-abb79f"
    case siameseLavender = "siamese-baaac6"
    case orangeTabbyMint = "orange-tabby-becdc5"
    case orangeTabbyBlue = "orange-tabby-a6b7d1"
    case silverTabbyBlue = "silver-tabby-a6b7d1"
    case greyCream = "grey-f9eee0"
    case blackPeach = "black-f5dabb"
    case tuxedoBlue = "tuxedo-a6b7d1"

    public static let standard = AppIconChoice.whiteSage

    public var title: String {
        switch self {
        case .whiteSage: "White on sage"
        case .whiteLavender: "White on lavender"
        case .whiteBlue: "White on blue"
        case .siameseSage: "Siamese on sage"
        case .siameseLavender: "Siamese on lavender"
        case .orangeTabbyMint: "Orange tabby on mint"
        case .orangeTabbyBlue: "Orange tabby on blue"
        case .silverTabbyBlue: "Silver tabby on blue"
        case .greyCream: "Grey on cream"
        case .blackPeach: "Black on peach"
        case .tuxedoBlue: "Tuxedo on blue"
        }
    }
}
