import XCTest
@testable import DMonteCore

/// Table-driven tests for the Volume Mixer's pure processing-decision logic:
/// `AppVolumeMixerController.shouldRunProcessing` (the predicate shared by the
/// 2-second reconciler and `setGain`) and `unmuteRestoreGain` (the per-app
/// unmute restore rule). Both are pure, nonisolated functions — no CoreAudio,
/// no main-actor state — so these run on any machine, headless or not.
final class VolumeMixerReconcileTests: XCTestCase {

    private func shouldRun(
        isActive: Bool = true,
        gain: Float = 1,
        hasCustomRoute: Bool = false,
        manualOverride: Bool? = nil,
        isIgnored: Bool = false
    ) -> Bool {
        AppVolumeMixerController.shouldRunProcessing(
            isActive: isActive,
            gain: gain,
            hasCustomRoute: hasCustomRoute,
            manualOverride: manualOverride,
            isIgnored: isIgnored
        )
    }

    // MARK: - Automatic policy (no manual override)

    // MARK: - Ignore is a hard stop

    /// Ignoring an app is a denylist action, so its engine must be released regardless of the
    /// settings that would otherwise keep it running — attenuation, a custom route, or an
    /// explicit play override. This is what makes an ignored app play back untouched.
    func testIgnoredAttenuatedTargetDoesNotProcess() {
        XCTAssertFalse(shouldRun(gain: 0.4, isIgnored: true))
    }

    func testIgnoredMutedTargetDoesNotProcess() {
        XCTAssertFalse(shouldRun(gain: 0, isIgnored: true))
    }

    func testIgnoredTargetWithCustomRouteDoesNotProcess() {
        XCTAssertFalse(shouldRun(gain: 1, hasCustomRoute: true, isIgnored: true))
    }

    func testIgnoreOverridesAnExplicitPlay() {
        XCTAssertFalse(shouldRun(gain: 0.4, manualOverride: true, isIgnored: true))
    }

    /// Un-ignoring restores normal policy: the gain was left persisted, so an attenuated app
    /// resumes processing at its old level once it is no longer ignored.
    func testUnignoringRestoresProcessing() {
        XCTAssertTrue(shouldRun(gain: 0.4, isIgnored: false))
    }

    func testAttenuatedActiveTargetProcesses() {
        XCTAssertTrue(shouldRun(gain: 0.5))
    }

    func testMutedActiveTargetProcesses() {
        XCTAssertTrue(shouldRun(gain: 0))
    }

    func testUnityGainDefaultRouteTargetDoesNotProcess() {
        XCTAssertFalse(shouldRun(gain: 1))
    }

    func testGainJustBelowThresholdProcesses() {
        XCTAssertTrue(shouldRun(gain: 0.998))
    }

    func testGainAtThresholdDoesNotProcess() {
        // 0.999 is treated as unity, matching the long-standing reconcile cutoff.
        XCTAssertFalse(shouldRun(gain: 0.999))
    }

    func testCustomRouteProcessesEvenAtUnityGain() {
        XCTAssertTrue(shouldRun(gain: 1, hasCustomRoute: true))
    }

    // MARK: - Liveness

    /// `isRunningOutput` is deliberately not an input to the predicate: a
    /// paused-but-active attenuated app must keep its engine so resume stays
    /// attenuated. The only liveness input is `isActive`, and an inactive
    /// target (audio session fully torn down) never processes — not even with
    /// a force-on override, since there is nothing left to tap.
    func testInactiveTargetNeverProcesses() {
        XCTAssertFalse(shouldRun(isActive: false, gain: 0.2))
        XCTAssertFalse(shouldRun(isActive: false, gain: 1, hasCustomRoute: true))
        XCTAssertFalse(shouldRun(isActive: false, gain: 0.2, manualOverride: true))
        XCTAssertFalse(shouldRun(isActive: false, gain: 1, manualOverride: false))
    }

    // MARK: - Manual overrides

    func testForceOnWinsAtUnityGainAndDefaultRoute() {
        // Pressing play at unity gain must not be auto-stopped 2s later.
        XCTAssertTrue(shouldRun(gain: 1, manualOverride: true))
    }

    func testForceOffWinsWhileAttenuated() {
        // Pressing stop while attenuated must not be undone by the reconciler.
        XCTAssertFalse(shouldRun(gain: 0.3, manualOverride: false))
    }

    func testForceOffWinsWithCustomRoute() {
        XCTAssertFalse(shouldRun(gain: 1, hasCustomRoute: true, manualOverride: false))
    }

    func testNilOverrideFallsBackToAutomaticPolicy() {
        XCTAssertTrue(shouldRun(gain: 0.4, manualOverride: nil))
        XCTAssertFalse(shouldRun(gain: 1, manualOverride: nil))
    }

    func testOverrideAlwaysWinsForActiveTargetsAcrossTheGrid() {
        for gain: Float in [0, 0.3, 0.998, 0.999, 1] {
            for hasCustomRoute in [false, true] {
                XCTAssertTrue(
                    shouldRun(gain: gain, hasCustomRoute: hasCustomRoute, manualOverride: true),
                    "force-on must win for gain \(gain), customRoute \(hasCustomRoute)"
                )
                XCTAssertFalse(
                    shouldRun(gain: gain, hasCustomRoute: hasCustomRoute, manualOverride: false),
                    "force-off must win for gain \(gain), customRoute \(hasCustomRoute)"
                )
            }
        }
    }

    // MARK: - Unmute restore

    func testUnmuteRestoresStashedLevel() {
        XCTAssertEqual(AppVolumeMixerController.unmuteRestoreGain(stashed: 0.42), 0.42, accuracy: 0.0001)
    }

    func testUnmuteWithoutStashFallsBackToFullVolume() {
        XCTAssertEqual(AppVolumeMixerController.unmuteRestoreGain(stashed: nil), 1)
    }

    func testUnmuteWithNearSilentStashFallsBackToFullVolume() {
        XCTAssertEqual(AppVolumeMixerController.unmuteRestoreGain(stashed: 0), 1)
        XCTAssertEqual(AppVolumeMixerController.unmuteRestoreGain(stashed: 0.0005), 1)
    }

    func testUnmuteClampsOutOfRangeStash() {
        XCTAssertEqual(AppVolumeMixerController.unmuteRestoreGain(stashed: 1.5), 1)
        XCTAssertEqual(AppVolumeMixerController.unmuteRestoreGain(stashed: 0.75), 0.75, accuracy: 0.0001)
    }
}
