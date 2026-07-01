import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// What a strap double-tap (or a wrist-off trigger) does on the Mac. The enum itself is
/// cross-platform because it's persisted by `BehaviorStore`; only the *execution* (`MacActions`,
/// below) is macOS-only.
enum MacActionKind: String, Codable, CaseIterable, Identifiable {
    case none
    case lockScreen
    case buzzBack
    case markMoment
    case runShortcut

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:        return "Nothing"
        case .lockScreen:  return "Lock the Mac"
        case .buzzBack:    return "Buzz back (confirm)"
        case .markMoment:  return "Mark a moment"
        case .runShortcut: return "Run a Shortcut…"
        }
    }
    var symbol: String {
        switch self {
        case .none:        return "circle.slash"
        case .lockScreen:  return "lock.fill"
        case .buzzBack:    return "waveform.path"
        case .markMoment:  return "mappin.and.ellipse"
        case .runShortcut: return "bolt.fill"
        }
    }
}

#if os(macOS)
/// Mac-side side effects. Sandbox-friendly: Shortcuts run via the URL scheme (Shortcuts.app does the
/// privileged work), and screen lock uses login.framework's lock entry point. macOS only — there is
/// no iPhone equivalent for screen-lock / running a named Shortcut on demand.
enum MacActions {
    /// Lock the screen immediately — the same call the Apple-menu "Lock Screen" uses
    /// (login.framework `SACLockScreenImmediate`, resolved at runtime). Returns false if unavailable,
    /// so callers can fall back to a "Lock Screen" Shortcut.
    @discardableResult
    static func lockScreen() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: LockFn.self)
        _ = fn()
        return true
    }

    /// Run a macOS Shortcut by name via the `shortcuts://` URL scheme. Anything the user can build in
    /// Shortcuts (lock, mute, set Focus, open an app, automations) is reachable this way.
    static func runShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif // os(macOS)
