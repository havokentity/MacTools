import AppKit
import SwiftUI

public struct InstalledApplication: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let size: UInt64?
    public let bundleIdentifier: String?

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

public enum ApplicationScanner {
    public static func scan() -> [InstalledApplication] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            homeApplications
        ]

        var seen = Set<String>()
        var apps: [InstalledApplication] = []

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else {
                    continue
                }

                let standardizedPath = url.standardizedFileURL.path
                guard seen.insert(standardizedPath).inserted else {
                    continue
                }

                apps.append(
                    InstalledApplication(
                        id: standardizedPath,
                        name: displayName(for: url),
                        path: standardizedPath,
                        size: nil,
                        bundleIdentifier: Bundle(url: url)?.bundleIdentifier
                    )
                )
            }
        }

        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func applyingSize(to app: InstalledApplication) -> InstalledApplication {
        InstalledApplication(
            id: app.id,
            name: app.name,
            path: app.path,
            size: directorySize(at: app.url),
            bundleIdentifier: app.bundleIdentifier
        )
    }

    private static func displayName(for url: URL) -> String {
        let localizedName = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.deletingPathExtension().lastPathComponent
        return localizedName.hasSuffix(".app") ? String(localizedName.dropLast(4)) : localizedName
    }

    private static func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        return enumerator.reduce(UInt64(0)) { partialResult, entry in
            guard let fileURL = entry as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
                return partialResult
            }

            return partialResult + UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
    }
}

enum UninstallerSelection {
    static func filteredApps(_ apps: [InstalledApplication], query rawQuery: String) -> [InstalledApplication] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return apps
        }

        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    static func selectedApp(in filteredApps: [InstalledApplication], selectedID: InstalledApplication.ID?) -> InstalledApplication? {
        guard let selectedID else {
            return filteredApps.first
        }

        return filteredApps.first { $0.id == selectedID } ?? filteredApps.first
    }
}

/// What the last uninstall has to say for itself.
///
/// The success line and the failure line are two halves of one outcome rather than alternatives.
/// A sweep that trashes three items out of `~/Library` and is refused on two out of `/Library` has
/// to report both: told only about the failure, the user goes hunting in `~/Library` for files
/// that are already in the Trash, or re-runs the sweep.
struct UninstallerFeedback: Equatable, Sendable {
    /// What did move. Rendered in the secondary colour.
    var status: String?

    /// What did not. Rendered in red, *underneath* the status line rather than instead of it.
    var failure: String?

    static let empty = UninstallerFeedback()

    var isEmpty: Bool {
        status == nil && failure == nil
    }

    /// macOS refused the bundle itself, so the sweep never ran and nothing moved.
    static func bundleRefused(reason: String) -> UninstallerFeedback {
        UninstallerFeedback(failure: reason)
    }

    /// The bundle moved and there was nothing else to do — either no leftovers were found or the
    /// user unticked every row in the review sheet.
    static func bundleTrashed(appName: String) -> UninstallerFeedback {
        UninstallerFeedback(status: "Moved \(appName) to Trash.")
    }

    /// The bundle moved and the sweep ran. Both lines are filled in when the sweep was partial,
    /// which is the common case: the tool is not privileged, so the `/Library` rows usually fail
    /// while the `~/Library` ones succeed.
    static func sweepFinished(appName: String, result: LeftoverRemovalResult) -> UninstallerFeedback {
        var feedback = UninstallerFeedback()

        // "and 0 support items (Zero KB)" is technically true and reads like a malfunction, so a
        // sweep that moved nothing reports the bundle alone and lets the failure line explain why.
        if result.trashedCount == 0 {
            feedback.status = "Moved \(appName) to Trash."
        } else {
            let noun = result.trashedCount == 1 ? "item" : "items"
            feedback.status = "Moved \(appName) and \(result.trashedCount) support \(noun) (\(result.trashedBytes.bytesString)) to Trash."
        }

        if let firstFailure = result.failures.first {
            feedback.failure = result.failures.count == 1
                ? "Could not remove \(firstFailure.path): \(firstFailure.reason)"
                : "Could not remove \(result.failures.count) support items. First: \(firstFailure.path) — \(firstFailure.reason)"
        }

        return feedback
    }
}

