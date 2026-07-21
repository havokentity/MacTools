import AppKit

/// Knows when a status item has actually landed in the menu bar, so a panel anchored to it opens
/// in the right place.
///
/// Every helper that reveals its UI at launch (`--open` from the Toolbox tile) has to wait for
/// its status item before positioning against it, and each one that tried got it wrong in the
/// same way: a single `DispatchQueue.main.async`, on the assumption that one runloop turn is
/// enough. It is not, and the failure is worse than a race — the button reports a *plausible*
/// frame long before it is placed, so the panel is positioned against garbage rather than
/// falling back to something sensible.
///
/// Measured on a cold launch, the item takes three positions before settling:
///
///     t=0.00  (0, -13)      not placed — real size, still at the origin
///     t=0.00  (2536, 1410)  placed, top right
///     t=0.10  (0, -30)      back to the origin
///     t=0.20  (1393, 1484)  final
///
/// So neither "is it non-zero" nor "is it in the menu bar" is sufficient. The only reliable
/// signal is that the frame has stopped changing.
@MainActor
public enum StatusItemAnchor {

    /// Consecutive identical samples that count as "it has stopped moving".
    private static let requiredStableSamples = 3

    /// The anchor's frame in screen coordinates if it is currently sitting in a menu bar,
    /// otherwise `nil`.
    ///
    /// Position, not size, is the test: a status item lives *above* its screen's visible frame,
    /// in the menu bar strip. A button reports its true size while its window is still at the
    /// origin, and anchoring to that puts the panel in the corner of whichever display owns
    /// (0, 0) — on a multi-display Mac, usually not even the display with the menu bar.
    public static func placedFrame(of view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let frameInWindow = view.convert(view.bounds, to: nil)
        let frame = window.convertToScreen(frameInWindow)
        guard frame.width > 0, frame.height > 0 else { return nil }

        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
        guard let screen else { return nil }
        return frame.midY > screen.visibleFrame.maxY ? frame : nil
    }

    /// Whether the anchor is currently placed in a menu bar.
    public static func isPlaced(_ view: NSView?) -> Bool {
        placedFrame(of: view) != nil
    }

    /// Runs `body` once the status item's frame has repeated unchanged, or after `timeout`
    /// regardless.
    ///
    /// The anchor is re-read on every poll rather than captured, because the button may not exist
    /// yet when this is called. Polling on a timer rather than re-dispatching matters: `async`
    /// hops elapse in microseconds and would all be spent before the status bar has done
    /// anything, which is the same as not waiting at all.
    ///
    /// Showing late is a cosmetic problem; never showing is a broken tool, so the timeout always
    /// runs `body`.
    public static func whenSettled(
        _ anchor: @escaping @MainActor () -> NSView?,
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.05,
        perform body: @escaping @MainActor () -> Void
    ) {
        poll(anchor, remaining: timeout, pollInterval: pollInterval, lastFrame: nil, stableSamples: 0, body: body)
    }

    private static func poll(
        _ anchor: @escaping @MainActor () -> NSView?,
        remaining: TimeInterval,
        pollInterval: TimeInterval,
        lastFrame: NSRect?,
        stableSamples: Int,
        body: @escaping @MainActor () -> Void
    ) {
        let frame = placedFrame(of: anchor())

        if let frame, frame == lastFrame {
            let samples = stableSamples + 1
            if samples >= requiredStableSamples {
                body()
                return
            }
            schedule(anchor, remaining: remaining, pollInterval: pollInterval, lastFrame: frame, stableSamples: samples, body: body)
            return
        }

        guard remaining > 0 else {
            body()
            return
        }
        // Moved, or not placed yet: restart the stability count from this sample.
        schedule(anchor, remaining: remaining, pollInterval: pollInterval, lastFrame: frame, stableSamples: 0, body: body)
    }

    private static func schedule(
        _ anchor: @escaping @MainActor () -> NSView?,
        remaining: TimeInterval,
        pollInterval: TimeInterval,
        lastFrame: NSRect?,
        stableSamples: Int,
        body: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            MainActor.assumeIsolated {
                poll(anchor, remaining: remaining - pollInterval, pollInterval: pollInterval, lastFrame: lastFrame, stableSamples: stableSamples, body: body)
            }
        }
    }
}
