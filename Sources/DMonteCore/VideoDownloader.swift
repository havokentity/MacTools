import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

public enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case maximum
    case high
    case normal
    case low

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: "Max (maximum available)"
        case .high: "High (up to 1080p)"
        case .normal: "Normal (up to 720p)"
        case .low: "Low (up to 360p)"
        }
    }

    var ytDlpFormat: String {
        switch self {
        case .maximum:
            "best[ext=mp4]/best"
        case .high:
            "best[ext=mp4][height<=1080]/best[height<=1080]/best"
        case .normal:
            "best[ext=mp4][height<=720]/best[height<=720]/best"
        case .low:
            "best[ext=mp4][height<=360]/best[height<=360]/best"
        }
    }
}

public enum VideoNonMP4Handling: String, CaseIterable, Identifiable, Sendable {
    case downloadMP4LowerQuality
    case downloadWithoutConversion
    case convertToMP4

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .downloadMP4LowerQuality: "Download MP4 in lower quality"
        case .downloadWithoutConversion: "Download without conversion"
        case .convertToMP4: "Convert to MP4"
        }
    }
}

public enum VideoCookieSource: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case disabled
    case safari
    case chrome
    case brave
    case edge
    case firefox

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic (when a sign-in is required)"
        case .disabled: "Don't use cookies"
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .firefox: "Firefox"
        }
    }

    /// The yt-dlp `--cookies-from-browser` identifier for a pinned browser, or
    /// `nil` for the automatic and disabled modes.
    var ytDlpBrowser: String? {
        switch self {
        case .automatic, .disabled: nil
        case .safari: "safari"
        case .chrome: "chrome"
        case .brave: "brave"
        case .edge: "edge"
        case .firefox: "firefox"
        }
    }
}

fileprivate struct VideoDownloaderPreferences: Sendable {
    var quality: VideoQuality
    var nonMP4Handling: VideoNonMP4Handling
    var downloadsSubtitles: Bool
    var saveDirectoryPath: String
    var cookieSource: VideoCookieSource

    @MainActor
    static var current: VideoDownloaderPreferences {
        let defaults = AppDefaults.shared
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        return VideoDownloaderPreferences(
            quality: VideoQuality(rawValue: defaults.string(forKey: DefaultsKey.videoDownloaderPreferredQuality) ?? "")
                ?? .maximum,
            nonMP4Handling: VideoNonMP4Handling(rawValue: defaults.string(forKey: DefaultsKey.videoDownloaderNonMP4Handling) ?? "")
                ?? .downloadWithoutConversion,
            downloadsSubtitles: defaults.bool(forKey: DefaultsKey.videoDownloaderDownloadsSubtitles),
            saveDirectoryPath: defaults.string(forKey: DefaultsKey.videoDownloaderSaveDirectory) ?? downloadsURL.path,
            cookieSource: VideoCookieSource(rawValue: defaults.string(forKey: DefaultsKey.videoDownloaderCookieSource) ?? "")
                ?? .automatic
        )
    }
}

@MainActor
final class VideoDownloaderModel: ObservableObject {
    enum DownloadState: Equatable {
        case queued
        case retrying
        case downloading
        case complete
        case failed
    }

    struct DownloadItem: Identifiable, Equatable {
        let id: UUID
        let url: String
        var title: String
        var status: String
        var detail: String
        var progressFraction: Double?
        var progressDetail: String
        var copyText: String
        var state: DownloadState
        var retryCount: Int
    }

    @Published var urlText = ""
    @Published var isDropTargeted = false
    @Published var downloads: [DownloadItem] = []

    private static let maximumConcurrentDownloads = 3
    private static let maximumRetryCount = 3
    private static let retryDelayRange: ClosedRange<Double> = 3...5
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    deinit {
        downloadTasks.values.forEach { $0.cancel() }
        retryTasks.values.forEach { $0.cancel() }
    }

    var canDownload: Bool {
        !trimmedURL.isEmpty
    }

    var isDownloading: Bool {
        downloads.contains { $0.state == .downloading }
    }

    var queueSummary: String {
        guard !downloads.isEmpty else {
            return "Drop or paste a link to start downloading"
        }

        let active = downloads.filter { $0.state == .downloading }.count
        let queued = downloads.filter { $0.state == .queued || $0.state == .retrying }.count
        let failed = downloads.filter { $0.state == .failed }.count

        if active > 0 || queued > 0 {
            let activeText = active == 1 ? "1 downloading" : "\(active) downloading"
            let queuedText = queued > 0 ? " · \(queued) queued" : ""
            return "\(activeText)\(queuedText)"
        }

        if failed > 0 {
            return failed == 1 ? "1 download failed" : "\(failed) downloads failed"
        }

        return "Downloads complete"
    }

