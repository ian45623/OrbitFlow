import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A key, or a key plus modifiers, that holds the mic open.
///
/// Two shapes, because macOS reports them through different events:
/// - a modifier on its own (Right ⌥, fn, Left ⌃…) arrives as `flagsChanged`, and press vs.
///   release is read from that one key's device-dependent flag bit;
/// - anything else (F5, ⌃⌥Space…) arrives as `keyDown`/`keyUp`, with `modifiers` held.
public struct Shortcut: Codable, Hashable, Sendable {
    public let keyCode: Int64
    /// Raw `CGEventFlags`, restricted to ⌃⌥⇧⌘. Always 0 for a modifier on its own.
    public let modifiers: UInt64
    /// What the key printed when it was recorded. Stored because a keyCode can't be named
    /// without the keyboard layout it was pressed on.
    public let keyName: String

    public static let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    public init(keyCode: Int64, modifiers: CGEventFlags = [], characters: String? = nil) {
        self.keyCode = keyCode
        let isModifier = Self.modifier(keyCode) != nil
        self.modifiers = isModifier ? 0 : modifiers.intersection(Self.modifierMask).rawValue
        let typed = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        self.keyName = Self.modifier(keyCode)?.name
            ?? Self.specialKeyName(keyCode)
            ?? (typed.isEmpty ? "Key \(keyCode)" : typed)
    }

    // The key name is a label, not identity: the same key recorded on two layouts is one shortcut.
    public static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    public var isModifierOnly: Bool { deviceFlag != nil }

    /// Device-*dependent* bit for this specific physical modifier key, or nil for other keys.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so `onRelease` never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    public var deviceFlag: CGEventFlags? { Self.modifier(keyCode)?.flag }

    /// Swallowing a lone modifier's `flagsChanged` can confuse apps that track modifier
    /// state, so only the two dedicated right-hand keys the app always consumed are. fn in
    /// particular must pass: fn+arrow, fn+delete and the emoji picker rely on it. A key
    /// combination is always consumed — it was pressed for us.
    public var consumesEvent: Bool {
        isModifierOnly ? (keyCode == kVK_RightOption || keyCode == kVK_RightCommand) : true
    }

    public var displayName: String {
        guard !isModifierOnly else { return keyName }
        let flags = CGEventFlags(rawValue: modifiers)
        var glyphs = ""
        if flags.contains(.maskControl) { glyphs += "⌃" }
        if flags.contains(.maskAlternate) { glyphs += "⌥" }
        if flags.contains(.maskShift) { glyphs += "⇧" }
        if flags.contains(.maskCommand) { glyphs += "⌘" }
        return glyphs + keyName
    }

    /// Whether a `keyDown`/`keyUp` with these values is this (non-modifier) shortcut.
    public func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        !isModifierOnly && keyCode == self.keyCode
            && flags.intersection(Self.modifierMask).rawValue == modifiers
    }

    /// Why this can't be a shortcut, or nil if it can.
    public var problem: String? {
        if keyCode == kVK_CapsLock { return "Caps Lock toggles instead of holding. Try another key." }
        if isModifierOnly { return nil }
        let flags = CGEventFlags(rawValue: modifiers)
        if keyCode == kVK_Escape, flags.isEmpty { return "Escape cancels dictation. Try another key." }
        if !Self.isFunctionKey(keyCode), flags.subtracting(.maskShift).isEmpty {
            return "Add ⌃, ⌥ or ⌘. On its own, \(displayName) would stop typing."
        }
        return nil
    }

    // MARK: - Key tables

    /// The raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    private static func modifier(_ keyCode: Int64) -> (flag: CGEventFlags, name: String)? {
        switch Int(keyCode) {
        case kVK_Control: (CGEventFlags(rawValue: 0x01), "Left ⌃")         // NX_DEVICELCTLKEYMASK
        case kVK_Shift: (CGEventFlags(rawValue: 0x02), "Left ⇧")           // NX_DEVICELSHIFTKEYMASK
        case kVK_RightShift: (CGEventFlags(rawValue: 0x04), "Right ⇧")     // NX_DEVICERSHIFTKEYMASK
        case kVK_Command: (CGEventFlags(rawValue: 0x08), "Left ⌘")         // NX_DEVICELCMDKEYMASK
        case kVK_RightCommand: (CGEventFlags(rawValue: 0x10), "Right ⌘")   // NX_DEVICERCMDKEYMASK
        case kVK_Option: (CGEventFlags(rawValue: 0x20), "Left ⌥")          // NX_DEVICELALTKEYMASK
        case kVK_RightOption: (CGEventFlags(rawValue: 0x40), "Right ⌥")    // NX_DEVICERALTKEYMASK
        case kVK_RightControl: (CGEventFlags(rawValue: 0x2000), "Right ⌃") // NX_DEVICERCTLKEYMASK
        case kVK_Function: (.maskSecondaryFn, "fn")                        // no left/right variant
        default: nil
        }
    }

    private static let functionKeys: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static func isFunctionKey(_ keyCode: Int64) -> Bool {
        functionKeys.contains(Int(keyCode))
    }

    /// Keys whose typed character is invisible or a private-use glyph.
    private static func specialKeyName(_ keyCode: Int64) -> String? {
        if let index = functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
        return switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_ANSI_KeypadEnter: "⌤"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "⎋"
        case kVK_CapsLock: "⇪"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        case kVK_Help: "Help"
        default: nil
        }
    }
}

/// The chosen shortcuts, and how they are stored.
public enum ShortcutKeys {
    public static let fallback = [Shortcut(keyCode: Int64(kVK_RightOption))]

    /// - Parameters:
    ///   - stored: the JSON-encoded `[Shortcut]`.
    ///   - previous: the short-lived array of preset names (`rightOption`, `fn`, `rightCommand`).
    ///   - legacy: the original single push-to-talk key, one of the same names.
    public static func resolved(stored: Data?, previous: [String]?, legacy: String?) -> [Shortcut] {
        if let stored, let decoded = try? JSONDecoder().decode([Shortcut].self, from: stored) {
            let keys = unique(decoded.filter { $0.problem == nil })
            if !keys.isEmpty { return keys }
        }
        let presets = unique((previous ?? []).compactMap(preset))
        if !presets.isEmpty { return presets }
        if let legacy, let key = preset(legacy) { return [key] }
        return fallback
    }

    private static func preset(_ name: String) -> Shortcut? {
        switch name {
        case "rightOption": Shortcut(keyCode: Int64(kVK_RightOption))
        case "fn": Shortcut(keyCode: Int64(kVK_Function))
        case "rightCommand": Shortcut(keyCode: Int64(kVK_RightCommand))
        default: nil
        }
    }

    private static func unique(_ keys: [Shortcut]) -> [Shortcut] {
        var seen = Set<Shortcut>()
        return keys.filter { seen.insert($0).inserted }
    }

    public static func adding(_ key: Shortcut, to keys: [Shortcut]) -> [Shortcut] {
        keys.contains(key) ? keys : keys + [key]
    }

    /// Refuses to drop the last remaining key, so dictation never has zero shortcuts.
    public static func removing(_ key: Shortcut, from keys: [Shortcut]) -> [Shortcut] {
        let next = keys.filter { $0 != key }
        return next.isEmpty ? keys : next
    }

    public static func displaySummary(_ keys: [Shortcut]) -> String {
        let names = (keys.isEmpty ? fallback : keys).map(\.displayName)
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) or \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", or " + names[names.count - 1]
        }
    }
}
