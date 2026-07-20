import AppKit
import SwiftUI

/// The floating Scratchpad popover: a switcher strip of named notes, a plain-text editor, a live
/// size readout, and copy/clear/delete actions. Content is scaled to match the menu-bar/display
/// scale so it fits the scaled panel (same approach as the other tools).
public struct ScratchpadPopoverView: View {
    @ObservedObject var controller: ScratchpadController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var isTitleFieldFocused: Bool

    private let scale = ScratchpadSizing.currentScale

    public init(controller: ScratchpadController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var accent: Color { .yellow }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                noteSwitcher
                editor
                countsRow
                Divider().opacity(0.6)
                actionRow
                footer
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    ScratchpadSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: ScratchpadSizing.preferredSize().width, height: ScratchpadSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "note.text")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(accent)

            Text("Scratchpad")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: s(14), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(14))
        .padding(.bottom, s(10))
    }

    // MARK: - Note switcher

    private var noteSwitcher: some View {
        VStack(spacing: s(8)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: s(6)) {
                    ForEach(controller.notes) { note in
                        noteChip(note)
                    }

                    Button {
                        endRenaming()
                        controller.addNote()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: s(12), weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: s(28), height: s(26))
                            .background(
                                RoundedRectangle(cornerRadius: s(7), style: .continuous)
                                    .fill(Color.secondary.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("New note")
                }
                .padding(.horizontal, s(16))
            }

            if isRenaming {
                renameField
            }
        }
        .padding(.top, s(10))
        .padding(.bottom, s(10))
    }

    private func noteChip(_ note: ScratchpadNote) -> some View {
        let isSelected = note.id == controller.selectedNoteID

        return Button {
            // A second tap on the note already open is the natural "rename this" gesture, and it
            // keeps a rename affordance out of the cramped chip itself.
            if isSelected {
                beginRenaming()
            } else {
                endRenaming()
                controller.selectNote(note.id)
            }
        } label: {
            Text(note.title)
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(isSelected ? Color.black.opacity(0.85) : .primary)
                .lineLimit(1)
                .padding(.horizontal, s(10))
                .frame(height: s(26))
                .background(
                    RoundedRectangle(cornerRadius: s(7), style: .continuous)
                        .fill(isSelected ? accent : Color.secondary.opacity(0.14))
                )
                .contentShape(RoundedRectangle(cornerRadius: s(7), style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Tap again to rename" : note.title)
    }

    private var renameField: some View {
        HStack(spacing: s(8)) {
            TextField("Note name", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: s(12), weight: .semibold))
                .focused($isTitleFieldFocused)
                .onSubmit { commitRename() }
                .padding(.horizontal, s(8))
                .frame(height: s(26))
                .background(
                    RoundedRectangle(cornerRadius: s(7), style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )

            Button("Rename") { commitRename() }
                .buttonStyle(.plain)
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, s(16))
    }

    private func beginRenaming() {
        draftTitle = controller.activeNote?.title ?? ""
        isRenaming = true
        isTitleFieldFocused = true
    }

    private func commitRename() {
        controller.renameSelectedNote(to: draftTitle)
        endRenaming()
    }

    private func endRenaming() {
        isRenaming = false
        isTitleFieldFocused = false
    }

    // MARK: - Editor

    private var editor: some View {
        ScratchpadTextView(
            noteID: controller.selectedNoteID,
            text: controller.activeText,
            fontSize: controller.fontSize,
            onTextChange: { controller.updateText($0) }
        )
        .padding(s(6))
        .background(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(Color.black.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        )
        .padding(.horizontal, s(16))
        .frame(maxHeight: .infinity)
    }

    // MARK: - Counts

    private var countsRow: some View {
        HStack(spacing: s(6)) {
            Text(countsSummary)
                .font(.system(size: s(11), weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: s(6))

            if let statusMessage = controller.statusMessage {
                Text(statusMessage)
                    .font(.system(size: s(11), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(8))
        .padding(.bottom, s(8))
    }

    private var countsSummary: String {
        let counts = controller.counts
        let words = counts.words == 1 ? "1 word" : "\(counts.words) words"
        let characters = counts.characters == 1 ? "1 character" : "\(counts.characters) characters"
        let lines = counts.lines == 1 ? "1 line" : "\(counts.lines) lines"
        return "\(words) · \(characters) · \(lines)"
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: s(8)) {
            actionButton(title: "Copy All", symbol: "doc.on.doc") {
                controller.copyAll()
            }

            if controller.canUndoClear {
                actionButton(title: "Undo Clear", symbol: "arrow.uturn.backward", tint: accent) {
                    controller.undoClear()
                }
            } else {
                actionButton(title: "Clear", symbol: "eraser") {
                    controller.clearActiveNote()
                }
            }

            actionButton(
                title: isDeleteArmed ? "Confirm" : "Delete",
                symbol: "trash",
                tint: isDeleteArmed ? .red : nil
            ) {
                endRenaming()
                controller.deleteSelectedNote()
            }
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(10))
        .padding(.bottom, s(2))
    }

    private var isDeleteArmed: Bool {
        controller.pendingDeleteNoteID != nil && controller.pendingDeleteNoteID == controller.selectedNoteID
    }

    private func actionButton(
        title: String,
        symbol: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: s(5)) {
                Image(systemName: symbol)
                    .font(.system(size: s(11), weight: .semibold))
                Text(title)
                    .font(.system(size: s(12), weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint ?? .primary)
            .frame(maxWidth: .infinity)
            .frame(height: s(30))
            .background(
                RoundedRectangle(cornerRadius: s(8), style: .continuous)
                    .fill((tint ?? Color.secondary).opacity(0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            Button {
                onQuit()
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: s(12), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(8))
        .padding(.bottom, s(14))
    }
}

// MARK: - Text view

/// Plain-text editor backed directly by `NSTextView`.
///
/// SwiftUI's `TextEditor` pushes the entire document back through its binding and re-diffs it on
/// every keystroke, which turns a long note into visible input lag. `NSTextView` edits its own
/// storage in place and merely reports the result, and it brings native undo, find and Unicode
/// text handling with it.
private struct ScratchpadTextView: NSViewRepresentable {
    /// Identity of the note on screen. A change means the whole document is replaced; the same id
    /// with different text means the controller rewrote the body (a clear, or its undo).
    var noteID: UUID?
    var text: String
    var fontSize: CGFloat
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .textColor
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 6, height: 8)

        // A scratchpad is where people park URLs, snippets and IDs. Silently rewriting their
        // quotes, hyphens and abbreviations would corrupt exactly the text they came here to keep
        // verbatim, so every "smart" substitution is off.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        textView.string = text
        context.coordinator.noteID = noteID
        context.coordinator.lastReportedText = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.onTextChange = onTextChange

        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }

        let switchedNote = context.coordinator.noteID != noteID
        // Compared against what the text view itself last reported rather than against
        // `textView.string`, which would materialize the whole storage on every SwiftUI update.
        // The two strings share a buffer in the common case, so this is effectively free.
        guard switchedNote || text != context.coordinator.lastReportedText else { return }

        textView.string = text
        context.coordinator.noteID = noteID
        context.coordinator.lastReportedText = text

        if switchedNote {
            // A different document must not inherit the previous note's undo stack — ⌘Z would
            // otherwise paste one note's deleted text into another.
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void
        var noteID: UUID?

        /// Last value this text view handed to the controller. Lets `updateNSView` tell "the
        /// controller echoed my own edit back" apart from "something else changed the body".
        var lastReportedText = ""

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let updated = textView.string
            lastReportedText = updated
            onTextChange(updated)
        }
    }
}

// MARK: - Settings

private struct ScratchpadSettingsView: View {
    @ObservedObject var controller: ScratchpadController
    var onQuit: () -> Void
    var onClose: () -> Void

    private let sizes: [CGFloat] = [11, 13, 16, 20]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Scratchpad Settings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            Text("Text size")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                ForEach(sizes, id: \.self) { size in
                    Button {
                        controller.setFontSize(size)
                    } label: {
                        Text("\(Int(size))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(controller.fontSize == size ? Color.white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(controller.fontSize == size ? Color.accentColor : Color.secondary.opacity(0.14))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Notes are saved automatically as you type, one file per note, and are flushed to disk whenever the panel closes or the app quits.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Scratchpad", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: ScratchpadSizing.settingsSize().width, height: ScratchpadSizing.settingsSize().height)
    }
}
