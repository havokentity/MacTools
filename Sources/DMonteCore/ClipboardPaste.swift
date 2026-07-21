import AppKit
import ApplicationServices
import CoreGraphics

/// Writes a history entry back to the system pasteboard and pastes it into the previously
/// active app by synthesizing ⌘V. Pasting requires Accessibility permission; without it the
/// content is still placed on the clipboard so the user can paste manually, and we prompt once.
@MainActor
public enum ClipboardPaste {
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let vKeyCode: CGKeyCode = 0x09

    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func promptForAccessibilityPermission() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt; referencing the global is flagged as
        // not concurrency-safe under Swift 6.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Places the entry on the pasteboard. When `asPlainText` is true only the plain string is
    /// written, dropping fonts/colors/links. Returns false — leaving the pasteboard untouched —
    /// when the entry has nothing left to write, i.e. an image whose file is gone or unreadable.
    @discardableResult
    public static func copyToPasteboard(_ entry: ClipboardEntry, store: ClipboardStore, asPlainText: Bool) -> Bool {
        let pasteboard = NSPasteboard.general

        switch entry.kind {
        case .image:
            let item = NSPasteboardItem()
            if let name = entry.imageFileName,
               let data = try? Data(contentsOf: store.imagesURL(for: name)) {
                if name.hasSuffix(".png") {
                    item.setData(data, forType: .png)
                }
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
            }
            // Test the representations that actually made it onto the item, not just the read: an
            // undecodable file leaves it marker-only, and clearing for that would throw away
            // whatever the user had on the clipboard and put nothing in its place.
            guard !item.types.isEmpty else { return false }
            item.setString(ClipboardMonitor.bundleIdentifier, forType: sourceType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

        case .file:
            pasteboard.clearContents()
            if let paths = entry.filePaths, !paths.isEmpty {
                let items = paths.map { path in
                    let item = NSPasteboardItem()
                    item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                    item.setString(ClipboardMonitor.bundleIdentifier, forType: sourceType)
                    return item
                }
                pasteboard.writeObjects(items)
            } else {
                let item = NSPasteboardItem()
                item.setString(ClipboardMonitor.bundleIdentifier, forType: sourceType)
                item.setString(entry.text ?? "", forType: .string)
                pasteboard.writeObjects([item])
            }

        default:
            let item = NSPasteboardItem()
            item.setString(entry.text ?? "", forType: .string)
            if !asPlainText {
                if let rtf = entry.rtfData {
                    item.setData(rtf, forType: .rtf)
                }
                if let html = entry.htmlData {
                    item.setData(html, forType: .html)
                }
            }
            item.setString(ClipboardMonitor.bundleIdentifier, forType: sourceType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        }

        return true
    }

    /// Places text recognized out of an image entry on the pasteboard, as plain text only.
    ///
    /// Deliberately *not* stamped with the nspasteboard source marker the other writers here
    /// use: that marker exists to keep paste-backs of an existing entry out of history, whereas
    /// this text is new content the user just produced and will want to find later. Letting the
    /// monitor record it cannot loop — the recorded entry is text, "Copy Text from Image" only
    /// exists on image entries, and a run only ever starts from an explicit user gesture — so
    /// the chain is one step deep and self-terminating.
    ///
    /// `pasteboard` is injectable so the marker-free contract above — the thing that decides
    /// whether the monitor records the result — can be asserted against a private pasteboard
    /// instead of the user's real clipboard.
    public static func copyRecognizedText(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies the entry then pastes it into `target` (the app that was frontmost before our
    /// panel appeared). The result answers "is Accessibility the problem?", not "did the paste
    /// happen": false only when the permission is missing (content is still copied and the
    /// prompt is shown), so the caller can raise the permission banner for that case alone.
    @discardableResult
    public static func paste(
        _ entry: ClipboardEntry,
        store: ClipboardStore,
        asPlainText: Bool,
        into target: NSRunningApplication?
    ) -> Bool {
        // Nothing to copy leaves the user's own clipboard in place, so synthesizing ⌘V would
        // paste that instead of the entry. Accessibility isn't the problem here, so don't claim
        // it is — the caller would show the permission banner.
        guard copyToPasteboard(entry, store: store, asPlainText: asPlainText) else { return true }

        return pasteCopiedContent(into: target)
    }

    /// Puts plain `text` on the pasteboard and pastes it into `target`, stamped as coming from
    /// `sourceBundleID` (the nspasteboard.org convention every clipboard manager reads). Shared
    /// by the tools that paste text they generated rather than text they captured — Snippets —
    /// so the permission handling and the ⌘V synthesis have exactly one implementation.
    ///
    /// Same contract as `paste(_:store:asPlainText:into:)`: false means only that Accessibility
    /// is missing; the text is on the clipboard either way, ready for a manual ⌘V.
    @discardableResult
    public static func pasteText(
        _ text: String,
        sourceBundleID: String,
        into target: NSRunningApplication?
    ) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(sourceBundleID, forType: sourceType)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        return pasteCopiedContent(into: target)
    }

    /// Activates `target` and synthesizes ⌘V into it. Assumes the pasteboard already holds what
    /// should land there.
    private static func pasteCopiedContent(into target: NSRunningApplication?) -> Bool {
        guard hasAccessibilityPermission else {
            promptForAccessibilityPermission()
            return false
        }

        target?.activate()

        // Let focus settle on the target app before injecting the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            synthesizeCommandV()
        }
        return true
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