    var visibleDownloads: [DownloadItem] {
        let activeOrQueued = downloads.filter {
            $0.state == .downloading || $0.state == .queued || $0.state == .retrying
        }
        let completed = downloads.filter { $0.state == .complete || $0.state == .failed }.suffix(3)
        return Array((activeOrQueued + completed).suffix(5))
    }

    var latestCopyMessage: String {
        downloads.last?.copyText ?? ""
    }

    func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.isEmpty else {
            return
        }

        urlText = pasted
        startDownload()
    }

    func acceptDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                    let text = if let data = item as? Data {
                        String(data: data, encoding: .utf8)
                    } else if let url = item as? URL {
                        url.absoluteString
                    } else {
                        item as? String
                    }

                    let droppedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in
                        guard let droppedText else {
                            return
                        }

                        self?.urlText = droppedText
                        self?.startDownload()
                    }
                }
                return true
            }

            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                    let droppedText = (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in
                        guard let droppedText else {
                            return
                        }

                        self?.urlText = droppedText
                        self?.startDownload()
                    }
                }
                return true
            }
        }

        return false
    }

    func startDownload() {
        let url = trimmedURL
        guard !url.isEmpty else {
            return
        }

        let normalizedURL = Self.normalizedURLString(url)
        guard !downloads.contains(where: { Self.normalizedURLString($0.url) == normalizedURL }) else {
            urlText = ""
            return
        }

        let preferences = VideoDownloaderPreferences.current
        let item = DownloadItem(
            id: UUID(),
            url: url,
            title: Self.displayTitle(for: url),
            status: "Queued",
            detail: preferences.quality.title,
            progressFraction: nil,
            progressDetail: "Waiting",
            copyText: url,
            state: .queued,
            retryCount: 0
        )

        downloads.append(item)
        trimCompletedDownloads()
        urlText = ""
        launchAvailableDownloads()
    }

    /// Re-queues a failed download from scratch. Triggered by tapping a failed row.
    func retryDownload(id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].state == .failed else {
            return
        }

        retryTasks[id]?.cancel()
        retryTasks[id] = nil

        downloads[index].retryCount = 0
        downloads[index].state = .queued
        downloads[index].status = "Queued"
        downloads[index].detail = VideoDownloaderPreferences.current.quality.title
        downloads[index].progressFraction = nil
        downloads[index].progressDetail = "Waiting"
        downloads[index].copyText = downloads[index].url
        launchAvailableDownloads()
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func launchAvailableDownloads() {
        let activeCount = downloads.filter { $0.state == .downloading }.count
        let availableSlots = max(Self.maximumConcurrentDownloads - activeCount, 0)

        guard availableSlots > 0 else {
            return
        }

        let queuedIDs = downloads
            .filter { $0.state == .queued }
            .prefix(availableSlots)
            .map(\.id)

        for id in queuedIDs {
            launchDownload(id: id)
        }
    }

    private func launchDownload(id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        downloads[index].state = .downloading
        downloads[index].status = downloads[index].retryCount > 0
            ? "Retry \(downloads[index].retryCount)/\(Self.maximumRetryCount)"
            : "Downloading"
        downloads[index].progressFraction = nil
        downloads[index].progressDetail = "Starting"

        let url = downloads[index].url
        let preferences = VideoDownloaderPreferences.current
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        downloadTasks[id]?.cancel()
        downloadTasks[id] = Task { [weak self] in
            guard let self else {
                return
            }

            let result = await VideoDownloaderRunner.download(url: url, preferences: preferences) { progress in
                Task { @MainActor in
                    self.updateProgress(id: id, progress: progress)
                }
            }

            guard !Task.isCancelled else {
                return
            }

            finishDownload(id: id, result: result)
        }
    }

    private func updateProgress(id: UUID, progress: VideoDownloaderRunner.Progress) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        downloads[index].progressFraction = progress.fraction
        downloads[index].progressDetail = progress.detail
    }

    private func finishDownload(id: UUID, result: VideoDownloaderRunner.Result) {
        downloadTasks[id] = nil

        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            launchAvailableDownloads()
            return
        }

        if !result.succeeded && downloads[index].retryCount < Self.maximumRetryCount {
            scheduleRetry(id: id, result: result)
            launchAvailableDownloads()
            return
        }

        downloads[index].state = result.succeeded ? .complete : .failed
        downloads[index].status = result.title
        downloads[index].detail = result.detail
        downloads[index].progressFraction = result.succeeded ? 1 : nil
        downloads[index].progressDetail = result.succeeded ? "Done" : ""
        downloads[index].copyText = result.copyText

        if result.succeeded {
            VideoDownloaderNotifications.notifyDownloadComplete(detail: result.detail)
        }

        trimCompletedDownloads()
        launchAvailableDownloads()
    }

    private func scheduleRetry(id: UUID, result: VideoDownloaderRunner.Result) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        let retryCount = downloads[index].retryCount + 1
        let delay = Double.random(in: Self.retryDelayRange)
        downloads[index].retryCount = retryCount
        downloads[index].state = .retrying
        downloads[index].status = "Retry \(retryCount)/\(Self.maximumRetryCount)"
        downloads[index].detail = result.detail
        downloads[index].progressFraction = nil
        downloads[index].progressDetail = "Retrying in \(Int(delay.rounded()))s"
        downloads[index].copyText = result.copyText

        retryTasks[id]?.cancel()
        retryTasks[id] = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.queueRetry(id: id)
        }
    }

    private func queueRetry(id: UUID) {
        retryTasks[id] = nil

        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].state == .retrying else {
            launchAvailableDownloads()
            return
        }

        downloads[index].state = .queued
        downloads[index].status = "Queued"
        downloads[index].progressFraction = nil
        downloads[index].progressDetail = "Waiting"
        launchAvailableDownloads()
    }

    private func trimCompletedDownloads() {
        let activeIDs = Set(downloads.filter {
            $0.state == .queued || $0.state == .retrying || $0.state == .downloading
        }.map(\.id))
        var completedSeen = 0
        downloads = downloads.reversed().filter { item in
            if activeIDs.contains(item.id) {
                return true
            }

            completedSeen += 1
            return completedSeen <= 5
        }.reversed()
    }

    private static func displayTitle(for urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host(percentEncoded: false) else {
            return "Video"
        }

        return host.replacingOccurrences(of: "www.", with: "")
    }

    private static func normalizedURLString(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if let queryItems = components.queryItems {
            let trackingPrefixes = ["utm_"]
            let trackingNames: Set<String> = [
                "fbclid",
                "gclid",
                "igshid",
                "mc_cid",
                "mc_eid"
            ]
            let filteredItems = queryItems.filter { item in
                let name = item.name.lowercased()
                return !trackingNames.contains(name)
                    && !trackingPrefixes.contains(where: { name.hasPrefix($0) })
            }
            components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        }

        var normalized = components.string ?? trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized.lowercased()
    }
}

