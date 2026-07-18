import AppKit
import SwiftUI

/// The floating Snippets popover: a search field, the snippet library, an editor sheet and a
/// settings overlay. Clicking a snippet pastes it into whatever app the user came from. Content
/// is scaled to the menu-bar/display scale so it fits the scaled panel (as in the other tools).
public struct SnippetsPopoverView: View {
    @ObservedObject var controller: SnippetsController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    @FocusState private var searchFocused: Bool
    private let scale = SnippetsSizing.currentScale

    public init(controller: SnippetsController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                searchField
                if controller.needsAccessibility {
                    accessibilityNotice
                }
                Divider().opacity(0.6)
                snippetList
                Divider().opacity(0.6)
                footer
            }

            if let session = controller.editorSession {
                PreferencesOverlay(cornerRadius: 18) {
                    SnippetEditorView(
                        session: session,
                        scale: scale,
                        onSave: { title, body, expands in
                            controller.commitEditor(title: title, body: body, expandsPlaceholders: expands)
                        },
                        onDelete: session.id.map { id in
                            { controller.delete(id) }
                        },
                        onCancel: { controller.cancelEditing() }
                    )
                    // A fresh identity per session so the editor's own @State starts from the
                    // snippet being opened instead of keeping the previous one's text.
                    .id(session.editorID)
                }
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    SnippetsSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: SnippetsSizing.preferredSize().width, height: SnippetsSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
        .onAppear { searchFocused = true }
        .onChange(of: controller.showToken) { _, _ in
            // An open editor deliberately survives a reopen, and its overlay covers the search
            // field — so refocusing search here would send the user's next keystrokes into a
            // control they cannot see, silently filtering the list instead of typing the snippet.
            // The panel is only ordered out, never torn down, so leaving focus alone restores the
            // editor field the window already had as its first responder.
            guard controller.editorSession == nil else { return }
            searchFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "note.text")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("Snippets")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            Spacer()

            Button {
                controller.beginCreating()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: s(15), weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("New snippet (⌘N)")

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

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: s(7)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search snippets", text: $controller.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: s(13)))
                .focused($searchFocused)
                .onChange(of: controller.searchText) { _, _ in
                    controller.selectFirst()
                }

            if !controller.searchText.isEmpty {
                Button {
                    controller.searchText = ""
                    controller.selectFirst()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: s(12)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, s(10))
        .frame(height: s(32))
        .background(
            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .padding(.horizontal, s(14))
        .padding(.bottom, s(8))
    }

    // MARK: - Accessibility notice

    /// Without Accessibility the ⌘V can't be synthesized, so a click copies but does not paste.
    /// Saying so up front beats letting the user click a snippet into a window that never changes.
    private var accessibilityNotice: some View {
        HStack(spacing: s(7)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: s(11), weight: .semibold))
                .foregroundStyle(.orange)

            Text("Snippets are copied, not pasted — Accessibility access is off.")
                .font(.system(size: s(10.5)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Fix") {
                openAccessibilitySettings()
            }
            .font(.system(size: s(10.5), weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, s(9))
        .padding(.vertical, s(6))
        .background(RoundedRectangle(cornerRadius: s(8), style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, s(14))
        .padding(.bottom, s(8))
    }

    // MARK: - List

    private var snippetList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: s(3)) {
                    let snippets = controller.filteredSnippets
                    if snippets.isEmpty {
                        emptyState
                    } else {
                        ForEach(snippets) { snippet in
                            SnippetRow(
                                snippet: snippet,
                                isSelected: snippet.id == controller.selectedID,
                                canMoveUp: controller.canMove(snippet.id, by: -1),
                                canMoveDown: controller.canMove(snippet.id, by: 1),
                                scale: scale,
                                onPaste: { controller.paste(snippet) },
                                onEdit: { controller.beginEditing(snippet.id) },
                                onMoveUp: { controller.move(snippet.id, by: -1) },
                                onMoveDown: { controller.move(snippet.id, by: 1) },
                                onDelete: { controller.delete(snippet.id) }
                            )
                            .id(snippet.id)
                        }
                    }
                }
                .padding(.horizontal, s(8))
                .padding(.vertical, s(6))
            }
            .onChange(of: controller.selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: s(8)) {
            Image(systemName: controller.isLibraryEmpty ? "note.text.badge.plus" : "magnifyingglass")
                .font(.system(size: s(30), weight: .light))
                .foregroundStyle(.secondary)

            Text(controller.isLibraryEmpty ? "No snippets yet" : "No matches")
                .font(.system(size: s(13), weight: .medium))
                .foregroundStyle(.secondary)

            if controller.isLibraryEmpty {
                Button {
                    controller.beginCreating()
                } label: {
                    Label("New Snippet", systemImage: "plus")
                        .font(.system(size: s(12), weight: .semibold))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, s(40))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: s(10)) {
            footerHint("⏎", "Paste")
            footerHint("⌘N", "New")
            footerHint("⌘E", "Edit")
            Spacer()
            footerHint("⌘↑↓", "Reorder")
        }
        .padding(.horizontal, s(14))
        .padding(.top, s(6))
        .padding(.bottom, s(10))
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: s(3)) {
            Text(key)
                .font(.system(size: s(9), weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, s(4))
                .padding(.vertical, s(1))
                .background(RoundedRectangle(cornerRadius: s(3)).fill(Color.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: s(9)))
                .foregroundStyle(.secondary)
        }
    }
}

/// Opens the Accessibility pane, prompting first so DMonte Snippets is already listed there.
@MainActor
private func openAccessibilitySettings() {
    ClipboardPaste.promptForAccessibilityPermission()
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Row

private struct SnippetRow: View {
    var snippet: Snippet
    var isSelected: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
    var scale: CGFloat
    var onPaste: () -> Void
    var onEdit: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    var body: some View {
        HStack(spacing: s(10)) {
            RoundedRectangle(cornerRadius: s(6), style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: s(28), height: s(28))
                .overlay(
                    Image(systemName: snippet.pastesADifferentValueEachTime ? "calendar.badge.clock" : "text.alignleft")
                        .font(.system(size: s(12), weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: s(1)) {
                Text(snippet.displayTitle)
                    .font(.system(size: s(12.5), weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(snippet.previewText)
                    .font(.system(size: s(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: s(4))

            if isHovered {
                rowActions
            }
        }
        .padding(.horizontal, s(8))
        .padding(.vertical, s(6))
        .background(
            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture { onPaste() }
        .contextMenu {
            Button("Paste") { onPaste() }
            Button("Edit…") { onEdit() }
            Divider()
            Button("Move Up") { onMoveUp() }.disabled(!canMoveUp)
            Button("Move Down") { onMoveDown() }.disabled(!canMoveDown)
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .help("Click to paste into the app you came from")
    }

    private var rowActions: some View {
        HStack(spacing: s(2)) {
            rowButton(systemImage: "chevron.up", help: "Move up", isEnabled: canMoveUp, action: onMoveUp)
            rowButton(systemImage: "chevron.down", help: "Move down", isEnabled: canMoveDown, action: onMoveDown)
            rowButton(systemImage: "pencil", help: "Edit", isEnabled: true, action: onEdit)
            rowButton(systemImage: "trash", help: "Delete", isEnabled: true, action: onDelete)
        }
    }

    private func rowButton(systemImage: String, help: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: s(11)))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: s(18), height: s(18))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}

// MARK: - Editor

private struct SnippetEditorView: View {
    var session: SnippetEditorSession
    var scale: CGFloat
    var onSave: (String, String, Bool) -> Void
    var onDelete: (() -> Void)?
    var onCancel: () -> Void

    @State private var title: String
    /// The snippet's text. Named `text`, not `body`: a stored `body` would collide with the
    /// `View` protocol's own `body` requirement.
    @State private var text: String
    @State private var expandsPlaceholders: Bool
    @FocusState private var titleFocused: Bool

    init(
        session: SnippetEditorSession,
        scale: CGFloat,
        onSave: @escaping (String, String, Bool) -> Void,
        onDelete: (() -> Void)?,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.scale = scale
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _title = State(initialValue: session.title)
        _text = State(initialValue: session.body)
        _expandsPlaceholders = State(initialValue: session.expandsPlaceholders)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(session.isNew ? "New Snippet" : "Edit Snippet")
                    .font(.system(size: 16, weight: .bold))

                Spacer()

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($titleFocused)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            HStack {
                Text("Insert date & time")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                GreenSwitch(isOn: $expandsPlaceholders)
            }

            Text(placeholderHelp)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                Spacer()

                Button("Cancel") { onCancel() }

                // ⌘S rather than the default Return action: snippets are multi-line, and a
                // Return-to-save button would swallow every newline typed in the editor.
                Button("Save") { onSave(title, text, expandsPlaceholders) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Save (⌘S)")
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { titleFocused = true }
    }


    /// The supported tokens, read straight off `SnippetsKit.placeholders` so the help text cannot
    /// drift from what expansion actually replaces.
    private var placeholderHelp: String {
        let tokens = SnippetsKit.placeholders
            .map { "\($0.token) — \($0.description.lowercased())" }
            .joined(separator: ", ")
        return "When on, these are replaced as the snippet is pasted: \(tokens). Anything else in braces is pasted unchanged."
    }
}

// MARK: - Settings

private struct SnippetsSettingsView: View {
    @ObservedObject var controller: SnippetsController
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Snippets Settings")
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

            Text("Click a snippet to paste it into the app you were last working in. Snippets are stored on this Mac only, readable by you alone.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.needsAccessibility {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pasting needs Accessibility access")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Allow DMonte Snippets under Privacy & Security → Accessibility so it can paste into other apps. Without it a snippet is still copied to the clipboard.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings") {
                        openAccessibilitySettings()
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Snippets", systemImage: "power")
            }
        }
        .padding(20)
        .frame(width: 340, height: controller.needsAccessibility ? 340 : 230)
        .onAppear { controller.refreshAccessibilityState() }
    }
}
