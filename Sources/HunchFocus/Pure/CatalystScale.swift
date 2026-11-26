import CoreGraphics

/// Mac Catalyst apps built for the iPad idiom (Draw Things) are drawn at 77% of their iPad size,
/// but accessibility reports the unscaled font size (17.25 pt for text that shows at 13.3 pt).
/// Apps built with the Mac idiom draw at full size: "Optimize for Mac" (device family 6), or
/// Apple's own Catalyst apps (Messages), which list family 2 but set `UIUserInterfaceIdiomMac`.
public enum CatalystScale {
    public static let iPadIdiom: CGFloat = 0.77

    /// The factor from reported font size to on-screen size, from the app's `UIDeviceFamily`
    /// Info.plist value: 1 for AppKit apps (no key) and Mac-idiom Catalyst apps.
    /// `macIdiom` is the `UIUserInterfaceIdiomMac` value, which overrides the family list.
    public static func factor(deviceFamily: Any?, macIdiom: Any? = nil) -> CGFloat {
        if (macIdiom as? Bool) == true { return 1 }
        guard let raw = deviceFamily else { return 1 }
        let families: [Int]
        if let list = raw as? [Any] {
            families = list.compactMap { ($0 as? Int) ?? Int(($0 as? String) ?? "") }
        } else if let one = raw as? Int {
            families = [one]
        } else {
            return 1
        }
        guard !families.isEmpty, !families.contains(6) else { return 1 }
        return iPadIdiom
    }
}
