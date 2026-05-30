import AppKit
import SwiftUI

/// The Grab Text window: a single "Grab Text" button that runs an interactive
/// screen capture and Vision OCR, a "Copy automatically" toggle, and a scrollable,
/// selectable result area with a Copy button and a character/line count. Content is
/// scaled to match the menu-bar/display scale so it fits the scaled panel (same
/// approach as the other tools).
public struct GrabTextWindowView: View {
    var onQuit: () -> Void

    @State private var isGrabbing = false
    @State private var recognizedText = ""
    @State private var statusMessage = "Drag to select a region of the screen to grab its text."
    @State private var copyAutomatically: Bool = GrabTextWindowView.initialCopyAutomatically()

    private let layout = GrabTextLayout.current

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: layout.contentSpacing) {
                grabButton
                copyToggle
                resultArea
                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout.contentHorizontalPadding)
            .padding(.bottom, layout.contentBottomPadding)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: 18)
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

            Color.clear
                .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    // MARK: - Grab button

    private var grabButton: some View {
        Button {
            startGrab()
        } label: {
            Label(isGrabbing ? "Selecting region…" : "Grab Text", systemImage: "text.viewfinder")
                .font(.system(size: layout.primaryButtonFontSize, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: layout.primaryButtonHeight)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isGrabbing)
        .opacity(isGrabbing ? 0.5 : 1)
        .padding(.top, layout.previewTopPadding)
    }

    private var copyToggle: some View {
        Toggle(isOn: $copyAutomatically) {
            Text("Copy automatically")
                .font(.system(size: layout.fieldFontSize, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: copyAutomatically) { _, newValue in
            AppDefaults.shared.set(newValue, forKey: DefaultsKey.grabTextCopyAutomatically)
        }
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

                actionButton(title: "Copy", systemImage: "doc.on.doc", isEnabled: !recognizedText.isEmpty) {
                    copyToPasteboard(recognizedText)
                    statusMessage = "Copied to clipboard."
                }
            }
        }
    }

    @ViewBuilder
    private var resultBox: some View {
        ScrollView {
            if recognizedText.isEmpty {
                Text(statusMessage)
                    .font(.system(size: layout.fieldFontSize, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(layout.cardPadding)
            } else {
                Text(recognizedText)
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
        let chars = recognizedText.count
        let lines = recognizedText.isEmpty
            ? 0
            : recognizedText.split(separator: "\n", omittingEmptySubsequences: false).count
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

    // MARK: - Actions

    private func startGrab() {
        guard !isGrabbing else {
            return
        }

        isGrabbing = true
        recognizedText = ""
        statusMessage = "Drag to select the region containing text…"

        Task {
            let result = await GrabTextRunner.grabRegion()
            // Back on the main actor here — safe to touch @State.
            isGrabbing = false

            switch result {
            case .cancelled:
                statusMessage = "Grab cancelled. Click Grab Text to try again."
            case let .failure(reason):
                statusMessage = reason
            case let .success(text):
                if text.isEmpty {
                    statusMessage = "No text found in that region. Try again."
                } else {
                    recognizedText = text
                    if copyAutomatically {
                        copyToPasteboard(text)
                        statusMessage = "Copied to clipboard."
                    } else {
                        statusMessage = ""
                    }
                }
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // Reads the toggle's stored value, defaulting to `true` even if unregistered.
    private static func initialCopyAutomatically() -> Bool {
        if AppDefaults.shared.object(forKey: DefaultsKey.grabTextCopyAutomatically) == nil {
            return true
        }
        return AppDefaults.shared.bool(forKey: DefaultsKey.grabTextCopyAutomatically)
    }
}

/// Runs the interactive screen capture and Vision OCR off the main actor. The heavy
/// work (spawning `screencapture` and running Vision) happens in a detached task; the
/// result is returned to the awaiting caller, which is back on its original actor.
private enum GrabTextRunner {
    enum Outcome: Sendable {
        case success(String)
        case cancelled
        case failure(String)
    }

    static func grabRegion() async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dmonte-grabtext-\(UUID().uuidString).png")

            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: interactive region selection, -x: silence the capture sound.
            process.arguments = ["-i", "-x", tempURL.path]

            do {
                try process.run()
            } catch {
                return .failure("Couldn't start screen capture: \(error.localizedDescription)")
            }

            process.waitUntilExit()

            // screencapture writes no file when the user presses Escape to cancel.
            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                return .cancelled
            }

            let lines = GrabTextKit.recognizeText(in: tempURL)
            let joined = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(joined)
        }.value
    }
}

private struct GrabTextLayout {
    let scale: CGFloat

    static var current: GrabTextLayout {
        GrabTextLayout(scale: GrabTextSizing.currentScale)
    }

    var windowSize: NSSize { GrabTextSizing.preferredSize() }

    var contentSpacing: CGFloat { 12 * scale }
    var contentHorizontalPadding: CGFloat { 24 * scale }
    var contentBottomPadding: CGFloat { 18 * scale }

    var headerButtonSize: CGFloat { 30 * scale }
    var closeIconSize: CGFloat { 16 * scale }
    var titleFontSize: CGFloat { 18 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 8 * scale }

    var previewTopPadding: CGFloat { 6 * scale }

    var resultHeight: CGFloat { 200 * scale }
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
