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
    /// written, dropping fonts/colors/links.
    public static func copyToPasteboard(_ entry: ClipboardEntry, store: ClipboardStore, asPlainText: Bool) {
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
            item.setString(ClipboardMonitor.bundleIdentifier, forType: sourceType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

        case .file:
            let urls = (entry.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.clearContents()
            if urls.isEmpty {
                pasteboard.setString(entry.text ?? "", forType: .string)
            } else {
                pasteboard.writeObjects(urls)
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
    }

    /// Copies the entry then pastes it into `target` (the app that was frontmost before our
    /// panel appeared). Returns false if Accessibility isn't granted yet (content is still
    /// copied and the permission prompt is shown).
    @discardableResult
    public static func paste(
        _ entry: ClipboardEntry,
        store: ClipboardStore,
        asPlainText: Bool,
        into target: NSRunningApplication?
    ) -> Bool {
        copyToPasteboard(entry, store: store, asPlainText: asPlainText)

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
