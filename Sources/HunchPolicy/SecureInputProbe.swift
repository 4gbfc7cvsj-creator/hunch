import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Reads system-wide Secure Event Input state. Call from the app to fill `SystemProbe`.
public enum SecureInputProbe {
    public static func isSecureEventInputEnabled() -> Bool { IsSecureEventInputEnabled() }

    /// Best-effort owner of Secure Event Input. Uses an undocumented session key; nil when absent.
    public static func ownerPID() -> pid_t? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let value = dict["kCGSSessionSecureInputPID"] as? NSNumber else { return nil }
        let pid = pid_t(truncating: value)
        return pid > 0 ? pid : nil
    }
}
