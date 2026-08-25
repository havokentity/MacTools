import AppKit
import XCTest
@testable import DMonteCore

/// Covers the remappable-shortcut plumbing: the storage codec, glyph rendering, validation,
/// the UserDefaults-backed store, and duplicate prevention in the controller.
final class WindowShortcutTests: XCTestCase {

    // MARK: - Codec

    func testStorageCodecRoundTrips() {
        let shortcut = WindowShortcut(keyCode: HotKeyCode.left, modifiers: HotKeyModifier.controlOption)
        XCTAssertEqual(shortcut.storageValue, "123,6144")
        XCTAssertEqual(WindowShortcut(storageValue: shortcut.storageValue), shortcut)
    }

    func testStorageCodecRejectsGarbage() {
        XCTAssertNil(WindowShortcut(storageValue: ""))
        XCTAssertNil(WindowShortcut(storageValue: "123"))
        XCTAssertNil(WindowShortcut(storageValue: "abc,def"))
        XCTAssertNil(WindowShortcut(storageValue: "1,2,3"))
        XCTAssertNil(WindowShortcut(storageValue: "-5,10"))
    }

    // MARK: - Glyphs

    func testDisplayStringUsesStandardMacGlyphOrder() {
        XCTAssertEqual(WindowShortcut(keyCode: HotKeyCode.left, modifiers: HotKeyModifier.controlOption).displayString, "⌃⌥←")
        XCTAssertEqual(WindowShortcut(keyCode: HotKeyCode.returnKey, modifiers: HotKeyModifier.controlOption).displayString, "⌃⌥↩")
        XCTAssertEqual(WindowShortcut(keyCode: HotKeyCode.c, modifiers: HotKeyModifier.controlOption).displayString, "⌃⌥C")
        // Canonical order is ⌃ ⌥ ⇧ ⌘ regardless of mask bit order.
        let all = HotKeyModifier.command | HotKeyModifier.shift | HotKeyModifier.option | HotKeyModifier.control
        XCTAssertEqual(WindowShortcut(keyCode: 0x00, modifiers: all).displayString, "⌃⌥⇧⌘A")
    }

    func testFunctionKeyAndUnknownGlyphs() {
        XCTAssertEqual(HotKeyGlyphs.glyph(forKeyCode: 79), "F18")
        XCTAssertEqual(HotKeyGlyphs.glyph(forKeyCode: 0x7E), "↑")
        XCTAssertEqual(HotKeyGlyphs.glyph(forKeyCode: 9999), "Key 9999")
    }

    func testEveryDefaultShortcutRendersWithoutPlaceholders() {
        for action in WindowAction.allCases {
            guard let shortcut = action.defaultShortcut else { continue }
            XCTAssertFalse(shortcut.displayString.contains("Key "), "\(action.rawValue) shortcut lacks a glyph")
            XCTAssertTrue(shortcut.displayString.hasPrefix("⌃⌥"), "\(action.rawValue) default should be ⌃⌥-based")
        }
    }

    // MARK: - Validation

    func testGlobalUsabilityRequiresStrongModifierOrFunctionKey() {
        let strong = WindowShortcut(keyCode: 0x00, modifiers: HotKeyModifier.control)
        XCTAssertTrue(strong.isUsableGlobally)

        let shiftOnly = WindowShortcut(keyCode: 0x00, modifiers: HotKeyModifier.shift)
        XCTAssertFalse(shiftOnly.isUsableGlobally, "⇧A alone would swallow typing")

        let bare = WindowShortcut(keyCode: 0x00, modifiers: 0)
        XCTAssertFalse(bare.isUsableGlobally)

        let bareFunctionKey = WindowShortcut(keyCode: 96, modifiers: 0) // F5
        XCTAssertTrue(bareFunctionKey.isUsableGlobally, "fn-less function keys are allowed bare")
    }

    // MARK: - Modifier conversion (recorder)

    @MainActor
    func testCarbonModifierConversionFromAppKitFlags() {
        XCTAssertEqual(ShortcutRecorder.carbonModifiers(from: [.control, .option]), HotKeyModifier.controlOption)
        XCTAssertEqual(ShortcutRecorder.carbonModifiers(from: [.command]), HotKeyModifier.command)
        XCTAssertEqual(ShortcutRecorder.carbonModifiers(from: [.shift, .command]), HotKeyModifier.shift | HotKeyModifier.command)
        XCTAssertEqual(ShortcutRecorder.carbonModifiers(from: []), 0)
    }

