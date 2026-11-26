import Foundation
import HunchCore

/// Built-in per-app defaults. Users can override any of these.
public enum Seeds {
    public static let passwordManagers: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess", "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
    ]
    /// Terminals stay enabled: HunchFocus reads the input box of an AI agent (Claude Code, Gemini CLI,
    /// Codex, Aider) or the command at a shell prompt, picked from the window title in Automatic
    /// mode (`ShellCommandMode`), and treats every other screen (output, menus) as no field.
    /// `TerminalHosts` in HunchFocus says how each one is read.
    public static let terminals: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "com.cmuxterm.app",
    ]
    /// Code editors stay off until the user switches them on. Tab is left to the editor (it
    /// indents, and Cursor Tab or Copilot own it), so Option+Tab accepts there; HunchFocus tells code
    /// buffers from the editor's chat, commit and search inputs (`IDESurfaceClassifier`).
    public static let codeEditors: [String] = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4",
        "com.sublimetext.3", "com.panic.Nova", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.jetbrains.CLion", "com.jetbrains.rider", "com.jetbrains.rubymine", "com.jetbrains.PhpStorm",
        "com.jetbrains.datagrip", "com.google.android.studio",
    ]
    public static let chromiumHosts: [String] = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id", "md.obsidian", "com.anthropic.claudefordesktop",
    ]
    /// Tab passes through in Mail header rows; header detection itself lives in HunchFocus.
    public static let mail: [String] = ["com.apple.mail"]
    /// Precise bounds queries move focus or scroll here (design §11): the caret is estimated
    /// from the field frame instead.
    public static let estimatedGeometryHosts: [String] = ["com.apple.iCal", "com.apple.systempreferences"]

    public static let table: [PolicyKey: AppPolicyPatch] = {
        var t: [PolicyKey: AppPolicyPatch] = [:]
        func add(_ ids: [String], _ configure: (inout AppPolicyPatch) -> Void) {
            for id in ids {
                var p = AppPolicyPatch()
                configure(&p)
                t[.app(bundleID: id)] = p
            }
        }
        add(passwordManagers) { $0.secureExcluded = true; $0.enabled = false }
        add(codeEditors) { $0.enabled = false; $0.acceptWordKey = .chord(.rightArrow) }
        add(chromiumHosts) { $0.wakeChromiumAX = true }
        add(mail) { $0.acceptWordKey = .shortcuts }
        add(estimatedGeometryHosts) { $0.estimatedGeometryOnly = true }
        return t
    }()
}
