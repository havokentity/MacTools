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

    // MARK: - Stop-processing persistence

    /// Only the force-off keys are persisted, sorted; a force-on is session-scoped and left out.
    func testStoppedKeysArePersistedButPlaysAreNot() {
        let overrides: [String: Bool] = ["b.app": false, "a.app": false, "c.app": true]
        XCTAssertEqual(
            AppVolumeMixerController.stoppedKeys(from: overrides),
            ["a.app", "b.app"]
        )
    }

    func testNoStoppedKeysProducesAnEmptyList() {
        XCTAssertTrue(AppVolumeMixerController.stoppedKeys(from: ["a.app": true]).isEmpty)
        XCTAssertTrue(AppVolumeMixerController.stoppedKeys(from: [:]).isEmpty)
    }

    /// Round trip: what is persisted rebuilds a map that stops exactly those apps and no others.
    func testStoppedKeysRoundTripToForceOffOverrides() {
        let restored = AppVolumeMixerController.overrides(fromStoppedKeys: ["a.app", "b.app"])
        XCTAssertEqual(restored, ["a.app": false, "b.app": false])
        // And that map yields no processing for a stopped, still-attenuated app.
        XCTAssertFalse(shouldRun(gain: 0.4, manualOverride: restored["a.app"]))
    }

    func testRestoredStopSurvivesTheReconciler() {
        // The exact reported bug: stop an attenuated app, relaunch, it must stay stopped.
        let persisted = AppVolumeMixerController.stoppedKeys(from: ["spotify": false])
        let afterRelaunch = AppVolumeMixerController.overrides(fromStoppedKeys: persisted)
        XCTAssertFalse(
            shouldRun(gain: 0.4, manualOverride: afterRelaunch["spotify"]),
            "A stopped app must not be re-tapped by the automatic policy after a relaunch"
        )
    }

    /// Quitting must not look like the footer gesture. `stopProcessing()` marks every live engine
    /// force-off, and that write is persisted — so routing teardown through it brings back every app
    /// that merely happened to be playing at quit as a stop the user never pressed, with the row's
    /// slider reading 40% while the audio plays at full volume. Asserted at the source level because
    /// the real path runs through CoreAudio and the shared prefs domain, neither of which a unit
    /// test may touch.
    func testQuitTearsDownWithoutPersistingAStop() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/DMonteCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/DMonteVolumeMixerApp/VolumeMixerAppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("shutdownProcessing()"),
            "Quit must release the taps through the non-persisting teardown"
        )
        XCTAssertFalse(
            source.contains("controller?.stopProcessing()"),
            "stopProcessing() persists a force-off per live engine — it is the footer gesture, not teardown"
        )
    }

    /// The stopped-keys list is read back off disk, so it is not ours to trust: a hand-edited or
    /// half-merged prefs plist can carry the same key twice. Building the map with
    /// `Dictionary(uniqueKeysWithValues:)` traps on that, which crashes the tool on launch — for a
    /// value whose meaning is unambiguous. A repeat must collapse, not kill the process.
    func testDuplicatePersistedKeysCollapseInsteadOfCrashing() {
        let restored = AppVolumeMixerController.overrides(fromStoppedKeys: ["a.app", "a.app", "b.app"])
        XCTAssertEqual(restored, ["a.app": false, "b.app": false])
        XCTAssertFalse(
            shouldRun(gain: 0.4, manualOverride: restored["a.app"]),
            "A duplicated key still means stopped"
        )
    }

}