    @MainActor
    func testRecorderNormalizesKeypadEnterToReturn() {
        XCTAssertEqual(ShortcutRecorder.normalizedKeyCode(HotKeyCode.keypadEnter), HotKeyCode.returnKey)
        XCTAssertEqual(ShortcutRecorder.normalizedKeyCode(HotKeyCode.returnKey), HotKeyCode.returnKey)
        XCTAssertEqual(ShortcutRecorder.normalizedKeyCode(HotKeyCode.left), HotKeyCode.left)
    }

    // MARK: - Store

    private func scratchDefaults() -> UserDefaults {
        let suite = "test.windowmanager.shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testEffectiveShortcutsFallBackToDefaults() {
        let store = WindowShortcutStore(defaults: scratchDefaults())
        let effective = store.effectiveShortcuts()
        XCTAssertEqual(effective[.leftHalf], WindowAction.leftHalf.defaultShortcut)
        XCTAssertEqual(effective[.maximize], WindowAction.maximize.defaultShortcut)
        XCTAssertNil(effective[.topLeft], "actions without a default start unassigned")
    }

    func testSavePersistsOverrideAndKeepsOtherDefaults() {
        let store = WindowShortcutStore(defaults: scratchDefaults())
        let custom = WindowShortcut(keyCode: 0x00, modifiers: HotKeyModifier.command | HotKeyModifier.option)
        store.save(custom, for: .leftHalf)

        let effective = store.effectiveShortcuts()
        XCTAssertEqual(effective[.leftHalf], custom)
        XCTAssertEqual(effective[.rightHalf], WindowAction.rightHalf.defaultShortcut)
        XCTAssertEqual(store.storedShortcuts(), [.leftHalf: custom], "only the override is persisted")
    }

    func testSaveAssignsActionsWithoutDefaults() {
        let store = WindowShortcutStore(defaults: scratchDefaults())
        let custom = WindowShortcut(keyCode: 105, modifiers: 0) // bare F13
        store.save(custom, for: .topLeft)
        XCTAssertEqual(store.effectiveShortcuts()[.topLeft], custom)
    }

    func testResetRestoresDefaults() {
        let store = WindowShortcutStore(defaults: scratchDefaults())
        store.save(WindowShortcut(keyCode: 0x0B, modifiers: HotKeyModifier.command), for: .leftHalf)
        store.reset()
        XCTAssertEqual(store.effectiveShortcuts()[.leftHalf], WindowAction.leftHalf.defaultShortcut)
        XCTAssertTrue(store.storedShortcuts().isEmpty)
    }

    /// The upgrade hazard: a user bound ⌃⌥⌫ to Center in 0.14.0, then Restore shipped with ⌃⌥⌫ as
    /// its default. Both actions holding it means two Carbon registrations for one combination and
    /// one keypress firing both, so the shipped default has to yield to the explicit binding.
    func testANewDefaultYieldsToAPreExistingUserOverride() {
        let store = WindowShortcutStore(defaults: scratchDefaults())
        guard let restoreDefault = WindowAction.restorePrevious.defaultShortcut else {
            return XCTFail("restore should ship with a default")
        }
        store.save(restoreDefault, for: .center)

        let effective = store.effectiveShortcuts()
        XCTAssertEqual(effective[.center], restoreDefault, "the user's own binding wins")
        XCTAssertNil(effective[.restorePrevious], "the colliding default must not also register")
        XCTAssertEqual(effective[.leftHalf], WindowAction.leftHalf.defaultShortcut, "unrelated defaults are untouched")
    }

    /// Whichever default a future release adds, no combination may ever come back bound twice.
    func testEffectiveShortcutsNeverBindOneCombinationTwice() {
        for action in WindowAction.allCases {
            guard let shortcut = action.defaultShortcut else { continue }
            let store = WindowShortcutStore(defaults: scratchDefaults())
            store.save(shortcut, for: .topLeft) // .topLeft ships with no default of its own

            let effective = store.effectiveShortcuts()
            XCTAssertEqual(effective[.topLeft], shortcut)
            XCTAssertNil(effective[action], "\(action.rawValue) kept a default the user had claimed")
            XCTAssertEqual(
                Set(effective.values).count,
                effective.count,
                "two actions share a combination after overriding \(action.rawValue)'s default"
            )
        }
    }