/// Everything the details pane draws, resolved in one pass.
///
/// The feedback is a field of the pane rather than something the selected-app branch renders, and
/// that is the entire point of the type: uninstalling the last app matching the current search
/// leaves nothing selected, and that is precisely the case where the user most needs to hear that
/// half the sweep was refused. Nested inside the selected-app branch, that report was silently
/// dropped exactly when it mattered.
struct UninstallerDetailsPane: Equatable, Sendable {
    /// The app whose details are shown, or nil when the list has nothing to show.
    let app: InstalledApplication?

    /// The stand-in shown when `app` is nil. Non-nil exactly when `app` is nil.
    let placeholder: String?

    /// The outcome of the last uninstall, shown whether or not an app is selected.
    let feedback: UninstallerFeedback

    var showsFeedback: Bool {
        !feedback.isEmpty
    }

    static func resolve(
        filteredApps: [InstalledApplication],
        selectedID: InstalledApplication.ID?,
        feedback: UninstallerFeedback
    ) -> UninstallerDetailsPane {
        let app = UninstallerSelection.selectedApp(in: filteredApps, selectedID: selectedID)

        return UninstallerDetailsPane(
            app: app,
            placeholder: app == nil ? (filteredApps.isEmpty ? "No apps found" : "Select an app") : nil,
            feedback: feedback
        )
    }
}

public struct UninstallerPopoverView: View {
    var onQuit: () -> Void