enum VideoDownloaderRunner {
    struct Result: Sendable {
        var title: String
        var detail: String
        var copyText: String
        var succeeded: Bool
    }

    struct Progress: Sendable {
        var fraction: Double?
        var detail: String
    }

    private struct Attempt {
        var status: Int32?
        var output: String
        var errorMessage: String?
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private let maximumCharacterCount = 32_768

        func append(_ data: Data) {
            guard !data.isEmpty,
                  let string = String(data: data, encoding: .utf8),
                  !string.isEmpty else {
                return
            }

            lock.lock()
            text += string
            if text.count > maximumCharacterCount {
                text = String(text.suffix(maximumCharacterCount))
            }
            lock.unlock()
        }

        var value: String {
            lock.lock()
            defer {
                lock.unlock()
            }

            return text
        }
    }

    fileprivate static func download(
        url: String,
        preferences: VideoDownloaderPreferences,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            guard let command = findYTDLPCommand() else {
                return Result(
                    title: "yt-dlp is required",
                    detail: "Install with Homebrew: brew install yt-dlp",
                    copyText: "yt-dlp is required. Install with Homebrew: brew install yt-dlp",
                    succeeded: false
                )
            }

            let saveURL = URL(fileURLWithPath: preferences.saveDirectoryPath, isDirectory: true)
            let outputTemplate = saveURL.appendingPathComponent("%(title).200B.%(ext)s").path
            var baseArguments = command.arguments + [
                "--newline",
                "--no-playlist",
                "--no-keep-video",
                "-f",
                preferences.quality.ytDlpFormat,
                "-o",
                outputTemplate
            ]

            if preferences.downloadsSubtitles {
                baseArguments += ["--write-subs", "--write-auto-subs", "--sub-langs", "all"]
            }

            switch preferences.nonMP4Handling {
            case .downloadMP4LowerQuality:
                baseArguments += ["--merge-output-format", "mp4"]
            case .downloadWithoutConversion:
                break
            case .convertToMP4:
                baseArguments += ["--recode-video", "mp4"]
            }

            func runAttempt(cookieBrowser: String?) async -> Attempt {
                var arguments = baseArguments
                if let cookieBrowser {
                    arguments += ["--cookies-from-browser", cookieBrowser]
                }
                arguments.append(url)

                let process = Process()
                process.executableURL = command.executableURL
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                let output = OutputBuffer()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    output.append(data)
                    if let progress = parseProgress(from: data) {
                        onProgress(progress)
                    }
                }
                defer {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    try? pipe.fileHandleForReading.close()
                }

                do {
                    let terminationStatus = try await runAndWait(process)
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
                    output.append(remainingData)
                    return Attempt(status: terminationStatus, output: output.value, errorMessage: nil)
                } catch {
                    return Attempt(status: nil, output: output.value, errorMessage: error.localizedDescription)
                }
            }

