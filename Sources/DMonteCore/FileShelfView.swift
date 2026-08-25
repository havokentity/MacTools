import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The floating File Shelf popover: a drop target that shelves whatever is dragged onto it, a list
/// of what is parked there with Reveal / Copy Path / Remove on each row, and a Clear Shelf action.
/// Every row is itself draggable, so the way out is the same gesture as the way in. Content is
/// scaled to match the menu-bar/display scale so it fits the scaled panel (same approach as the
/// other tools).
public struct FileShelfPopoverView: View {
    @ObservedObject var store: FileShelfStore
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    @State private var isDropTargeted = false

    private let scale = FileShelfSizing.currentScale

    public init(store: FileShelfStore, onQuit: @escaping () -> Void) {
        self.store = store
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var accent: Color { .orange }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)

                if store.items.isEmpty {
                    emptyState
                } else {
                    shelfList
                }

                Spacer(minLength: 0)

                if let status = store.statusMessage {
                    statusLine(status)
                }

                clearRow
                footer
            }
            // The drop target is the whole panel, not a dedicated well inside it. People aim at
            // the window, and a drop that lands two points outside a well is a drop that silently
            // did nothing.
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                shelve(from: providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(accent, lineWidth: s(3))
                        .allowsHitTesting(false)
                }
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    FileShelfSettingsView(
                        store: store,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: FileShelfSizing.preferredSize().width, height: FileShelfSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: store.items.isEmpty ? "tray" : "tray.full.fill")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(store.items.isEmpty ? Color.secondary : accent)

            Text("File Shelf")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: s(11), weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, s(6))
                    .padding(.vertical, s(2))
                    .background(
                        Capsule().fill(accent.opacity(0.16))
                    )
            }

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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: s(10)) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: s(34), weight: .regular))
                .foregroundStyle(isDropTargeted ? accent : Color.secondary)
                .symbolRenderingMode(.hierarchical)

            Text("Drop files here")
                .font(.system(size: s(14), weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Drag files onto this window or onto the menu bar icon to park them, then drag them straight back out into any app. Nothing is copied — the shelf only remembers where each file lives.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, s(24))
        .padding(.vertical, s(30))
    }

    // MARK: - Shelf list

    private var shelfList: some View {
        ScrollView {
            VStack(spacing: s(8)) {
                ForEach(store.items) { item in
                    shelfRow(item)
                }
            }
            .padding(.horizontal, s(16))
            .padding(.vertical, s(12))
        }
    }

    private func shelfRow(_ item: ShelfItem) -> some View {
        HStack(spacing: s(9)) {
            FileIcon(url: item.url, isAvailable: item.isAvailable, size: s(28))

            VStack(alignment: .leading, spacing: s(2)) {
                Text(item.displayName)
                    .font(.system(size: s(13), weight: .semibold))
                    .foregroundStyle(item.isAvailable ? .primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle(for: item))
                    .font(.system(size: s(10), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: s(4))

            rowButton(systemImage: "magnifyingglass", help: "Reveal in Finder", isEnabled: item.isAvailable) {
                store.revealInFinder(id: item.id)
            }
            rowButton(systemImage: "doc.on.doc", help: "Copy path", isEnabled: true) {
                store.copyPath(id: item.id)
            }
            rowButton(systemImage: "xmark", help: "Remove from shelf", isEnabled: true) {
                store.remove(id: item.id)
            }
        }
        .padding(.horizontal, s(9))
        .padding(.vertical, s(7))
        .background(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(Color.secondary.opacity(item.isAvailable ? 0.12 : 0.06))
        )
        .opacity(item.isAvailable ? 1 : 0.65)
        // Dragging out hands over the real file URL, so the receiving app copies/opens/attaches
        // the actual file rather than a description of it. An unavailable row offers an empty
        // provider: there is nothing to give, and a drag that produced a broken path would be
        // worse than one that produces nothing.
        .onDrag {
            guard item.isAvailable, let url = item.url, let provider = NSItemProvider(contentsOf: url) else {
                return NSItemProvider()
            }
            return provider
        }
    }

    private func subtitle(for item: ShelfItem) -> String {
        switch item.availability {
        case .available:
            // The containing folder, not the whole path: the file's own name is already on the
            // line above, and repeating it wastes the width that would show where it lives.
            return item.url?.deletingLastPathComponent().path ?? item.displayPath
        case .missing:
            // Covers both ways a real bookmark stops being followable, because the row cannot tell
            // them apart and guessing "unplugged" at a file the user deleted reads as a bug.
            return "Not there right now — deleted, or the disk is unplugged"
        case .unresolvable:
            // The only state the user has to act on: this one does not come back on its own.
            return "Can’t be found any more — shelve it again"
        }
    }

    private func rowButton(
        systemImage: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: s(10), weight: .bold))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
                .frame(width: s(22), height: s(22))
                .background(
                    RoundedRectangle(cornerRadius: s(6), style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
                .contentShape(RoundedRectangle(cornerRadius: s(6), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }

    // MARK: - Status

    private func statusLine(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, s(16))
            .padding(.bottom, s(8))
    }

    // MARK: - Clear

    @ViewBuilder
    private var clearRow: some View {
        if store.isConfirmingClearAll {
            HStack(spacing: s(8)) {
                Button {
                    store.confirmClearAll()
                } label: {
                    Text("Clear \(store.items.count) File\(store.items.count == 1 ? "" : "s")")
                        .font(.system(size: s(12), weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: s(32))
                        .background(
                            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                                .fill(accent)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    store.cancelClearAll()
                } label: {
                    Text("Cancel")
                        .font(.system(size: s(12), weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: s(78))
                        .frame(height: s(32))
                        .background(
                            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                                .fill(Color.secondary.opacity(0.14))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, s(16))
            .padding(.bottom, s(8))
        } else if !store.items.isEmpty {
            Button {
                store.requestClearAll()
            } label: {
                HStack(spacing: s(8)) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: s(13), weight: .semibold))
                    Text("Clear Shelf")
                        .font(.system(size: s(13), weight: .semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: s(34))
                .background(
                    RoundedRectangle(cornerRadius: s(8), style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
                .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Take everything off the shelf. The files themselves are not touched.")
            .padding(.horizontal, s(16))
            .padding(.bottom, s(8))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: s(12), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Re-check every file on the shelf")

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
        .padding(.top, s(4))
        .padding(.bottom, s(14))
    }

    // MARK: - Drop handling

    /// Pulls file URLs out of a SwiftUI drop and shelves them.
    private func shelve(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let collector = DroppedURLCollector(expected: fileProviders.count, store: store)
        collector.startDeadline()
        for (index, provider) in fileProviders.enumerated() {
            // The completion handler runs off the main actor. `collector` is a main-actor class
            // and therefore Sendable, so it can cross the boundary; the hop back onto the main
            // actor is what makes touching its state legal.
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    collector.accept(url, at: index)
                }
            }
        }

        return true
    }
}

/// Gathers the URLs of one drag and shelves them together, in the order the drag carried them.
///
/// The providers in a multi-file drag answer in whatever order they feel like, and shelving each
/// one as it arrived would land the files on the shelf in an order that has nothing to do with
/// what the user selected. Waiting for the last one costs effectively nothing — a provider
/// carrying a file URL hands over the URL, it does not read the file — and it makes a drop into
/// the popover behave exactly like a drop onto the menu-bar icon, which reads the pasteboard in
/// one go and is ordered for free.
///
/// Waiting for every provider is only safe because the wait has an end. `NSItemProvider`'s
/// completion handler is a promise made by whichever *other* application assembled the drag, and
/// nothing in this process can make that application keep it: a provider whose loader wedges, or
/// whose source crashes before its XPC reply lands, simply never answers. Without a deadline the
/// count never reaches zero and the entire drop is swallowed in silence, which is the one outcome
/// this tool must never produce — a drag that visibly landed has to leave something behind.
@MainActor
final class DroppedURLCollector {
    /// How long a batch waits for a provider that has stopped answering.
    ///
    /// Long enough that no honest provider is cut off — these hand over a URL, they do not read the
    /// file — and short enough that a user who dropped something and saw nothing happen has not yet
    /// given up and gone looking for the menu-bar icon.
    static let defaultDeadline: TimeInterval = 10

    private var urls: [URL?]
    /// Which slots have answered. Tracked separately from `urls`, because a provider is allowed to
    /// report failure — a `nil` URL is a real answer, and is indistinguishable from an empty slot.
    private var answered: [Bool]
    private var remaining: Int
    private var hasShelved = false
    private let store: FileShelfStore
    private var deadline: Task<Void, Never>?

    init(expected: Int, store: FileShelfStore) {
        urls = Array(repeating: nil, count: expected)
        answered = Array(repeating: false, count: expected)
        remaining = expected
        self.store = store
    }

    /// Starts the clock on the batch. Separate from `init` so the caller registers every provider
    /// first, and so a test can ask for a deadline it does not have to sit through.
    ///
    /// The task captures `self` strongly on purpose: the collector is otherwise owned only by the
    /// provider completion handlers, and a provider that is torn down without calling back would
    /// take the whole batch with it. Holding it until the deadline fires — or until the normal path
    /// cancels the task — is what makes "the batch is always flushed exactly once" true.
    func startDeadline(after seconds: TimeInterval = defaultDeadline) {
        deadline = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            shelveWhatArrived()
        }
    }

    /// Records one provider's answer, and shelves the batch once every provider has replied. A
    /// provider that failed contributes `nil` and is simply left out; it must still be counted, or
    /// one unreadable item in a drag would strand the whole batch.
    func accept(_ url: URL?, at index: Int) {
        guard !hasShelved, urls.indices.contains(index), !answered[index] else { return }

        answered[index] = true
        urls[index] = url
        remaining -= 1
        guard remaining == 0 else { return }

        shelveWhatArrived()
    }

    /// Hands the store whatever the batch has, once. Everything that has not answered by now is
    /// treated as a provider that failed, which is the same way a `nil` answer is already treated.
    private func shelveWhatArrived() {
        guard !hasShelved else { return }
        hasShelved = true
        deadline?.cancel()
        deadline = nil

        let resolved = urls.compactMap { $0 }
        guard !resolved.isEmpty else { return }
        store.shelve(urls: resolved)
    }
}

/// The Finder icon for a shelved file, which is what people actually recognise a file by. An
/// entry that no longer resolves falls back to a generic question-marked document rather than
/// borrowing the icon of whatever happens to sit at its old path now.
private struct FileIcon: View {
    var url: URL?
    var isAvailable: Bool
    var size: CGFloat

    var body: some View {
        if isAvailable, let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "questionmark.folder")
                .font(.system(size: size * 0.7, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Settings

private struct FileShelfSettingsView: View {
    @ObservedObject var store: FileShelfStore
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("File Shelf Settings")
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

            settingRow(title: "Confirm before clearing") {
                GreenSwitch(isOn: Binding(
                    get: { store.confirmsClearAll },
                    set: { store.setConfirmsClearAll($0) }
                ))
            }

            Text("When on, Clear Shelf asks for a second press before emptying the shelf.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("The shelf never copies anything. Each entry is a bookmark to the original file, so it keeps working after you rename or move the file, and removing a row leaves the file exactly where it is. A file that has been deleted, or that lives on a disk you have unplugged, stays on the shelf and is shown as unavailable rather than disappearing.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit File Shelf", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: FileShelfSizing.settingsSize().width, height: FileShelfSizing.settingsSize().height)
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
