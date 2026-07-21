import AppKit
import Combine
import XCTest
@testable import DMonteCore

/// Headless coverage for Grab Text's global capture hotkey: how the shortcut is persisted and
/// resolved, how a capture attempt is classified (so a missing Screen Recording grant never
/// masquerades as "no text found"), and how the controller behaves when the hotkey fires — the
/// in-flight guard, the copy-automatically preference, and a registration macOS refuses.
///
/// Nothing here touches Carbon or `screencapture`: the controller takes an injectable registrar
/// and an injectable capture, which is what makes the failure paths reachable at all. A real
/// `RegisterEventHotKey` can neither be made to fail on demand nor be safely left registered by a
/// test process.
final class GrabTextHotKeyTests: XCTestCase {

    private func scratchDefaults() -> UserDefaults {
        let suite = "test.grabtext.hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Shortcut persistence

    func testEffectiveShortcutFallsBackToTheBuiltInDefault() {
        let store = GrabTextShortcutStore(defaults: scratchDefaults())
        XCTAssertEqual(store.effectiveShortcut(), GrabTextShortcutStore.defaultShortcut)
        XCTAssertEqual(GrabTextShortcutStore.defaultShortcut.displayString, "⌃⌥G")
    }

    func testSavedShortcutRoundTripsThroughDefaults() {
        let defaults = scratchDefaults()
        let custom = WindowShortcut(keyCode: 0x11, modifiers: HotKeyModifier.command | HotKeyModifier.shift) // ⇧⌘T
        GrabTextShortcutStore(defaults: defaults).save(custom)

        // A fresh store over the same suite is what the next launch sees.
        XCTAssertEqual(GrabTextShortcutStore(defaults: defaults).effectiveShortcut(), custom)
    }

    func testDisableIsDistinctFromNeverHavingChosen() {
        let defaults = scratchDefaults()
        let store = GrabTextShortcutStore(defaults: defaults)

        store.disable()
        XCTAssertNil(store.effectiveShortcut(), "an explicit disable must not fall back to the default")
        XCTAssertEqual(
            defaults.string(forKey: DefaultsKey.grabTextCaptureShortcut),
            GrabTextShortcutStore.disabledStorageValue
        )

        store.reset()
        XCTAssertEqual(store.effectiveShortcut(), GrabTextShortcutStore.defaultShortcut)
    }

    func testCorruptStoredValueFallsBackToTheDefaultRatherThanNoHotKey() {
        let defaults = scratchDefaults()
        defaults.set("not-a-shortcut", forKey: DefaultsKey.grabTextCaptureShortcut)
        XCTAssertEqual(GrabTextShortcutStore(defaults: defaults).effectiveShortcut(), GrabTextShortcutStore.defaultShortcut)
    }

    func testDefaultShortcutIsSafeToClaimGlobally() {
        XCTAssertTrue(GrabTextShortcutStore.defaultShortcut.isUsableGlobally)
    }

    // MARK: - Capture classification

    func testCaptureWithAccessReportsTextAndCancellation() {
        XCTAssertEqual(
            GrabTextKit.classifyCapture(fileWritten: true, recognizedText: "hello", hasScreenRecordingAccess: true),
            .success("hello")
        )
        // A grab of a genuinely text-free region is a success with nothing in it, not a failure.
        XCTAssertEqual(
            GrabTextKit.classifyCapture(fileWritten: true, recognizedText: "", hasScreenRecordingAccess: true),
            .success("")
        )
        XCTAssertEqual(
            GrabTextKit.classifyCapture(fileWritten: false, recognizedText: "", hasScreenRecordingAccess: true),
            .cancelled
        )
    }

    func testCaptureWithoutAccessReportsThePermissionRatherThanAnEmptyResult() {
        // No file at all: TCC blocked the capture outright.
        XCTAssertEqual(
            GrabTextKit.classifyCapture(fileWritten: false, recognizedText: "", hasScreenRecordingAccess: false),
            .needsScreenRecordingPermission
        )
        // A file was written but everything in it was redacted — the empty-result trap.
        XCTAssertEqual(
            GrabTextKit.classifyCapture(fileWritten: true, recognizedText: "", hasScreenRecordingAccess: false),
            .needsScreenRecordingPermission
        )
    }

    func testTextThatCameBackDespiteAMissingGrantIsStillASuccess() {
        // The preflight can lag a grant given during this very capture; believe the pixels.
        XCTAssertEqual(
            GrabTextKit.classifyCapture(fileWritten: true, recognizedText: "hi", hasScreenRecordingAccess: false),
            .success("hi")
        )
    }

    // MARK: - Controller: dispatch through the hotkey

    /// Builds a controller whose hotkey registration is faked, and hands back the registered
    /// handler so a test can "press" the shortcut.
    @MainActor
    private func makeController(
        defaults: UserDefaults,
        capture: @escaping GrabTextCapture,
        hasScreenRecordingAccess: Bool = true,
        secureInput: @escaping @MainActor () -> Bool = { false },
        registrarError: GlobalHotKeyRegistrationError? = nil
    ) -> (controller: GrabTextController, press: () -> Void) {
        let box = HandlerBox()
        let controller = GrabTextController(
            defaults: defaults,
            capture: capture,
            screenRecordingAccess: { hasScreenRecordingAccess },
            secureInput: secureInput,
            registrar: { _, _, handler in
                if let registrarError { throw registrarError }
                box.handler = handler
                return NSObject()
            }
        )
        return (controller, { box.handler?() })
    }

    /// Holds the registered hotkey handler. A class so the registrar closure can write to it.
    @MainActor
    private final class HandlerBox {
        var handler: (@Sendable () -> Void)?
    }

    @MainActor
    func testHotKeyPressStartsACaptureAndCopiesAutomatically() async {
        let counter = CallCounter()
        let (controller, press) = makeController(
            defaults: scratchDefaults(),
            capture: {
                await counter.increment()
                return .success("grabbed text")
            }
        )
        controller.registerHotKey()
        XCTAssertNil(controller.registrationFailure)

        // The handler runs on the main run loop, exactly as Carbon delivers it, and starts the
        // capture synchronously — so `isGrabbing` is already true when it returns.
        press()
        XCTAssertTrue(controller.isGrabbing)

        await settle()
        let captures = await counter.value()
        XCTAssertEqual(captures, 1)
        XCTAssertFalse(controller.isGrabbing)
        XCTAssertEqual(controller.recognizedText, "grabbed text")
        XCTAssertEqual(controller.statusMessage, "Copied to clipboard.")
    }

    @MainActor
    func testSecondCaptureIsIgnoredWhileOneIsInFlight() async {
        let counter = CallCounter()
        let (controller, press) = makeController(
            defaults: scratchDefaults(),
            capture: {
                await counter.increment()
                return .success("once")
            }
        )
        controller.registerHotKey()

        let first = controller.startGrab()
        XCTAssertNotNil(first)
        // Both a second hotkey press and a second button press must be dropped: the region selector
        // from the first is still up.
        press()
        XCTAssertNil(controller.startGrab(), "a second grab while one is in flight must be refused")

        await first?.value
        let afterFirst = await counter.value()
        XCTAssertEqual(afterFirst, 1, "only one capture may ever be running")

        // Once it finishes, the tool is available again.
        XCTAssertNotNil(controller.startGrab())
        await settle()
        let afterSecond = await counter.value()
        XCTAssertEqual(afterSecond, 2)
    }

    @MainActor
    func testRegistrationFailureIsSurfacedRatherThanSwallowed() {
        let (controller, press) = makeController(
            defaults: scratchDefaults(),
            capture: { .success("never runs") },
            registrarError: .registrationFailed(-9878) // eventHotKeyExistsErr
        )
        controller.registerHotKey()

        XCTAssertEqual(controller.registrationFailure, -9878, "the OSStatus must reach the UI")
        press() // no handler was ever registered, so this is a no-op
        XCTAssertFalse(controller.isGrabbing)
    }

    @MainActor
    func testRegistrationFailureClearsAfterAWorkingShortcutIsAssigned() {
        let defaults = scratchDefaults()
        let attempts = FailureSchedule(failFirst: 1)
        let controller = GrabTextController(
            defaults: defaults,
            capture: { .cancelled },
            screenRecordingAccess: { true },
            registrar: { _, _, _ in
                if attempts.shouldFail() { throw GlobalHotKeyRegistrationError.registrationFailed(-9878) }
                return NSObject()
            }
        )
        controller.registerHotKey()
        XCTAssertEqual(controller.registrationFailure, -9878)

        let replacement = WindowShortcut(keyCode: 0x11, modifiers: HotKeyModifier.command | HotKeyModifier.control)
        XCTAssertEqual(controller.assignShortcut(replacement), .assigned)
        XCTAssertNil(controller.registrationFailure, "re-registering under a free combination must clear the alarm")
        XCTAssertEqual(controller.shortcut, replacement)
    }

    @MainActor
    func testDisabledShortcutRegistersNothingAndReportsNoFailure() {
        var registrarCalls = 0
        let controller = GrabTextController(
            defaults: scratchDefaults(),
            capture: { .cancelled },
            screenRecordingAccess: { true },
            registrar: { _, _, _ in
                registrarCalls += 1
                return NSObject()
            }
        )
        controller.disableShortcut()
        controller.registerHotKey()

        XCTAssertNil(controller.shortcut)
        XCTAssertEqual(registrarCalls, 0, "an off shortcut must not claim anything")
        XCTAssertNil(controller.registrationFailure, "off is a choice, not a failure")
    }

    @MainActor
    func testAssignRefusesCombinationsThatWouldSwallowTyping() {
        let (controller, _) = makeController(defaults: scratchDefaults(), capture: { .cancelled })

        XCTAssertEqual(controller.assignShortcut(WindowShortcut(keyCode: HotKeyCode.g, modifiers: 0)), .needsModifiers)
        XCTAssertEqual(
            controller.assignShortcut(WindowShortcut(keyCode: HotKeyCode.g, modifiers: HotKeyModifier.shift)),
            .needsModifiers
        )
        XCTAssertEqual(controller.shortcut, GrabTextShortcutStore.defaultShortcut, "a refused assignment changes nothing")
    }

    @MainActor
    func testAssignedShortcutSurvivesARelaunch() {
        let defaults = scratchDefaults()
        let (controller, _) = makeController(defaults: defaults, capture: { .cancelled })
        let custom = WindowShortcut(keyCode: 0x0E, modifiers: HotKeyModifier.command | HotKeyModifier.control) // ⌃⌘E
        XCTAssertEqual(controller.assignShortcut(custom), .assigned)

        let (relaunched, _) = makeController(defaults: defaults, capture: { .cancelled })
        XCTAssertEqual(relaunched.shortcut, custom)
    }

    // MARK: - Controller: what the user is told

    @MainActor
    func testMissingScreenRecordingAccessIsExplainedInsteadOfLookingEmpty() async {
        let (controller, press) = makeController(
            defaults: scratchDefaults(),
            capture: { .needsScreenRecordingPermission },
            hasScreenRecordingAccess: false
        )
        controller.registerHotKey()

        var pulledWindowForward = false
        controller.onHotKeyResultNeedsAttention = { pulledWindowForward = true }

        press()
        await settle()

        XCTAssertEqual(controller.statusMessage, GrabTextController.permissionMessage)
        XCTAssertTrue(controller.statusMessage.contains("Screen Recording"))
        XCTAssertTrue(controller.recognizedText.isEmpty)
        XCTAssertFalse(controller.hasScreenRecordingAccess)
        XCTAssertTrue(pulledWindowForward, "a hotkey grab has no window on screen, so the problem must fetch one")
    }

    @MainActor
    func testHotKeyGrabStaysInvisibleWhenItAutoCopies() async {
        let (controller, press) = makeController(defaults: scratchDefaults(), capture: { .success("quiet") })
        controller.registerHotKey()
        controller.copyAutomatically = true

        var pulledWindowForward = false
        controller.onHotKeyResultNeedsAttention = { pulledWindowForward = true }

        press()
        await settle()

        XCTAssertFalse(pulledWindowForward, "the whole point of the shortcut is not interrupting the user")
    }

    @MainActor
    func testHotKeyGrabShowsTheWindowWhenNothingWasCopied() async {
        let defaults = scratchDefaults()
        defaults.set(false, forKey: DefaultsKey.grabTextCopyAutomatically)
        let (controller, press) = makeController(defaults: defaults, capture: { .success("kept in the window") })
        controller.registerHotKey()
        XCTAssertFalse(controller.copyAutomatically, "the existing preference must be honoured by the hotkey path")

        var pulledWindowForward = false
        controller.onHotKeyResultNeedsAttention = { pulledWindowForward = true }

        press()
        await settle()

        XCTAssertEqual(controller.recognizedText, "kept in the window")
        XCTAssertTrue(pulledWindowForward, "text nobody copied only exists in the window, so the window has to appear")
    }

    @MainActor
    func testCancelledHotKeyGrabDoesNotBotherTheUser() async {
        let (controller, press) = makeController(defaults: scratchDefaults(), capture: { .cancelled })
        controller.registerHotKey()

        var pulledWindowForward = false
        controller.onHotKeyResultNeedsAttention = { pulledWindowForward = true }

        press()
        await settle()

        XCTAssertFalse(pulledWindowForward, "they pressed Esc; they know what happened")
        XCTAssertTrue(controller.statusMessage.contains("cancelled"))
    }

    @MainActor
    func testUncopiedTextIsFlaggedSoTheWindowCanSayItWasNotCopied() async {
        let defaults = scratchDefaults()
        defaults.set(false, forKey: DefaultsKey.grabTextCopyAutomatically)
        let (controller, press) = makeController(defaults: defaults, capture: { .success("only in the window") })
        controller.registerHotKey()

        press()
        await settle()

        // The sentence explaining that nothing was copied lives in `statusMessage`, which the
        // result box replaces with the text itself as soon as there is one. `resultNeedsCopying`
        // is what lets the window render it anyway — without it the instruction is unreachable UI.
        XCTAssertTrue(controller.resultNeedsCopying)
        XCTAssertTrue(controller.statusMessage.contains("Press Copy"))

        controller.copyRecognizedText()
        XCTAssertFalse(controller.resultNeedsCopying, "once it is on the clipboard there is nothing left to say")
        XCTAssertEqual(controller.statusMessage, "Copied to clipboard.")
    }

    @MainActor
    func testAutoCopiedTextIsNotFlaggedAsNeedingACopy() async {
        let (controller, press) = makeController(defaults: scratchDefaults(), capture: { .success("straight to the clipboard") })
        controller.registerHotKey()
        controller.copyAutomatically = true

        press()
        await settle()

        XCTAssertFalse(controller.resultNeedsCopying)
    }

    @MainActor
    func testMissingScreenRecordingInterruptsOnceRatherThanOnEveryPress() async {
        let (controller, press) = makeController(
            defaults: scratchDefaults(),
            capture: { .needsScreenRecordingPermission },
            hasScreenRecordingAccess: false
        )
        controller.registerHotKey()

        var interruptions = 0
        controller.onHotKeyResultNeedsAttention = { interruptions += 1 }

        press()
        await settle()
        XCTAssertEqual(interruptions, 1, "a missing grant has to be explained")

        // While the grant is missing an Esc-cancel is classified as a permission problem, so
        // surfacing it every time would steal activation on every cancelled press — the exact
        // interruption the shortcut exists to avoid.
        press()
        await settle()
        press()
        await settle()
        XCTAssertEqual(interruptions, 1, "saying it again on every press is the interruption, not the fix")
        XCTAssertEqual(controller.statusMessage, GrabTextController.permissionMessage, "the window still explains it")
    }

    @MainActor
    func testMissingScreenRecordingIsAnnouncedAgainAfterTheGrantIsLostASecondTime() async {
        let grant = EnvironmentSwitch(isOn: false)
        let box = HandlerBox()
        let controller = GrabTextController(
            defaults: scratchDefaults(),
            capture: { .needsScreenRecordingPermission },
            screenRecordingAccess: { MainActor.assumeIsolated { grant.isOn } },
            secureInput: { false },
            registrar: { _, _, handler in
                box.handler = handler
                return NSObject()
            }
        )
        controller.registerHotKey()

        var interruptions = 0
        controller.onHotKeyResultNeedsAttention = { interruptions += 1 }

        box.handler?()
        await settle()
        XCTAssertEqual(interruptions, 1)

        // The user grants it; the one-shot has to re-arm, or a later revocation would be silent.
        grant.isOn = true
        controller.refreshEnvironment()
        XCTAssertTrue(controller.hasScreenRecordingAccess)

        grant.isOn = false
        box.handler?()
        await settle()
        XCTAssertEqual(interruptions, 2, "a grant that is lost again is a new problem, not the old one")
    }

    // MARK: - Controller: the environment behind the window

    @MainActor
    func testSecureInputIsReReadRatherThanTrustedFromLaunch() {
        let secure = EnvironmentSwitch(isOn: false)
        let (controller, _) = makeController(
            defaults: scratchDefaults(),
            capture: { .cancelled },
            secureInput: { secure.isOn }
        )
        controller.registerHotKey()
        XCTAssertFalse(controller.secureInputBlocked)

        // Secure Input comes on behind our back — a password field, the lock screen. macOS
        // announces nothing, so only looking again can tell.
        secure.isOn = true
        controller.refreshEnvironment()
        XCTAssertTrue(controller.secureInputBlocked, "the hint has to say why the shortcut stopped working")

        // And the other direction: a warning that outlives its cause is just as wrong.
        secure.isOn = false
        controller.refreshEnvironment()
        XCTAssertFalse(controller.secureInputBlocked, "the warning must not outlive the block it describes")
    }

    @MainActor
    func testEnvironmentPollNoticesSecureInputTurningOnWhileTheWindowIsOpen() async {
        let secure = EnvironmentSwitch(isOn: false)
        let (controller, _) = makeController(
            defaults: scratchDefaults(),
            capture: { .cancelled },
            secureInput: { secure.isOn }
        )
        controller.registerHotKey()

        // The window is on screen and stays there. Its `onAppear` has already fired and can never
        // fire again — the hosting controller is built once — so the poll is the only thing that
        // can keep this true.
        controller.beginEnvironmentMonitoring(interval: 0.02)
        XCTAssertFalse(controller.secureInputBlocked)

        let blocked = expectation(description: "the poll surfaces Secure Input turning on")
        blocked.assertForOverFulfill = false
        let subscription = controller.$secureInputBlocked
            .filter { $0 }
            .sink { _ in blocked.fulfill() }

        secure.isOn = true
        await fulfillment(of: [blocked], timeout: 5)
        subscription.cancel()
        controller.endEnvironmentMonitoring()

        XCTAssertTrue(controller.secureInputBlocked)
    }

    @MainActor
    func testEnvironmentPollStopsWhenTheWindowLeavesTheScreen() async {
        let secure = EnvironmentSwitch(isOn: false)
        let (controller, _) = makeController(
            defaults: scratchDefaults(),
            capture: { .cancelled },
            secureInput: { secure.isOn }
        )

        controller.beginEnvironmentMonitoring(interval: 0.02)
        controller.endEnvironmentMonitoring()

        // Nobody can read the hint, so nothing should be spent keeping it fresh.
        secure.isOn = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(controller.secureInputBlocked, "the poll must not outlive the window it serves")

        // And it comes back when the window does.
        controller.beginEnvironmentMonitoring(interval: 0.02)
        controller.endEnvironmentMonitoring()
        XCTAssertTrue(controller.secureInputBlocked, "showing the window re-reads immediately, not a tick later")
    }

    @MainActor
    func testCopyAutomaticallyIsPersistedOnChange() {
        let defaults = scratchDefaults()
        let (controller, _) = makeController(defaults: defaults, capture: { .cancelled })
        XCTAssertTrue(controller.copyAutomatically, "unset means on — the tool exists to fill the clipboard")

        controller.copyAutomatically = false
        XCTAssertFalse(defaults.bool(forKey: DefaultsKey.grabTextCopyAutomatically))

        let (relaunched, _) = makeController(defaults: defaults, capture: { .cancelled })
        XCTAssertFalse(relaunched.copyAutomatically)
    }

    // MARK: - Helpers

    /// Lets the capture task and its main-actor completion run. The capture closures under test
    /// return immediately, so a couple of hops are enough; the loop just avoids depending on the
    /// exact number.
    @MainActor
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    /// Counts capture invocations from the (non-isolated) capture closure.
    private actor CallCounter {
        private var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    /// A system flag the test can flip mid-run — Secure Input, the Screen Recording grant. Both
    /// are read through injected closures precisely because macOS gives no way to script them.
    @MainActor
    private final class EnvironmentSwitch {
        var isOn: Bool
        init(isOn: Bool) { self.isOn = isOn }
    }

    /// Makes the first N registration attempts fail. Main-actor confined: the registrar runs there.
    @MainActor
    private final class FailureSchedule {
        private var remaining: Int
        init(failFirst: Int) { remaining = failFirst }
        func shouldFail() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