            func successResult() -> Result {
                let message = "Download complete. Saved to \(saveURL.path)"
                return Result(
                    title: "Download complete",
                    detail: "Saved to \(saveURL.lastPathComponent)",
                    copyText: message,
                    succeeded: true
                )
            }

            func failureResult(from attempt: Attempt, loginGated: Bool) -> Result {
                if let errorMessage = attempt.errorMessage, attempt.output.isEmpty {
                    return Result(
                        title: "Download failed",
                        detail: errorMessage,
                        copyText: errorMessage,
                        succeeded: false
                    )
                }

                if loginGated {
                    let hint = "This needs a sign-in. Open the link in a browser where you're logged in, then click to retry."
                    return Result(
                        title: "Sign-in required",
                        detail: hint,
                        copyText: attempt.output.isEmpty ? hint : "\(attempt.output)\n\n\(hint)",
                        succeeded: false
                    )
                }

                return Result(
                    title: "Download failed",
                    detail: lastUsefulLine(from: attempt.output),
                    copyText: attempt.output.isEmpty ? "Download failed. Check the link and try again." : attempt.output,
                    succeeded: false
                )
            }

            // Cookies disabled: a single plain attempt.
            if preferences.cookieSource == .disabled {
                let attempt = await runAttempt(cookieBrowser: nil)
                return attempt.status == 0 ? successResult() : failureResult(from: attempt, loginGated: false)
            }

            // A pinned browser: always send its cookies.
            if let pinnedBrowser = preferences.cookieSource.ytDlpBrowser {
                let attempt = await runAttempt(cookieBrowser: pinnedBrowser)
                return attempt.status == 0
                    ? successResult()
                    : failureResult(from: attempt, loginGated: isAuthError(attempt.output))
            }

            // Automatic: try without cookies first so public videos never touch the
            // browser keychain, then escalate to each signed-in browser on a sign-in error.
            let firstAttempt = await runAttempt(cookieBrowser: nil)
            if firstAttempt.status == 0 {
                return successResult()
            }

            guard !Task.isCancelled, isAuthError(firstAttempt.output) else {
                return failureResult(from: firstAttempt, loginGated: false)
            }

            for browser in installedCookieBrowsers() {
                if Task.isCancelled {
                    return failureResult(from: firstAttempt, loginGated: true)
                }

                let attempt = await runAttempt(cookieBrowser: browser)
                if attempt.status == 0 {
                    return successResult()
                }
            }

