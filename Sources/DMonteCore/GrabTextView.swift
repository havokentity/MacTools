import AppKit
import SwiftUI

/// The Grab Text window: a single "Grab Text" button that runs an interactive
/// screen capture and Vision OCR, a "Copy automatically" toggle, and a scrollable,
/// selectable result area with a Copy button and a character/line count. Content is
/// scaled to match the menu-bar/display scale so it fits the scaled panel (same
/// approach as the other tools).
///
/// The state lives in `GrabTextController` rather than here because the global capture hotkey
/// starts the same flow while this window is closed — see the controller for why sharing the
/// in-flight guard matters.
public struct GrabTextWindowView: View {
    @ObservedObject var controller: GrabTextController
    var onQuit: () -> Void

    @State private var isShowingSettings = false

    private let layout = GrabTextLayout.current

    public init(controller: GrabTextController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                VStack(spacing: layout.contentSpacing) {
                    grabButton
                    hotKeyHint
                    copyToggle
                    resultArea
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.contentHorizontalPadding)
                .padding(.bottom, layout.contentBottomPadding)
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    GrabTextSettingsView(
                        controller: controller,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: 18)
        .onAppear { controller.refreshEnvironment() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Quit DMonte Grab Text")

            Spacer()

            Text("DMonte Grab Text")
                .font(.system(size: layout.titleFontSize, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.82))

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: layout.closeIconSize, weight: .semibold))
                    .foregroundStyle(hotKeyNeedsAttention ? Color.orange : Color.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    // MARK: - Grab button

    private var grabButton: some View {
        Button {
            controller.startGrab()
        } label: {
            Label(controller.isGrabbing ? "Selecting region…" : "Grab Text", systemImage: "text.viewfinder")
                .font(.system(size: layout.primaryButtonFontSize, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: layout.primaryButtonHeight)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(controller.isGrabbing)
        .opacity(controller.isGrabbing ? 0.5 : 1)
        .padding(.top, layout.previewTopPadding)
    }

    /// One line under the button telling the user the shortcut exists — a global hotkey nobody
    /// knows about is the same as no hotkey. Turns into the problem when there is one.
    private var hotKeyHint: some View {
        HStack(spacing: layout.buttonRowSpacing / 2) {
            Image(systemName: hotKeyNeedsAttention ? "exclamationmark.triangle.fill" : "command")
                .font(.system(size: layout.captionFontSize, weight: .semibold))
            Text(hotKeyHintText)
                .font(.system(size: layout.captionFontSize, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(hotKeyNeedsAttention ? Color.orange : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hotKeyNeedsAttention: Bool {
        controller.registrationFailure != nil || controller.secureInputBlocked
    }

    private var hotKeyHintText: String {
        if controller.registrationFailure != nil {
            return "The capture shortcut is already claimed by another app — pick a different one in Settings."
        }
        if controller.secureInputBlocked {
            return "macOS Secure Input is blocking global shortcuts right now."
        }
        guard let shortcut = controller.shortcut else {
            return "No capture shortcut set — assign one in Settings."
        }
        return "Press \(shortcut.displayString) anywhere to grab text without opening this window."
    }

    private var copyToggle: some View {
        Toggle(isOn: $controller.copyAutomatically) {
            Text("Copy automatically")
                .font(.system(size: layout.fieldFontSize, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Result area

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: layout.buttonRowSpacing) {
            resultBox

            HStack(spacing: layout.buttonRowSpacing) {
                Text(countSummary)
                    .font(.system(size: layout.captionFontSize, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()

                Spacer()

                actionButton(title: "Copy", systemImage: "doc.on.doc", isEnabled: !controller.recognizedText.isEmpty) {
                    controller.copyRecognizedText()
                }
            }
        }
    }

    @ViewBuilder
    private var resultBox: some View {
        ScrollView {
            if controller.recognizedText.isEmpty {
                Text(controller.statusMessage)
                    .font(.system(size: layout.fieldFontSize, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(layout.cardPadding)
            } else {
                Text(controller.recognizedText)
                    .font(.system(size: layout.fieldFontSize, weight: .regular, design: .default))
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(layout.cardPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.resultHeight)
        .background(
            RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay {
            RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        }
    }

    private var countSummary: String {
        let text = controller.recognizedText
        let chars = text.count
        let lines = text.isEmpty
            ? 0
            : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(chars) chars · \(lines) lines"
    }

    // MARK: - Shared button

    private func actionButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: layout.secondaryButtonFontSize, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(height: layout.secondaryButtonHeight)
                .padding(.horizontal, layout.secondaryButtonPadding)
                .background(
                    RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The settings sheet: recording the global capture shortcut, the reasons it might not be working,
/// and the Screen Recording grant the capture itself depends on.
private struct GrabTextSettingsView: View {
    @ObservedObject var controller: GrabTextController
    @StateObject private var recorder = ShortcutRecorder()
    @State private var notice: String?
    var onClose: () -> Void

    /// The recorder is keyed by a slot token; Grab Text has exactly one.
    private enum Slot: Hashable { case captureShortcut }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Grab Text Settings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    recorder.cancel()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            shortcutRow

            if let message = problemMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Click the shortcut, then press the new keys. Esc cancels.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            permissionSection

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: GrabTextSizing.settingsSize().width, height: GrabTextSizing.settingsSize().height)
        .onAppear { controller.refreshEnvironment() }
        .onDisappear { recorder.cancel() }
    }

    private var shortcutRow: some View {
        HStack(spacing: 10) {
            Text("Capture shortcut")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button {
                beginRecording()
            } label: {
                Text(shortcutLabel)
                    .font(.system(size: 13, weight: .medium, design: recorder.isRecording(Slot.captureShortcut) ? .default : .rounded))
                    .foregroundStyle(shortcutTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(recorder.isRecording(Slot.captureShortcut) ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .help("Click to record a new capture shortcut")

            Button("Clear") {
                recorder.cancel()
                notice = nil
                controller.disableShortcut()
            }
            .font(.system(size: 11))
            .disabled(controller.shortcut == nil)

            Button("Default") {
                recorder.cancel()
                notice = nil
                controller.resetShortcut()
            }
            .font(.system(size: 11))
        }
    }

    private var shortcutLabel: String {
        if recorder.isRecording(Slot.captureShortcut) { return "Press keys…" }
        return controller.shortcut?.displayString ?? "Off"
    }

    private var shortcutTint: Color {
        if recorder.isRecording(Slot.captureShortcut) { return .accentColor }
        if controller.registrationFailure != nil { return .orange }
        return .primary.opacity(0.85)
    }

    /// The first thing standing between the user and a working shortcut, if anything is.
    private var problemMessage: String? {
        if let notice { return notice }
        if controller.secureInputBlocked {
            return "macOS Secure Input is blocking all global shortcuts right now (a password field, the lock screen, or a stuck loginwindow). They resume automatically when it ends."
        }
        if let status = controller.registrationFailure {
            return "macOS refused this shortcut (error \(status)) — another app already owns it exclusively. Pick a different combination."
        }
        return nil
    }

    @ViewBuilder
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                controller.hasScreenRecordingAccess ? "Screen Recording access granted" : "Screen Recording access needed",
                systemImage: controller.hasScreenRecordingAccess ? "checkmark.shield" : "lock.shield"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(controller.hasScreenRecordingAccess ? Color.secondary : Color.orange)

            Text("Grabbing text means photographing part of your screen, which macOS gates behind Screen Recording. Without it a capture comes back blank rather than failing outright, so Grab Text says so instead of reporting \u{201C}no text found\u{201D}.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !controller.hasScreenRecordingAccess {
                Button("Open Screen Recording Settings") {
                    controller.requestScreenRecordingAccess()
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    private func beginRecording() {
        notice = nil
        if recorder.isRecording(Slot.captureShortcut) {
            recorder.cancel()
            return
        }
        recorder.begin(
            for: Slot.captureShortcut,
            suspendHotKeys: { controller.suspendHotKeyForRecording() },
            resumeHotKeys: { controller.resumeHotKeyAfterRecording() }
        ) { shortcut in
            guard let shortcut else { return } // Esc — cancelled
            switch controller.assignShortcut(shortcut) {
            case .assigned:
                notice = nil
            case .needsModifiers:
                notice = "Add at least one of ⌘ ⌃ ⌥ (function keys may stand alone)."
            }
        }
    }
}

private struct GrabTextLayout {
    let scale: CGFloat

    static var current: GrabTextLayout {
        GrabTextLayout(scale: GrabTextSizing.currentScale)
    }

    var windowSize: NSSize { GrabTextSizing.preferredSize() }

    var contentSpacing: CGFloat { 10 * scale }
    var contentHorizontalPadding: CGFloat { 24 * scale }
    var contentBottomPadding: CGFloat { 18 * scale }

    var headerButtonSize: CGFloat { 30 * scale }
    var closeIconSize: CGFloat { 16 * scale }
    var titleFontSize: CGFloat { 18 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 8 * scale }

    var previewTopPadding: CGFloat { 6 * scale }

    var resultHeight: CGFloat { 180 * scale }
    var fieldCornerRadius: CGFloat { 8 * scale }
    var fieldFontSize: CGFloat { 13 * scale }
    var captionFontSize: CGFloat { 11 * scale }
    var cardPadding: CGFloat { 12 * scale }

    var buttonRowSpacing: CGFloat { 10 * scale }
    var buttonCornerRadius: CGFloat { 7 * scale }

    var primaryButtonHeight: CGFloat { 36 * scale }
    var primaryButtonFontSize: CGFloat { 14 * scale }

    var secondaryButtonHeight: CGFloat { 32 * scale }
    var secondaryButtonFontSize: CGFloat { 13 * scale }
    var secondaryButtonPadding: CGFloat { 16 * scale }
}
