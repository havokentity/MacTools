import XCTest
import CoreAudio
@testable import DMonteCore

/// `MicControlKit` is pure, so unlike the CoreAudio-facing kits these assertions
/// are exact rather than environment-tolerant. The glyph mapping gets the most
/// attention: the tool's entire value is that a glance at the menu bar tells you
/// whether you are muted, so a regression there is a regression in the product.
final class MicControlKitTests: XCTestCase {

    // MARK: - State derivation

    func testNoDefaultInputYieldsNoDeviceState() {
        XCTAssertEqual(MicControlKit.state(hasDevice: false, muted: nil), .noDevice)
        // A stale mute reading must not resurrect a device that is gone.
        XCTAssertEqual(MicControlKit.state(hasDevice: false, muted: true), .noDevice)
        XCTAssertEqual(MicControlKit.state(hasDevice: false, muted: false), .noDevice)
    }

    func testDeviceWithoutSettableMuteIsUnsupported() {
        XCTAssertEqual(MicControlKit.state(hasDevice: true, muted: nil), .unsupported)
    }

    func testMuteReadingMapsToMutedAndLive() {
        XCTAssertEqual(MicControlKit.state(hasDevice: true, muted: true), .muted)
        XCTAssertEqual(MicControlKit.state(hasDevice: true, muted: false), .live)
    }

    // MARK: - Toggling

    func testOnlyMutableStatesCanToggle() {
        XCTAssertTrue(MicControlKit.canToggle(.muted))
        XCTAssertTrue(MicControlKit.canToggle(.live))
        // Offering a toggle for these would be a button that silently does nothing.
        XCTAssertFalse(MicControlKit.canToggle(.unsupported))
        XCTAssertFalse(MicControlKit.canToggle(.noDevice))
    }

    // MARK: - Tray glyph

    func testMutedIsTheOnlyStateWithASlashedGlyph() {
        // The inverse of this is the dangerous failure: reading "muted" while live.
        XCTAssertEqual(MicControlKit.trayGlyphName(for: .muted), "mic.slash.fill")
        for state in MicControlKit.MicState.allCases where state != .muted {
            XCTAssertFalse(
                MicControlKit.trayGlyphName(for: state).contains("slash"),
                "\(state) must not use a slashed mic — it would read as muted"
            )
        }
    }

    func testLiveIsTheOnlyStateWithTheFilledMicGlyph() {
        XCTAssertEqual(MicControlKit.trayGlyphName(for: .live), "mic.fill")
        for state in MicControlKit.MicState.allCases where state != .live {
            XCTAssertNotEqual(
                MicControlKit.trayGlyphName(for: state),
                "mic.fill",
                "\(state) must not claim the live glyph"
            )
        }
    }

    func testEveryStateHasANonEmptyGlyph() {
        for state in MicControlKit.MicState.allCases {
            XCTAssertFalse(MicControlKit.trayGlyphName(for: state).isEmpty)
        }
    }

    // MARK: - Copy

    func testTooltipNamesTheDeviceWhenOneIsKnown() {
        XCTAssertTrue(
            MicControlKit.trayTooltip(for: .muted, deviceName: "Shure MV7").contains("Shure MV7")
        )
        XCTAssertTrue(
            MicControlKit.trayTooltip(for: .live, deviceName: "Shure MV7").contains("Shure MV7")
        )
    }

    func testCopyNeverLeaksAnEmptyDeviceName() {
        // CoreAudio can withhold a name; blank/nil must not produce "  is muted".
        for name in [nil, "", "   "] as [String?] {
            for state in MicControlKit.MicState.allCases {
                let subtitle = MicControlKit.subtitle(for: state, deviceName: name)
                let tooltip = MicControlKit.trayTooltip(for: state, deviceName: name)
                XCTAssertFalse(subtitle.contains("  "), "Double space in subtitle for \(state): \(subtitle)")
                XCTAssertFalse(tooltip.contains("  "), "Double space in tooltip for \(state): \(tooltip)")
                XCTAssertFalse(subtitle.isEmpty)
                XCTAssertFalse(tooltip.isEmpty)
            }
        }
    }

    func testUnusableStatesExplainThemselves() {
        // A disabled control with no explanation reads as a bug, so both dead
        // states must say why they are dead.
        XCTAssertTrue(
            MicControlKit.subtitle(for: .unsupported, deviceName: "Aggregate Device")
                .contains("no mute control")
        )
        XCTAssertTrue(
            MicControlKit.subtitle(for: .noDevice, deviceName: nil).contains("Sound settings")
        )
    }