            return failureResult(from: firstAttempt, loginGated: true)
        }.value
    }

    private static func runAndWait(_ process: Process) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func findYTDLPCommand() -> (executableURL: URL, arguments: [String])? {
        if let bundledURL = bundledYTDLPURL(),
           FileManager.default.isExecutableFile(atPath: bundledURL.path) {
            return (bundledURL, [])
        }

        let directPaths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]

        for path in directPaths where FileManager.default.isExecutableFile(atPath: path) {
            return (URL(fileURLWithPath: path), [])
        }

        let pythonPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for path in pythonPaths where FileManager.default.isExecutableFile(atPath: path) {
            if pythonModuleExists(executablePath: path) {
                return (URL(fileURLWithPath: path), ["-m", "yt_dlp"])
            }
        }

        return nil
    }

    private static func bundledYTDLPURL() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin")
            .appendingPathComponent("yt-dlp")
    }

    private static func parseProgress(from data: Data) -> Progress? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }

        if text.localizedCaseInsensitiveContains("[download] destination:") {
            return Progress(fraction: nil, detail: "Preparing file")
        }

        if text.localizedCaseInsensitiveContains("[download] 100%") {
            return Progress(fraction: 1, detail: "Finishing")
        }

        if text.localizedCaseInsensitiveContains("[Merger]") {
            return Progress(fraction: nil, detail: "Merging")
        }

        let lines = text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("[download]") }

        for line in lines.reversed() {
            guard let percent = downloadPercent(in: line) else {
                continue
            }

            let speed = capture(in: line, pattern: #" at\s+(.+?)(?:\s+ETA|$)"#)
            let eta = capture(in: line, pattern: #" ETA\s+([^\s]+)"#)
            let parts = [speed.map { "at \($0)" }, eta.map { "ETA \($0)" }].compactMap(\.self)
            return Progress(fraction: percent / 100, detail: parts.isEmpty ? "\(Int(percent))%" : parts.joined(separator: "  "))
        }

        return nil
    }

    private static func downloadPercent(in line: String) -> Double? {
        guard let match = line.range(of: #"([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression) else {
            return nil
        }

        let value = line[match].dropLast()
        return Double(value)
    }

    private static func capture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[range])
    }

    private static func pythonModuleExists(executablePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-m", "yt_dlp", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func lastUsefulLine(from output: String) -> String {
        output
            .split(separator: "\n")
            .reversed()
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Check the link and try again."
    }

    /// Heuristic for failures that a signed-in browser session is likely to fix
    /// (login walls, private/restricted content, rate limits).
    private static func isAuthError(_ output: String) -> Bool {
        let lowered = output.lowercased()
        let needles = [
            "login required",
            "log in",
            "logged in",
            "sign in",
            "available to everyone",
            "requested content is not available",
            "this content isn",
            "only available to",
            "is private",
            "private video",
            "private account",
            "rate-limit",
            "rate limit",
            "http error 429",
            "http error 403",
            "use --cookies",
            "cookies-from-browser",
            "authenticat",
            "age-restricted",
            "age restricted",
            "confirm your age",
            "you must be 18"
        ]
        return needles.contains { lowered.contains($0) }
    }

    /// yt-dlp browser identifiers for browsers whose profile data exists on this
    /// Mac, in the order they should be tried for cookies. Safari is last because
    /// its cookies live in a protected container that needs Full Disk Access.
    private static func installedCookieBrowsers() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)

        let candidates: [(browser: String, relativePath: String)] = [
            ("chrome", "Google/Chrome"),
            ("brave", "BraveSoftware/Brave-Browser"),
            ("edge", "Microsoft Edge"),
            ("vivaldi", "Vivaldi"),
            ("chromium", "Chromium"),
            ("firefox", "Firefox")
        ]

        var browsers = candidates
            .filter { fileManager.fileExists(atPath: appSupport.appendingPathComponent($0.relativePath).path) }
            .map(\.browser)

        let safariCookies = home.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
        )
        if fileManager.fileExists(atPath: safariCookies.path) {
            browsers.append("safari")
        }

        return browsers
    }
}

public struct VideoDownloaderWindowView: View {
    var onQuit: () -> Void

    @StateObject private var model = VideoDownloaderModel()
    @State private var isShowingSettings = false
    @AppStorage(DefaultsKey.videoDownloaderPreferredQuality, store: AppDefaults.shared) private var preferredQualityRaw = VideoQuality.maximum.rawValue

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        let layout = VideoDownloaderLayout.current

