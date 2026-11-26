import Foundation

/// The "app" a piece of learned data belongs to: the site's host in a browser, otherwise the
/// app's bundle ID. Saved sentences are kept per app key and learned words favor the app where
/// they were used.
public enum AppKey {
    public static func make(bundleID: String?, urlHost: String?) -> String? {
        if var host = urlHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if !host.isEmpty { return host }
        }
        let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }
}
