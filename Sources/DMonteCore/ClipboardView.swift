import AppKit
import SwiftUI

/// The floating clipboard popover: search, type filters, a keyboard-selectable history list,
/// a live preview of the selected entry, and a settings overlay. Content is scaled to match the
/// menu-bar/display scale so it fits the scaled panel (same approach as the other tools).
public struct ClipboardPopoverView: View {
    @ObservedObject var controller: ClipboardController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    @FocusState private var searchFocused: Bool
    private let scale = ClipboardSizing.currentScale

    public init(controller: ClipboardController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                searchField
                typeFilters
                Divider().opacity(0.6)
                historyList
                Divider().opacity(0.6)
                preview
                footer
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    ClipboardSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: ClipboardSizing.preferredSize().width, height: ClipboardSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
        .onAppear { searchFocused = true }
        .onChange(of: controller.showToken) { _, _ in
            searchFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Button {
                controller.togglePause()
            } label: {
                Image(systemName: controller.isPaused ? "pause.circle.fill" : "doc.on.clipboard.fill")
                    .font(.system(size: s(15), weight: .semibold))
                    .foregroundStyle(controller.isPaused ? Color.orange : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(controller.isPaused ? "Resume capturing" : "Pause capturing")

            Text(controller.isPaused ? "Clipboard · Paused" : "Clipboard")
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

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: s(7)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search clipboard", text: $controller.searchText)
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

    // MARK: - Type filters

    private var typeFilters: some View {
        HStack(spacing: s(6)) {
            filterChip(title: "All", isSelected: controller.typeFilter == nil) {
                controller.typeFilter = nil
                controller.selectFirst()
            }
            ForEach([ClipboardKind.text, .link, .image, .file], id: \.self) { kind in
                filterChip(title: kind.label, isSelected: controller.typeFilter == kind) {
                    controller.typeFilter = controller.typeFilter == kind ? nil : kind
                    controller.selectFirst()
                }
            }
            Spacer()
        }
        .padding(.horizontal, s(14))
        .padding(.bottom, s(8))
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: s(11), weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .padding(.horizontal, s(9))
                .padding(.vertical, s(4))
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - History list

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: s(3)) {
                    let entries = controller.filteredEntries
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            ClipboardRow(
                                entry: entry,
                                index: index,
                                isSelected: entry.id == controller.selectedID,
                                scale: scale,
                                thumbnail: entry.kind == .image ? controller.store.thumbnail(for: entry) : nil,
                                onSelect: { controller.selectedID = entry.id },
                                onPaste: { controller.paste(entry, asPlainText: false) },
                                onTogglePin: { controller.togglePin(entry.id) },
                                onDelete: { controller.delete(entry.id) }
                            )
                            .id(entry.id)
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
            .onChange(of: controller.showToken) { _, _ in
                if let first = controller.filteredEntries.first?.id {
                    proxy.scrollTo(first, anchor: .top)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: s(8)) {
            Image(systemName: controller.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: s(30), weight: .light))
                .foregroundStyle(.secondary)
            Text(controller.searchText.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.system(size: s(13), weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, s(40))
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if let entry = controller.selectedEntry {
            HStack(alignment: .top, spacing: s(10)) {
                if entry.kind == .image, let image = controller.store.thumbnail(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: s(110), maxHeight: s(70))
                        .clipShape(RoundedRectangle(cornerRadius: s(6), style: .continuous))
                } else {
                    ScrollView {
                        Text(entry.fullText)
                            .font(.system(size: s(11.5), design: entry.kind == .file ? .monospaced : .default))
                            .foregroundStyle(.primary.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .trailing, spacing: s(4)) {
                    Text(entry.kind.label)
                        .font(.system(size: s(10), weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(Self.metaLine(for: entry))
                        .font(.system(size: s(10)))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .frame(width: s(86), alignment: .trailing)
            }
            .padding(.horizontal, s(14))
            .frame(height: s(80))
        } else {
            Color.clear.frame(height: s(80))
        }
    }

    private static func metaLine(for entry: ClipboardEntry) -> String {
        var parts: [String] = []
        if let app = entry.sourceAppName, !app.isEmpty { parts.append(app) }
        if entry.kind == .image {
            parts.append(UInt64(entry.byteCount).diskBytesString)
        } else if entry.kind != .file {
            parts.append("\((entry.text ?? "").count) chars")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: s(10)) {
            footerHint("⏎", "Paste")
            footerHint("⌥⏎", "Plain")
            footerHint("⌘1–9", "Quick")
            footerHint("⌘P", "Pin")
            Spacer()
            footerHint("⌫", "Delete")
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

// MARK: - Row

private struct ClipboardRow: View {
    var entry: ClipboardEntry
    var index: Int
    var isSelected: Bool
    var scale: CGFloat
    var thumbnail: NSImage?
    var onSelect: () -> Void
    var onPaste: () -> Void
    var onTogglePin: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    var body: some View {
        HStack(spacing: s(10)) {
            leadingVisual

            VStack(alignment: .leading, spacing: s(1)) {
                Text(entry.previewText)
                    .font(.system(size: s(12.5), weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: s(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: s(4))

            trailing
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
        .onTapGesture(count: 2) { onPaste() }
        .onTapGesture(count: 1) { onSelect() }
        .contextMenu {
            Button("Paste") { onPaste() }
            Button(entry.pinned ? "Unpin" : "Pin") { onTogglePin() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if entry.kind == .image, let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: s(28), height: s(28))
                .clipShape(RoundedRectangle(cornerRadius: s(6), style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: s(6), style: .continuous)
                .fill(tint.opacity(0.18))
                .frame(width: s(28), height: s(28))
                .overlay(
                    Image(systemName: entry.kind.iconName)
                        .font(.system(size: s(13), weight: .semibold))
                        .foregroundStyle(tint)
                )
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovered {
            HStack(spacing: s(2)) {
                Button(action: onTogglePin) {
                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                        .font(.system(size: s(11)))
                        .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: s(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else if entry.pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: s(10)))
                .foregroundStyle(Color.accentColor)
        } else if index < 9 {
            Text("⌘\(index + 1)")
                .font(.system(size: s(9), weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, s(4))
                .padding(.vertical, s(1))
                .background(RoundedRectangle(cornerRadius: s(3)).fill(Color.primary.opacity(0.08)))
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let app = entry.sourceAppName, !app.isEmpty { parts.append(app) }
        parts.append(Self.relativeTime(from: entry.date))
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch entry.kind {
        case .text: .secondary
        case .richText: .purple
        case .link: .blue
        case .image: .pink
        case .file: .teal
        case .color: .orange
        }
    }

    private static func relativeTime(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }
}

// MARK: - Settings

private struct ClipboardSettingsView: View {
    @ObservedObject var controller: ClipboardController
    var onQuit: () -> Void
    var onClose: () -> Void

    @AppStorage(DefaultsKey.clipboardOpenAtLogin, store: AppDefaults.shared) private var openAtLogin = true
    @AppStorage(DefaultsKey.clipboardMaxHistory, store: AppDefaults.shared) private var maxHistory = 200

    private let historyOptions = [50, 100, 200, 500, 1000]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Clipboard Settings")
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

            settingRow(title: "Open at login") {
                GreenSwitch(isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, newValue in
                        ClipboardLoginItem.setEnabled(newValue)
                    }
            }

            settingRow(title: "History size") {
                Picker("", selection: $maxHistory) {
                    ForEach(historyOptions, id: \.self) { option in
                        Text("\(option)").tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
            }

            if controller.needsAccessibility {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pasting needs Accessibility access")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Allow DMonte Clipboard under Privacy & Security → Accessibility so it can paste into other apps.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings") {
                        ClipboardPaste.promptForAccessibilityPermission()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    controller.clearAll()
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                Spacer()
                Button(role: .destructive) {
                    onClose()
                    onQuit()
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }

            Text("Pinned items are kept when clearing. Password-manager and concealed copies are never recorded.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340, height: controller.needsAccessibility ? 360 : 250)
    }

    private func settingRow<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            trailing()
        }
    }
}
