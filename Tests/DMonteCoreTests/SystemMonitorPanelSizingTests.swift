import AppKit
import XCTest
@testable import DMonteCore

/// The System Monitor panel grew a sparkline row inside every card and a whole process card
/// underneath them. Its height is now derived from the same constants the popover lays itself out
/// with, and its settings sheet is capped against it — both relationships that only hold if
/// nobody edits one number without the other.
final class SystemMonitorPanelSizingTests: XCTestCase {

    /// The scale is read from live screen metrics, so asserting today's numbers would only pin
    /// today's machine. Everything below asserts the relationships across the whole range instead.
    private let scales: [CGFloat] = [0.78, 0.8, 0.85, 0.88, 0.92, 0.96, 1.0]

    func testSettingsSheetFitsInsideThePanelWithRoomForTheOverlayPadding() {
        for scale in scales {
            let panel = SystemMonitorPanelSizing.panelSize(scale: scale)
            let settings = SystemMonitorPanelSizing.settingsSize(scale: scale)

            // PreferencesOverlay adds 18pt of padding per side, so a sheet sized to the full panel
            // becomes panel+36 once padded and drags the content behind it off both edges.
            XCTAssertLessThanOrEqual(
                settings.width, panel.width - SystemMonitorPanelSizing.overlayChrome,
                "scale \(scale): the settings sheet is wide enough to be clipped on both sides"
            )
            XCTAssertLessThanOrEqual(
                settings.height, panel.height - SystemMonitorPanelSizing.overlayChrome,
                "scale \(scale): the settings sheet cannot show its bottom row"
            )
            XCTAssertGreaterThan(settings.width, 0)
            XCTAssertGreaterThan(settings.height, 0)
        }
    }

    func testShippedSizesHoldTheSameRelationship() {
        let panel = SystemMonitorPanelSizing.preferredSize()
        let settings = SystemMonitorPanelSizing.settingsSize()

        XCTAssertLessThanOrEqual(settings.width, panel.width - SystemMonitorPanelSizing.overlayChrome)
        XCTAssertLessThanOrEqual(settings.height, panel.height - SystemMonitorPanelSizing.overlayChrome)
    }

    /// The panel has to be at least as tall as the content it now holds, or the process card at
    /// the foot is silently clipped.
    func testPanelIsTallEnoughForTheGridAndTheProcessCard() {
        for scale in scales {
            let panel = SystemMonitorPanelSizing.panelSize(scale: scale)

            XCTAssertGreaterThanOrEqual(
                panel.height,
                (SystemMonitorPanelSizing.baseContentHeight * scale).rounded() - 1,
                "scale \(scale): the panel is shorter than the content laid out inside it"
            )
        }
    }

    func testPanelGrowsWithScaleAndStaysWithinItsWidthBounds() {
        var previousHeight: CGFloat = 0

        for scale in scales {
            let panel = SystemMonitorPanelSizing.panelSize(scale: scale)

            XCTAssertGreaterThanOrEqual(panel.height, previousHeight)
            previousHeight = panel.height

            XCTAssertGreaterThanOrEqual(panel.width, SystemMonitorPanelSizing.minimumWidth)
            XCTAssertLessThanOrEqual(panel.width, SystemMonitorPanelSizing.maximumWidth)
        }
    }

    /// The bug this catches, caught once already while writing it: the process card was given a
    /// height four points shorter than the rows it holds, which drops the last process off the
    /// bottom without any other symptom.
    func testLaidOutContentFitsThePanelAtEveryScale() {
        for scale in scales {
            let layout = SystemMonitorPanelLayout(scale: scale)
            let panel = SystemMonitorPanelSizing.panelSize(scale: scale)

            let header = layout.headerVerticalPadding * 2 + layout.settingsButtonSize
            let grid = layout.cardHeight * 2 + layout.gridSpacing + layout.gridBottomPadding
            let content = header + grid + layout.processCardHeight

            XCTAssertLessThanOrEqual(
                content, panel.height,
                "scale \(scale): the popover lays out \(content)pt of content in a \(panel.height)pt panel"
            )
        }
    }

    func testProcessCardIsTallEnoughForEveryRowItShows() {
        for scale in scales {
            let layout = SystemMonitorPanelLayout(scale: scale)
            let rows = CGFloat(TopProcessKit.listLimit)

            // Padding, the header row and its trailing gap, five rows, and the five gaps the VStack
            // puts between the six children.
            let content = layout.processCardPadding * 2
                + layout.processSegmentHeight + layout.processHeaderSpacing
                + layout.processRowHeight * rows
                + layout.processRowSpacing * rows

            XCTAssertLessThanOrEqual(
                content, layout.processCardHeight,
                "scale \(scale): \(content)pt of process rows in a \(layout.processCardHeight)pt card"
            )
        }
    }

    /// The sparklines were slotted into cards that already had a gauge, a title and a detail line
    /// in them; the card had spare room, but not unlimited spare room.
    func testMetricCardIsTallEnoughForItsGaugeAndSparkline() {
        for scale in scales {
            let layout = SystemMonitorPanelLayout(scale: scale)

            let content = layout.cardPadding * 2
                + layout.gaugeHeight
                + layout.sparklineTopGap + layout.sparklineHeight
                + layout.visualGap
                + layout.metricFontSize
                + layout.textLineGap + layout.detailFontSize

            XCTAssertLessThanOrEqual(
                content, layout.cardHeight,
                "scale \(scale): \(content)pt of card content in a \(layout.cardHeight)pt card"
            )
        }
    }

    func testScaleIsClampedToItsDocumentedRange() {
        for visibleHeight in [CGFloat(200), 640, 800, 950, 1_400, 4_000] {
            let scale = SystemMonitorPanelSizing.scale(forVisibleHeight: visibleHeight)

            XCTAssertGreaterThanOrEqual(scale, 0.78)
            XCTAssertLessThanOrEqual(scale, 1.0)
        }
    }

    /// `NSScreen.main` is nil on a headless machine and its frame can be reported as zero mid
    /// display change; either would make the scale a NaN and the panel unsizeable.
    func testDegenerateScreenHeightsFallBackToAFiniteScale() {
        for visibleHeight in [CGFloat(0), -100, .nan, .infinity] {
            let scale = SystemMonitorPanelSizing.scale(forVisibleHeight: visibleHeight)

            XCTAssertTrue(scale.isFinite, "a visible height of \(visibleHeight) produced \(scale)")
            XCTAssertGreaterThan(scale, 0)
        }
    }
}
