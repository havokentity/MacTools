import AppKit
import XCTest
@testable import DMonteCore

/// Guards the click path through the transparent drop overlay that covers the File Shelf's
/// menu-bar button.
///
/// The overlay exists only so the button can accept a file drag, and it must be invisible to
/// everything else. That has two halves — the view has to agree to receive a click in the first
/// place, and it has to hand the click straight back to the button — and losing either one leaves
/// the tool with an icon that cannot be opened at all, which no shelf-logic test would catch.
@MainActor
final class StatusItemFileDropViewTests: XCTestCase {
    /// Stands in for the `NSStatusBarButton` underneath, since AppKit will not let us make a real
    /// one outside a status item.
    private final class RecordingButton: NSView {
        var mouseDownCount = 0
        var rightMouseDownCount = 0
        var mouseUpCount = 0
        var rightMouseUpCount = 0

        override func mouseDown(with event: NSEvent) { mouseDownCount += 1 }
        override func rightMouseDown(with event: NSEvent) { rightMouseDownCount += 1 }
        override func mouseUp(with event: NSEvent) { mouseUpCount += 1 }
        override func rightMouseUp(with event: NSEvent) { rightMouseUpCount += 1 }
    }

    private func makeEvent(type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    /// The regression this file exists for.
    ///
    /// The shelf runs as an `LSUIElement` helper that never becomes the active app, so *every*
    /// click on its menu-bar icon is a first mouse click. The overlay wins hit-testing over the
    /// button it covers, and plain `NSView` answers `false` here where `NSStatusBarButton` answers
    /// `true` — so with the default in place AppKit spends the mouse-down activating the app
    /// instead of delivering it, `mouseDown(with:)` is never called, and the popover never opens.
    func testTheOverlayAcceptsTheFirstClickTheWayTheButtonUnderneathWould() throws {
        let dropView = StatusItemFileDropView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))

        XCTAssertTrue(
            dropView.acceptsFirstMouse(for: try makeEvent(type: .leftMouseDown)),
            "A menu-bar helper is never the active app, so refusing the first mouse means refusing every click"
        )
        XCTAssertTrue(
            dropView.acceptsFirstMouse(for: nil),
            "AppKit is allowed to ask with no event at all, and the answer must not change"
        )
    }

    /// Accepting the click is only useful if it then reaches the button, which is what actually
    /// toggles the popover.
    func testEveryMouseEventIsHandedBackToTheButtonUnderneath() throws {
        let button = RecordingButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        let dropView = StatusItemFileDropView(frame: button.bounds)
        button.addSubview(dropView)

        dropView.mouseDown(with: try makeEvent(type: .leftMouseDown))
        dropView.mouseUp(with: try makeEvent(type: .leftMouseUp))
        dropView.rightMouseDown(with: try makeEvent(type: .rightMouseDown))
        dropView.rightMouseUp(with: try makeEvent(type: .rightMouseUp))

        XCTAssertEqual(button.mouseDownCount, 1)
        XCTAssertEqual(button.mouseUpCount, 1)
        XCTAssertEqual(button.rightMouseDownCount, 1, "Right-click drives the menu, so it has to pass through too")
        XCTAssertEqual(button.rightMouseUpCount, 1)
    }

    /// The overlay is only worth its risk because it is a drag destination; if it stopped
    /// advertising file URLs the drop would never arrive and the pass-through would be pure cost.
    func testTheOverlayIsRegisteredForFileDrags() {
        let dropView = StatusItemFileDropView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))

        XCTAssertTrue(dropView.registeredDraggedTypes.contains(.fileURL))
    }
}