    func testTitlesAndActionsAreDistinctPerState() {
        let titles = MicControlKit.MicState.allCases.map { MicControlKit.title(for: $0) }
        XCTAssertEqual(Set(titles).count, titles.count, "Each state needs its own headline")

        XCTAssertEqual(MicControlKit.actionTitle(for: .muted), "Unmute")
        XCTAssertEqual(MicControlKit.actionTitle(for: .live), "Mute")
        XCTAssertEqual(MicControlKit.actionTitle(for: .unsupported), "Unavailable")
        XCTAssertEqual(MicControlKit.actionTitle(for: .noDevice), "Unavailable")
    }

    func testCopyUsesCurlyApostrophes() {
        // House typography: no straight quotes anywhere in user-facing strings.
        for state in MicControlKit.MicState.allCases {
            XCTAssertFalse(MicControlKit.title(for: state).contains("'"))
            XCTAssertFalse(MicControlKit.subtitle(for: state, deviceName: "Mic").contains("'"))
        }
    }

    // MARK: - Gain

    func testClampGainBoundsTheSliderValue() {
        XCTAssertEqual(MicControlKit.clampGain(-0.5), 0)
        XCTAssertEqual(MicControlKit.clampGain(0), 0)
        XCTAssertEqual(MicControlKit.clampGain(0.42), 0.42)
        XCTAssertEqual(MicControlKit.clampGain(1), 1)
        XCTAssertEqual(MicControlKit.clampGain(2), 1)
    }

    func testClampGainRejectsNonFiniteValues() {
        // A NaN reaching CoreAudio would be a hardware write of garbage.
        XCTAssertEqual(MicControlKit.clampGain(.nan), 0)
        XCTAssertEqual(MicControlKit.clampGain(.infinity), 0)
        XCTAssertEqual(MicControlKit.clampGain(-.infinity), 0)
    }

    func testGainPercentLabelRoundsRatherThanTruncates() {
        XCTAssertEqual(MicControlKit.gainPercentLabel(0), "0%")
        XCTAssertEqual(MicControlKit.gainPercentLabel(1), "100%")
        // 0.999 truncates to 99% but should read as a full slider.
        XCTAssertEqual(MicControlKit.gainPercentLabel(0.999), "100%")
        XCTAssertEqual(MicControlKit.gainPercentLabel(0.724), "72%")
        // Exact halves round away from zero, matching the slider's own readout.
        XCTAssertEqual(MicControlKit.gainPercentLabel(0.725), "73%")
        // Out-of-range input is clamped before it is formatted.
        XCTAssertEqual(MicControlKit.gainPercentLabel(3), "100%")
        XCTAssertEqual(MicControlKit.gainPercentLabel(-1), "0%")
    }

    // MARK: - Registration

    func testMicControlIsRegisteredInTheCatalog() {
        let tool = ToolboxCatalog.all.first { $0.id == "micControl" }
        let micControl = try? XCTUnwrap(tool)
        XCTAssertEqual(micControl?.executableName, "DMonteMicControl")
        XCTAssertEqual(micControl?.bundleID, "com.havokentity.mactools.miccontrol")
        XCTAssertEqual(micControl?.appName, "DMonte Mic Control.app")
        // The helper's own observer registers exactly this name; if the two ever
        // drift, "Open" from the Toolbox silently does nothing.
        XCTAssertEqual(
            micControl?.showNotification.rawValue,
            "com.havokentity.mactools.miccontrol.showWindow"
        )
    }

    // MARK: - Input-scope device access

    func testInputScopeMuteAndVolumeReadsAreEnvironmentTolerant() {
        // Read-only smoke test: never mutates the user's audio state. On headless
        // CI there may be no default input at all, which must not crash.
        guard let inputID = AudioDeviceKit.defaultInputDeviceID() else { return }

        // These may legitimately be nil/false; the contract is only that asking
        // in the input scope returns rather than trapping.
        _ = AudioDeviceKit.isMuted(inputID, scope: kAudioObjectPropertyScopeInput)
        _ = AudioDeviceKit.isMuteSettable(inputID, scope: kAudioObjectPropertyScopeInput)

        if let gain = AudioDeviceKit.volume(for: inputID, scope: kAudioObjectPropertyScopeInput) {
            XCTAssertGreaterThanOrEqual(gain, 0)
            XCTAssertLessThanOrEqual(gain, 1)
        }
    }

    func testDefaultInputIsAnInputDeviceWhenPresent() {
        guard let inputID = AudioDeviceKit.defaultInputDeviceID(),
              let device = AudioDeviceKit.allDevices().first(where: { $0.id == inputID }) else {
            return
        }
        XCTAssertTrue(device.hasInput, "The default input device should expose input streams")
    }
}
