import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import OrbitFlowHotkey

struct ShortcutKeysTests {
    let rightOption = Shortcut(keyCode: Int64(kVK_RightOption))
    let fn = Shortcut(keyCode: Int64(kVK_Function))
    let ctrlOptSpace = Shortcut(keyCode: Int64(kVK_Space), modifiers: [.maskControl, .maskAlternate])

    @Test("A stored list wins, and survives a JSON round trip")
    func storedWins() throws {
        let data = try JSONEncoder().encode([fn, ctrlOptSpace])
        let keys = ShortcutKeys.resolved(stored: data, previous: ["rightCommand"], legacy: "rightOption")
        #expect(keys == [fn, ctrlOptSpace])
        #expect(keys.map(\.displayName) == ["fn", "⌃⌥Space"])
    }

    @Test("The preset-name list and the old single key both migrate")
    func migrates() {
        #expect(ShortcutKeys.resolved(stored: nil, previous: ["fn", "fn", "rightOption"], legacy: nil) == [fn, rightOption])
        #expect(ShortcutKeys.resolved(stored: nil, previous: nil, legacy: "fn") == [fn])
        #expect(ShortcutKeys.resolved(stored: nil, previous: ["banana"], legacy: nil) == [rightOption])
    }

    @Test("Garbage or invalid stored data falls back")
    func garbage() throws {
        #expect(ShortcutKeys.resolved(stored: Data("nope".utf8), previous: nil, legacy: "fn") == [fn])
        let bare = try JSONEncoder().encode([Shortcut(keyCode: Int64(kVK_ANSI_A))])
        #expect(ShortcutKeys.resolved(stored: bare, previous: nil, legacy: nil) == [rightOption])
    }

    @Test("A lone modifier drops any modifiers and keeps its left/right name")
    func modifierOnly() {
        let leftCmd = Shortcut(keyCode: Int64(kVK_Command), modifiers: .maskCommand)
        #expect(leftCmd.isModifierOnly)
        #expect(leftCmd.modifiers == 0)
        #expect(leftCmd.displayName == "Left ⌘")
        #expect(!fn.consumesEvent)
        #expect(rightOption.consumesEvent)
    }

    @Test("Combinations match only with exactly their modifiers")
    func matching() {
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskNumericPad]
        #expect(ctrlOptSpace.matches(keyCode: Int64(kVK_Space), flags: flags))
        #expect(!ctrlOptSpace.matches(keyCode: Int64(kVK_Space), flags: .maskControl))
        #expect(!rightOption.matches(keyCode: Int64(kVK_RightOption), flags: []))
    }

    @Test("Keys that would break typing or cancelling are refused")
    func problems() {
        #expect(Shortcut(keyCode: Int64(kVK_ANSI_A)).problem != nil)
        #expect(Shortcut(keyCode: Int64(kVK_ANSI_A), modifiers: .maskShift).problem != nil)
        #expect(Shortcut(keyCode: Int64(kVK_Escape)).problem != nil)
        #expect(Shortcut(keyCode: Int64(kVK_CapsLock)).problem != nil)
        #expect(Shortcut(keyCode: Int64(kVK_F5)).problem == nil)
        #expect(Shortcut(keyCode: Int64(kVK_ANSI_D), modifiers: .maskCommand, characters: "d").displayName == "⌘D")
        #expect(ctrlOptSpace.problem == nil)
    }

    @Test("Adding dedupes; the last key cannot be removed")
    func addRemove() {
        #expect(ShortcutKeys.adding(fn, to: [rightOption]) == [rightOption, fn])
        #expect(ShortcutKeys.adding(fn, to: [fn]) == [fn])
        #expect(ShortcutKeys.removing(fn, from: [fn]) == [fn])
        #expect(ShortcutKeys.removing(fn, from: [fn, rightOption]) == [rightOption])
    }

    @Test("Summaries read as 'or'")
    func summary() {
        #expect(ShortcutKeys.displaySummary([rightOption, fn]) == "Right ⌥ or fn")
    }
}
