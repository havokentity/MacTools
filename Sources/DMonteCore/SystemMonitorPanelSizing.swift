import AppKit

public enum SystemMonitorPanelSizing {
    /// The panel's height at scale 1, built from the same constants the popover lays its content
    /// out with so the two cannot drift apart:
    ///
    /// - 44 header (a 26pt settings button between 9pt paddings)
    /// - 304 metric grid (two 148pt card rows with 8pt between them)
    /// - 8 below the grid
    /// - 130 process card
    /// - 10 at the foot
    ///
    /// Adding the sparklines and the process list is what made this worth deriving rather than
    /// hard-coding: a panel an inch short of its content silently clips the bottom row.
    static let baseContentHeight: CGFloat = 44 + 304 + 8 + 130 + 10

    /// Width at scale 1, clamped below so the two-column grid never squeezes the cards to
    /// unreadable, and above so the panel does not sprawl on a tall display.
    static let baseWidth: CGFloat = 370
    static let minimumWidth: CGFloat = 338
    static let maximumWidth: CGFloat = 376

    /// The settings sheet's size at scale 1, before it is capped against the panel.
    static let baseSettingsWidth: CGFloat = 338
    static let baseSettingsHeight: CGFloat = 350

    /// The padding `PreferencesOverlay` adds around the sheet, 18pt per side. A sheet sized to the
    /// full panel becomes panel+36 once padded and drags the content behind it off both edges.
    static let overlayChrome: CGFloat = 36

    public static func preferredSize() -> NSSize {
        panelSize(scale: currentScale)
    }

    /// The settings sheet, capped at the panel it is centred over. Hard-coded at 338x350 the sheet
    /// was 4pt wider than the panel at scale 1, which clipped the first and last character of its
    /// title; the cap makes the relationship hold at every scale instead of at one.
    public static func settingsSize() -> NSSize {
        settingsSize(scale: currentScale)
    }

    static func panelSize(scale: CGFloat) -> NSSize {
        let width = min(maximumWidth, max(minimumWidth, baseWidth * scale))

        return NSSize(width: width.rounded(), height: (baseContentHeight * scale).rounded())
    }

    static func settingsSize(scale: CGFloat) -> NSSize {
        let panel = panelSize(scale: scale)

        return NSSize(
            width: min(baseSettingsWidth * scale, panel.width - overlayChrome),
            height: min(baseSettingsHeight * scale, panel.height - overlayChrome)
        )
    }

    /// Shared by the panel and by the popover's layout metrics, so a change to one moves both.
    static var currentScale: CGFloat {
        scale(forVisibleHeight: NSScreen.main?.visibleFrame.height ?? 900)
    }

    /// The panel is now tall enough that a short display has to shrink it, hence the wider floor
    /// than the 0.88 the two-card layout used.
    static func scale(forVisibleHeight visibleHeight: CGFloat) -> CGFloat {
        guard visibleHeight.isFinite, visibleHeight > 0 else {
            return 1.0
        }

        return min(1.0, max(0.78, visibleHeight / 950))
    }
}