        ZStack {
            VStack(spacing: 0) {
                header(layout: layout)

                Picker("", selection: preferredQualityBinding) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(layout.controlSize)
                .frame(width: layout.qualityPickerWidth)

                dropZone(layout: layout)
                    .padding(.horizontal, layout.contentHorizontalPadding)
                    .padding(.top, layout.dropZoneTopPadding)

                VStack(spacing: layout.controlSpacing) {
                    TextField("Paste video URL", text: $model.urlText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(layout.controlSize)
                        .onSubmit {
                            model.startDownload()
                        }

                    HStack(spacing: layout.buttonSpacing) {
                        Button("Paste Link") {
                            model.pasteFromClipboard()
                        }
                        .controlSize(layout.controlSize)

                        Button(model.isDownloading ? "Add" : "Download") {
                            model.startDownload()
                        }
                        .controlSize(layout.controlSize)
                        .disabled(!model.canDownload)
                    }
                }
                .padding(.horizontal, layout.contentHorizontalPadding)
                .padding(.top, layout.controlsTopPadding)

                Text(model.queueSummary)
                    .font(.system(size: layout.statusFontSize, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(height: layout.statusTextHeight, alignment: .bottom)
                    .padding(.horizontal, layout.contentHorizontalPadding)
                    .padding(.top, layout.statusTopPadding)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copyDownloadMessage()
                    }
                    .help("Copy download message")

                if !model.downloads.isEmpty {
                    downloadQueue(layout: layout)
                        .padding(.horizontal, layout.contentHorizontalPadding)
                        .padding(.top, layout.queueTopPadding)
                }

                Spacer(minLength: layout.bottomSpacing)
            }
            .opacity(isShowingSettings ? 0 : 1)
            .rotation3DEffect(
                .degrees(isShowingSettings ? -90 : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.72
            )
            .allowsHitTesting(!isShowingSettings)

            VideoDownloaderSettingsView(
                onDone: { isShowingSettings = false }
            )
            .opacity(isShowingSettings ? 1 : 0)
            .rotation3DEffect(
                .degrees(isShowingSettings ? 0 : 90),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.72
            )
            .allowsHitTesting(isShowingSettings)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: layout.cornerRadius)
        .animation(.easeInOut(duration: 0.24), value: isShowingSettings)
    }

    private var preferredQualityBinding: Binding<VideoQuality> {
        Binding {
            VideoQuality(rawValue: preferredQualityRaw) ?? .maximum
        } set: { quality in
            preferredQualityRaw = quality.rawValue
        }
    }

    private func copyDownloadMessage() {
        let message = model.latestCopyMessage.isEmpty ? model.queueSummary : model.latestCopyMessage

        guard !message.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    private func header(layout: VideoDownloaderLayout) -> some View {
        HStack {
            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Quit Download Video")

            Spacer()

            Text("Download Video")
                .font(.system(size: layout.titleFontSize, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.82))

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: layout.settingsIconSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    private func downloadQueue(layout: VideoDownloaderLayout) -> some View {
        ScrollView {
            LazyVStack(spacing: layout.queueRowSpacing) {
                ForEach(model.visibleDownloads) { item in
                    DownloadQueueRow(item: item, layout: layout) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.copyText, forType: .string)
                    } onRetry: {
                        model.retryDownload(id: item.id)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: layout.queueHeight)
    }

    private func dropZone(layout: VideoDownloaderLayout) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: layout.dropZoneCornerRadius, style: .continuous)
                .stroke(
                    Color.secondary.opacity(model.isDropTargeted ? 0.95 : 0.7),
                    style: StrokeStyle(lineWidth: layout.dropZoneLineWidth, lineCap: .round, dash: layout.dropZoneDash)
                )
                .background(
                    RoundedRectangle(cornerRadius: layout.dropZoneCornerRadius, style: .continuous)
                        .fill(model.isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                )

            if model.isDownloading {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(layout.progressScale)
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: layout.arrowFontSize, weight: .ultraLight))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: layout.dropZoneHeight)
        .contentShape(RoundedRectangle(cornerRadius: layout.dropZoneCornerRadius, style: .continuous))
        .onTapGesture {
            model.pasteFromClipboard()
        }
        .onDrop(
            of: [UTType.url.identifier, UTType.plainText.identifier],
            isTargeted: $model.isDropTargeted,
            perform: model.acceptDroppedProviders
        )
    }
}

private struct DownloadQueueRow: View {
    var item: VideoDownloaderModel.DownloadItem
    var layout: VideoDownloaderLayout
    var onCopy: () -> Void
    var onRetry: () -> Void

    private var isFailed: Bool {
        item.state == .failed
    }

    var body: some View {
        Button(action: isFailed ? onRetry : onCopy) {
            HStack(spacing: layout.queueRowHorizontalSpacing) {
                Image(systemName: iconName)
                    .font(.system(size: layout.queueIconSize, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: layout.queueIconFrame, height: layout.queueIconFrame)

                VStack(alignment: .leading, spacing: layout.queueTextSpacing) {
                    HStack(spacing: 6 * layout.scale) {
                        Text(item.title)
                            .font(.system(size: layout.queueTitleFontSize, weight: .semibold))
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(item.status)
                            .font(.system(size: layout.queueMetaFontSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: layout.queueRowHorizontalSpacing) {
                        if isFailed {
                            retryPill
                        } else if let fraction = item.progressFraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                        } else if item.state == .downloading || item.state == .queued {
                            ProgressView()
                                .progressViewStyle(.linear)
                        } else {
                            Capsule()
                                .fill(Color.secondary.opacity(0.16))
                                .frame(height: 4 * layout.scale)
                        }

                        Text(item.progressDetail)
                            .font(.system(size: layout.queueMetaFontSize, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: layout.queueProgressLabelWidth, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, layout.queueRowHorizontalPadding)
            .padding(.vertical, layout.queueRowVerticalPadding)
            .frame(height: layout.queueRowHeight)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: layout.queueRowCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: layout.queueRowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isFailed ? "Click to retry this download" : "Copy download message")
        .contextMenu {
            Button("Copy Details") { onCopy() }
            if isFailed {
                Button("Retry") { onRetry() }
            }
        }
    }

    private var retryPill: some View {
        HStack(spacing: 4 * layout.scale) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: layout.queueMetaFontSize, weight: .bold))
            Text("Retry")
                .font(.system(size: layout.queueMetaFontSize, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        switch item.state {
        case .queued, .retrying:
            "clock"
        case .downloading:
            "arrow.down.circle.fill"
        case .complete:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .queued, .retrying:
            .secondary
        case .downloading:
            .accentColor
        case .complete:
            .green
        case .failed:
            .red
        }
    }
}

public enum VideoDownloaderNotifications {
    public static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func notifyDownloadComplete(detail: String) {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = detail.isEmpty ? "Video saved." : detail
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dmonte-video-download-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private struct VideoDownloaderLayout {
    let scale: CGFloat

    static var current: VideoDownloaderLayout {
        VideoDownloaderLayout(scale: VideoDownloaderSizing.currentScale)
    }

    var windowSize: NSSize { VideoDownloaderSizing.preferredSize() }
    var cornerRadius: CGFloat { 18 * scale }
    var headerButtonSize: CGFloat { 32 * scale }
    var closeIconSize: CGFloat { 18 * scale }
    var settingsIconSize: CGFloat { 20 * scale }
    var titleFontSize: CGFloat { 27 * scale }
    var headerHorizontalPadding: CGFloat { 24 * scale }
    var headerTopPadding: CGFloat { 18 * scale }
    var headerBottomPadding: CGFloat { 10 * scale }
    var qualityPickerWidth: CGFloat { 220 * scale }
    var contentHorizontalPadding: CGFloat { 42 * scale }
    var dropZoneTopPadding: CGFloat { 12 * scale }
    var dropZoneHeight: CGFloat { 215 * scale }
    var dropZoneCornerRadius: CGFloat { 38 * scale }
    var dropZoneLineWidth: CGFloat { 3 * scale }
    var dropZoneDash: [CGFloat] { [18 * scale, 16 * scale] }
    var arrowFontSize: CGFloat { 76 * scale }
    var progressScale: CGFloat { 1.25 * scale }
    var controlsTopPadding: CGFloat { 12 * scale }
    var controlSpacing: CGFloat { 8 * scale }
    var buttonSpacing: CGFloat { 10 * scale }
    var statusTopPadding: CGFloat { 8 * scale }
    var statusFontSize: CGFloat { 14 * scale }
    var statusTextHeight: CGFloat { 22 * scale }
    var queueTopPadding: CGFloat { 6 * scale }
    var queueHeight: CGFloat { 92 * scale }
    var queueRowHeight: CGFloat { 42 * scale }
    var queueRowSpacing: CGFloat { 6 * scale }
    var queueRowHorizontalSpacing: CGFloat { 8 * scale }
    var queueRowHorizontalPadding: CGFloat { 10 * scale }
    var queueRowVerticalPadding: CGFloat { 6 * scale }
    var queueRowCornerRadius: CGFloat { 8 * scale }
    var queueTitleFontSize: CGFloat { 11 * scale }
    var queueMetaFontSize: CGFloat { 9 * scale }
    var queueIconSize: CGFloat { 13 * scale }
    var queueIconFrame: CGFloat { 18 * scale }
    var queueTextSpacing: CGFloat { 4 * scale }
    var queueProgressLabelWidth: CGFloat { 70 * scale }
    var bottomSpacing: CGFloat { 10 * scale }
    var controlSize: ControlSize { scale < 0.94 ? .small : .regular }
}

private struct VideoDownloaderSettingsView: View {
    var onDone: () -> Void

    @AppStorage(DefaultsKey.videoDownloaderPreferredQuality, store: AppDefaults.shared) private var preferredQualityRaw = VideoQuality.maximum.rawValue
    @AppStorage(DefaultsKey.videoDownloaderNonMP4Handling, store: AppDefaults.shared) private var nonMP4HandlingRaw = VideoNonMP4Handling.downloadWithoutConversion.rawValue
    @AppStorage(DefaultsKey.videoDownloaderDownloadsSubtitles, store: AppDefaults.shared) private var downloadsSubtitles = true
    @AppStorage(DefaultsKey.videoDownloaderCookieSource, store: AppDefaults.shared) private var cookieSourceRaw = VideoCookieSource.automatic.rawValue
    @AppStorage(DefaultsKey.videoDownloaderSaveDirectory, store: AppDefaults.shared) private var saveDirectoryPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path

    var body: some View {
        let layout = VideoDownloaderSettingsLayout.current

        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            settingsPicker(
                title: "Preferred quality:",
                selection: $preferredQualityRaw,
                options: VideoQuality.allCases.map { ($0.rawValue, $0.title) },
                layout: layout
            )

            settingsPicker(
                title: "For non-MP4 videos:",
                selection: $nonMP4HandlingRaw,
                options: VideoNonMP4Handling.allCases.map { ($0.rawValue, $0.title) },
                layout: layout
            )

            VStack(alignment: .leading, spacing: layout.captionSpacing) {
                Toggle("Download subtitles", isOn: $downloadsSubtitles)
                    .toggleStyle(.checkbox)
                    .controlSize(layout.controlSize)
                    .font(.system(size: layout.bodyFontSize, weight: .semibold))

                Text("All available subtitles will be downloaded together with the video")
                    .font(.system(size: layout.captionFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: layout.controlSpacing) {
                Text("Save to:")
                    .font(.system(size: layout.labelFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.76))

                Button {
                    chooseSaveDirectory()
                } label: {
                    HStack(spacing: layout.folderSpacing) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.cyan)

                        Text(saveDirectoryName)
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: layout.chevronFontSize, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6 * layout.scale)
                            .frame(height: layout.pickerHeight)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 7 * layout.scale, style: .continuous))
                    }
                    .font(.system(size: layout.bodyFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.86))
                    .padding(.leading, layout.pickerHorizontalPadding)
                    .frame(height: layout.pickerHeight)
                    .background(Color.white.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: layout.controlCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .controlSize(layout.controlSize)
            }

            VStack(alignment: .leading, spacing: layout.captionSpacing) {
                settingsPicker(
                    title: "Use browser cookies:",
                    selection: $cookieSourceRaw,
                    options: VideoCookieSource.allCases.map { ($0.rawValue, $0.title) },
                    layout: layout
                )

                Text("For sign-in-only videos, e.g. Instagram.")
                    .font(.system(size: layout.captionFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Done") {
                onDone()
            }
            .font(.system(size: layout.doneFontSize, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(layout.doneControlSize)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, layout.topPadding)
        .padding(.bottom, layout.bottomPadding)
        .frame(width: layout.width, height: layout.height)
    }

    private var saveDirectoryName: String {
        URL(fileURLWithPath: saveDirectoryPath, isDirectory: true).lastPathComponent
    }

    private func settingsPicker(
        title: String,
        selection: Binding<String>,
        options: [(String, String)],
        layout: VideoDownloaderSettingsLayout
    ) -> some View {
        VStack(alignment: .leading, spacing: layout.controlSpacing) {
            Text(title)
                .font(.system(size: layout.labelFontSize, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.76))

            Picker("", selection: selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(layout.controlSize)
            .font(.system(size: layout.bodyFontSize, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            saveDirectoryPath = url.path
        }
    }
}

private struct VideoDownloaderSettingsLayout {
    let scale: CGFloat

    static var current: VideoDownloaderSettingsLayout {
        VideoDownloaderSettingsLayout(scale: VideoDownloaderSizing.currentScale)
    }

    var width: CGFloat { VideoDownloaderSizing.preferredSize().width }
    var height: CGFloat { VideoDownloaderSizing.preferredSize().height }
    var horizontalPadding: CGFloat { 42 * scale }
    var topPadding: CGFloat { 40 * scale }
    var bottomPadding: CGFloat { 38 * scale }
    var labelFontSize: CGFloat { 20 * scale }
    var bodyFontSize: CGFloat { 18 * scale }
    var captionFontSize: CGFloat { 15 * scale }
    var doneFontSize: CGFloat { 16 * scale }
    var chevronFontSize: CGFloat { 12 * scale }
    var sectionSpacing: CGFloat { 16 * scale }
    var controlSpacing: CGFloat { 7 * scale }
    var captionSpacing: CGFloat { 9 * scale }
    var folderSpacing: CGFloat { 8 * scale }
    var pickerHeight: CGFloat { 40 * scale }
    var pickerHorizontalPadding: CGFloat { 14 * scale }
    var controlCornerRadius: CGFloat { 8 * scale }
    var controlSize: ControlSize { scale < 0.94 ? .small : .regular }
    var doneControlSize: ControlSize { scale < 0.94 ? .regular : .large }
}