    @MainActor
    func testControllerDropsADefaultThatCollidesWithAStoredOverride() {
        let defaults = scratchDefaults()
        guard let restoreDefault = WindowAction.restorePrevious.defaultShortcut else {
            return XCTFail("restore should ship with a default")
        }
        WindowShortcutStore(defaults: defaults).save(restoreDefault, for: .center)

        let controller = WindowManagerController(defaults: defaults)
        defer { controller.unregisterHotKeys() }

        XCTAssertEqual(controller.shortcut(for: .center), restoreDefault)
        XCTAssertNil(controller.shortcut(for: .restorePrevious))
        XCTAssertEqual(controller.actionUsing(restoreDefault), .center, "exactly one action answers for the combination")
        XCTAssertEqual(
            Set(controller.shortcuts.values).count,
            controller.shortcuts.count,
            "the registrar would claim the same combination twice"
        )
    }

    func testStoreIgnoresCorruptEntries() {
        let defaults = scratchDefaults()
        defaults.set(
            ["leftHalf": "not-a-shortcut", "noSuchAction": "1,2", "rightHalf": "11,256"],
            forKey: DefaultsKey.windowManagerShortcuts
        )
        let store = WindowShortcutStore(defaults: defaults)
        XCTAssertEqual(store.storedShortcuts(), [.rightHalf: WindowShortcut(keyCode: 11, modifiers: 256)])
    }

    // MARK: - Controller assignment rules

    @MainActor
    func testAssignShortcutRefusesDuplicatesWithinTheTool() {
        let controller = WindowManagerController(defaults: scratchDefaults())
        defer { controller.unregisterHotKeys() }

        let rightHalfShortcut = WindowAction.rightHalf.defaultShortcut!
        XCTAssertEqual(controller.assignShortcut(rightHalfShortcut, to: .leftHalf), .conflict(.rightHalf))
        // Re-assigning an action its own current shortcut is fine (not a conflict with itself).
        XCTAssertEqual(controller.assignShortcut(rightHalfShortcut, to: .rightHalf), .assigned)
    }

    @MainActor
    func testAssignShortcutRefusesModifierlessKeys() {
        let controller = WindowManagerController(defaults: scratchDefaults())
        defer { controller.unregisterHotKeys() }

        XCTAssertEqual(
            controller.assignShortcut(WindowShortcut(keyCode: 0x00, modifiers: 0), to: .leftHalf),
            .needsModifiers
        )
        XCTAssertEqual(
            controller.assignShortcut(WindowShortcut(keyCode: 0x00, modifiers: HotKeyModifier.shift), to: .leftHalf),
            .needsModifiers
        )
    }

    @MainActor
    func testAssignShortcutPersistsAndPublishes() {
        let defaults = scratchDefaults()
        let controller = WindowManagerController(defaults: defaults)
        defer { controller.unregisterHotKeys() }

        let custom = WindowShortcut(keyCode: 0x0E, modifiers: HotKeyModifier.command | HotKeyModifier.control) // ⌘⌃E
        XCTAssertEqual(controller.assignShortcut(custom, to: .almostMaximize), .assigned)
        XCTAssertEqual(controller.shortcut(for: .almostMaximize), custom)

        // A fresh controller over the same defaults sees the persisted assignment.
        let reloaded = WindowManagerController(defaults: defaults)
        defer { reloaded.unregisterHotKeys() }
        XCTAssertEqual(reloaded.shortcut(for: .almostMaximize), custom)
    }

    @MainActor
    func testResetShortcutsToDefaultsClearsOverrides() {
        let controller = WindowManagerController(defaults: scratchDefaults())
        defer { controller.unregisterHotKeys() }

        controller.assignShortcut(WindowShortcut(keyCode: 0x0B, modifiers: HotKeyModifier.command | HotKeyModifier.option), to: .leftHalf)
        controller.resetShortcutsToDefaults()
        XCTAssertEqual(controller.shortcut(for: .leftHalf), WindowAction.leftHalf.defaultShortcut)
    }
}