    @State private var apps: [InstalledApplication] = []
    @State private var selectedAppID: InstalledApplication.ID?
    @State private var searchText = ""
    @State private var isScanning = true
    @State private var isSizing = false
    @State private var scanToken = UUID()
    @State private var feedback = UninstallerFeedback.empty
    @State private var review: LeftoverReview?
    @State private var selectedLeftoverIDs: Set<String> = []
    @State private var isPreparingRemoval = false
    @State private var isRemoving = false

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: UninstallerSizing.sidebarWidth)

                Divider()

                details
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: UninstallerSizing.windowSize.width, height: UninstallerSizing.windowSize.height)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.64, green: 0.61, blue: 0.78).opacity(0.26))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
        }
        .task {
            await reload()
        }
        .sheet(item: $review) { pendingReview in
            LeftoverReviewSheet(
                app: pendingReview.app,
                items: pendingReview.items,
                selection: $selectedLeftoverIDs,
                onCancel: { review = nil },
                onConfirm: { performUninstall(pendingReview) }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Uninstall Apps")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Quit Uninstaller")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.74))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if isScanning {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Scanning apps")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredApps) { app in
                            AppRow(app: app, isSelected: app.id == selectedApp?.id) {
                                select(app)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var details: some View {
        // Resolved in one pass, up front, because the uninstall report belongs to the pane and not
        // to the selected app: trashing the last app that matches the current search leaves nothing
        // selected, and that is exactly the moment the user most needs to hear that the /Library
        // half of the sweep was refused.
        let pane = UninstallerDetailsPane.resolve(
            filteredApps: filteredApps,
            selectedID: selectedAppID,
            feedback: feedback
        )

        return VStack(alignment: .leading, spacing: 14) {
            if let app = pane.app {
                HStack(alignment: .top, spacing: 14) {
                    AppIcon(url: app.url, size: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 22, weight: .bold))

                        Text(app.path)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Text(app.sizeLabel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Moves the app bundle to Trash, then offers the support files it left in ~/Library and /Library. You review the exact list before anything moves.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                feedbackLines(pane.feedback, alignment: .leading)

                Spacer()

                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                    } label: {
                        Label("Reveal", systemImage: "finder")
                    }

                    Spacer()

                    if isPreparingRemoval || isRemoving {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button(role: .destructive) {
                        beginUninstall(app)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(isPreparingRemoval || isRemoving)
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(pane.placeholder ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)

                    feedbackLines(pane.feedback, alignment: .center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(22)
    }

    /// Both halves of the last uninstall's outcome, stacked rather than chosen between. They are
    /// not alternatives: a sweep that moved three items out of `~/Library` and was refused on two
    /// out of `/Library` has to report both, or the user goes hunting in `~/Library` for files
    /// that are already in the Trash.
    private func feedbackLines(_ feedback: UninstallerFeedback, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if let status = feedback.status {
                Text(status)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if let failure = feedback.failure {
                Text(failure)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    /// Moves the selection, and drops the previous uninstall's report along with it. The report
    /// names the app it describes, so leaving it on screen under a different app's name, path and
    /// size reads as a claim that *this* app was just trashed.
    private func select(_ app: InstalledApplication) {
        selectedAppID = app.id
        feedback = .empty
    }

    private var filteredApps: [InstalledApplication] {
        UninstallerSelection.filteredApps(apps, query: searchText)
    }

    private var selectedApp: InstalledApplication? {
        UninstallerSelection.selectedApp(in: filteredApps, selectedID: selectedAppID)
    }

    private func reload() async {
        let token = UUID()
        scanToken = token
        isScanning = true
        isSizing = false
        feedback = .empty
        let scannedApps = await Task.detached(priority: .userInitiated) {
            ApplicationScanner.scan()
        }.value
        guard scanToken == token else {
            return
        }

        apps = scannedApps
        selectedAppID = scannedApps.first?.id
        isScanning = false
        await loadSizes(for: scannedApps, token: token)
    }

    private func loadSizes(for scannedApps: [InstalledApplication], token: UUID) async {
        guard !scannedApps.isEmpty else {
            return
        }

        isSizing = true

        for chunk in scannedApps.chunked(into: 6) {
            guard scanToken == token else {
                break
            }

            await withTaskGroup(of: InstalledApplication.self) { group in
                for app in chunk {
                    group.addTask {
                        ApplicationScanner.applyingSize(to: app)
                    }
                }

                for await sizedApp in group {
                    guard scanToken == token else {
                        group.cancelAll()
                        return
                    }

                    if let index = apps.firstIndex(where: { $0.id == sizedApp.id }) {
                        apps[index] = sizedApp
                    }
                }
            }
        }

        if scanToken == token {
            isSizing = false
        }
    }

    /// Gathers everything that would move — the bundle and its leftovers — and hands it to the
    /// review sheet. Nothing is removed on this path: the old single-alert confirmation could
    /// only ever describe the bundle, and a leftover sweep the user has not seen item by item is
    /// exactly the kind of "helpful" deletion this tool must not do.
    private func beginUninstall(_ app: InstalledApplication) {
        if app.isRunning {
            let runningAlert = NSAlert()
            runningAlert.messageText = "\(app.name) is currently running"
            runningAlert.informativeText = "Quit the app before uninstalling so macOS can move the bundle safely."
            runningAlert.alertStyle = .warning
            runningAlert.addButton(withTitle: "Cancel")
            runningAlert.runModal()
            return
        }

        if app.isAppleApplication {
            let appleAlert = NSAlert()
            appleAlert.messageText = "Move an Apple app to Trash?"
            appleAlert.informativeText = "\(app.name) appears to be an Apple/system utility. Removing it may fail or affect macOS features."
            appleAlert.alertStyle = .critical
            appleAlert.addButton(withTitle: "Continue")
            appleAlert.addButton(withTitle: "Cancel")

            guard appleAlert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        feedback = .empty
        isPreparingRemoval = true

        // The names of the *other* installed apps are what lets the display-name fallback refuse
        // an ambiguous guess, so they have to be sampled here where the app list lives.
        let otherAppNames = apps.filter { $0.id != app.id }.map(\.name)
        let bundleIdentifier = app.bundleIdentifier
        let appName = app.name

        Task {
            let items = await Task.detached(priority: .userInitiated) {
                LeftoverScanner.scan(
                    bundleIdentifier: bundleIdentifier,
                    appName: appName,
                    otherAppNames: otherAppNames
                )
            }.value

            isPreparingRemoval = false
            selectedLeftoverIDs = UninstallerLeftovers.defaultSelection(for: items)
            review = LeftoverReview(app: app, items: items)
        }
    }

    /// Trashes the bundle first, then whatever the user left ticked. The bundle goes first on
    /// purpose: if macOS refuses it (a locked bundle, a missing admin right) the support files
    /// are still where the app expects them, so the user is left with a working install rather
    /// than a half-gutted one.
    private func performUninstall(_ pendingReview: LeftoverReview) {
        let app = pendingReview.app
        let chosen = pendingReview.items.filter { selectedLeftoverIDs.contains($0.id) }

        review = nil

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: app.url, resultingItemURL: &resultingURL)
        } catch {
            feedback = .bundleRefused(reason: error.localizedDescription)
            return
        }

        apps.removeAll { $0.id == app.id }
        selectedAppID = filteredApps.first?.id
        feedback = .empty

        guard !chosen.isEmpty else {
            feedback = .bundleTrashed(appName: app.name)
            return
        }

        isRemoving = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LeftoverScanner.moveToTrash(chosen)
            }.value

            isRemoving = false
            feedback = .sweepFinished(appName: app.name, result: result)
        }
    }
}

/// The bundle and its leftovers, frozen at the moment the user asked to uninstall so the sheet
/// cannot be re-scanned out from under the checkboxes the user just ticked.
private struct LeftoverReview: Identifiable {
    let id = UUID()
    let app: InstalledApplication
    let items: [LeftoverItem]
}

/// The "here is exactly what will move" sheet. Every leftover is listed with its real path and
/// size, and rows matched only by display name start unticked because that match is a heuristic.
private struct LeftoverReviewSheet: View {
    var app: InstalledApplication
    var items: [LeftoverItem]
    @Binding var selection: Set<String>
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(app.name) to Trash?")
                .font(.system(size: 17, weight: .bold))

            HStack(spacing: 12) {
                AppIcon(url: app.url, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.path)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text("The app bundle itself. Always removed.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                Text(app.size?.bytesString ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Divider()

            if items.isEmpty {
                Text("No support files were found for this app.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text("Support files (\(items.count))")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Button(allSelected ? "Deselect All" : "Select All") {
                        selection = allSelected ? [] : Set(items.map(\.id))
                    }
                    .buttonStyle(.link)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                }
                .frame(height: 220)
            }

            Divider()

            HStack {
                Text(totalLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Move to Trash", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(for item: LeftoverItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: binding(for: item))
                .labelsHidden()
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.candidate.label)
                        .font(.system(size: 12, weight: .semibold))

                    if item.candidate.match == .appName {
                        Text("matched by name")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.22))
                            .clipShape(Capsule())
                    }

                    if item.candidate.scope == .system {
                        Text("system-wide")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }

                Text(item.candidate.displayPath)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Text(item.bytes.bytesString)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func binding(for item: LeftoverItem) -> Binding<Bool> {
        Binding(
            get: { selection.contains(item.id) },
            set: { isOn in
                if isOn {
                    selection.insert(item.id)
                } else {
                    selection.remove(item.id)
                }
            }
        )
    }

    private var allSelected: Bool {
        !items.isEmpty && selection.count == items.count
    }

    private var totalLabel: String {
        let total = (app.size ?? 0) + UninstallerLeftovers.selectedBytes(in: items, selection: selection)
        return "\(total.bytesString) will move to Trash"
    }
}

private struct AppRow: View {
    var app: InstalledApplication
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIcon(url: app.url, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    Text(app.sizeLabel)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private extension InstalledApplication {
    var sizeLabel: String {
        size?.bytesString ?? "Calculating"
    }

    var isRunning: Bool {
        if let bundleIdentifier,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            return true
        }

        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == url.standardizedFileURL.path
        }
    }

    var isAppleApplication: Bool {
        bundleIdentifier?.hasPrefix("com.apple.") == true
            || path.hasPrefix("/System/")
            || path.hasPrefix("/Applications/Utilities/")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }

        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

private struct AppIcon: View {
    var url: URL
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
            .cornerRadius(size * 0.18)
    }
}
