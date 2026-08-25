import Foundation

/// Where the splitter found `ffmpeg` and `ffprobe`. Both are required: without
/// ffprobe there is no duration to divide, and a split that guesses the length would
/// silently drop the end of the video.
public struct VideoSplitterTools: Sendable, Equatable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Locates both binaries, or nil if either is missing.
    ///
    /// The search order is the reason this tool adds no megabytes to the download:
    /// inside the shipped Tool Box the Video Downloader helper already carries a
    /// signed, notarized static ffmpeg/ffprobe pair (126 MB of it), and both helpers
    /// live in the same container, signed by the same team. A second copy would double
    /// that for no benefit, so the splitter borrows its sibling's. A helper run on its
    /// own (or `swift run` during development) falls through to a Homebrew/system
    /// install, and the UI says plainly when there is none.
    public static func locate(bundle: Bundle = .main) -> VideoSplitterTools? {
        var searchDirectories: [URL] = []

        if let ownBin = bundle.resourceURL?.appendingPathComponent("bin") {
            searchDirectories.append(ownBin)
        }
        searchDirectories.append(siblingVideoDownloaderBinDirectory(helperBundleURL: bundle.bundleURL))
        searchDirectories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map(URL.init(fileURLWithPath:))

        for directory in searchDirectories {
            let ffmpeg = directory.appendingPathComponent("ffmpeg")
            let ffprobe = directory.appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: ffmpeg.path),
               FileManager.default.isExecutableFile(atPath: ffprobe.path) {
                return VideoSplitterTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }

        return nil
    }

    /// The Video Downloader helper's bundled-binaries directory, as seen from another
    /// helper in the same `Contents/Helpers` folder.
    public static func siblingVideoDownloaderBinDirectory(helperBundleURL: URL) -> URL {
        helperBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("DMonte Video Downloader.app")
            .appendingPathComponent("Contents/Resources/bin")
    }
}

/// Runs the split: probes the source, cuts each clip with ffmpeg, and verifies that
/// nothing came out over the cap.
///
/// `nonisolated` and `Sendable`, so the controller drives it from a detached task
/// while the window stays live. One runner handles one video at a time, cutting
/// several of its clips concurrently; `cancel()` kills every ffmpeg it has running and
/// abandons the rest of the plan.
public final class VideoSplitterRunner: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case unreadableDuration
        case outputDirectoryUnwritable
        case ffmpeg(String)
        case oversizedClip
        case cancelled

        public var message: String {
            switch self {
            case .unreadableDuration: "Couldn't read the video's duration"
            case .outputDirectoryUnwritable: "Couldn't create the clips folder"
            case let .ffmpeg(reason): reason
            case .oversizedClip: "A clip came out over the limit — nothing was kept"
            case .cancelled: "Cancelled"
            }
        }
    }

    public struct Summary: Sendable, Equatable {
        public let clipCount: Int
        public let outputDirectory: URL

        public init(clipCount: Int, outputDirectory: URL) {
            self.clipCount = clipCount
            self.outputDirectory = outputDirectory
        }
    }

    private let lock = NSLock()
    private var runningProcesses: [ObjectIdentifier: Process] = [:]
    private var isCancelled = false

    public init() {}

    /// Stops every ffmpeg running now and makes each worker bail out of the rest of the
    /// plan. Safe to call before the runner has started anything.
    public func cancel() {
        lock.lock()
        isCancelled = true
        let processes = Array(runningProcesses.values)
        lock.unlock()
        processes.forEach { $0.terminate() }
    }

    /// Clears the cancelled flag so the runner can be reused for the next video.
    public func reset() {
        lock.lock()
        isCancelled = false
        lock.unlock()
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    /// Kills the ffmpeg processes running right now without marking the runner
    /// cancelled — used when one clip has failed and the rest of *this* video's clips
    /// are about to be thrown away anyway.
    private func terminateRunningProcesses() {
        lock.lock()
        let processes = Array(runningProcesses.values)
        lock.unlock()
        processes.forEach { $0.terminate() }
    }

    // MARK: - Hardware encoding

    /// Whether this ffmpeg can encode H.264 on the media engine.
    ///
    /// Asked of the binary rather than assumed from the chip: the answer depends on how
    /// this particular ffmpeg was built as much as on the Mac it runs on, and the UI
    /// offers the mode only when the encoder is really there.
    public func supportsHardwareEncoding(tools: VideoSplitterTools) -> Bool {
        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .contains(VideoSplitterKit.Encoder.hardware.ffmpegName)
    }

    // MARK: - Probing

    /// Duration in seconds, or 0 when ffprobe can't read it.
    public func duration(of source: URL, tools: VideoSplitterTools) -> TimeInterval {
        probeNumber(source, tools: tools, entries: "format=duration", videoStreamOnly: false) ?? 0
    }

    /// The source's video bitrate, falling back to the container's overall bitrate,
    /// or 0 when neither is stated (common in Matroska).
    public func bitrate(of source: URL, tools: VideoSplitterTools) -> Int {
        if let streamBitrate = probeNumber(source, tools: tools, entries: "stream=bit_rate", videoStreamOnly: true) {
            return Int(streamBitrate)
        }
        guard let containerBitrate = probeNumber(source, tools: tools, entries: "format=bit_rate", videoStreamOnly: false) else {
            return 0
        }
        return Int(containerBitrate)
    }

    private func probeNumber(
        _ source: URL,
        tools: VideoSplitterTools,
        entries: String,
        videoStreamOnly: Bool
    ) -> Double? {
        var arguments = ["-v", "error"]
        if videoStreamOnly {
            arguments += ["-select_streams", "v:0"]
        }
        arguments += [
            "-show_entries", entries,
            "-of", "default=noprint_wrappers=1:nokey=1",
            source.path
        ]

        let process = Process()
        process.executableURL = tools.ffprobe
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: ffprobe's output is tiny, but a pipe that fills while
        // nobody drains it deadlocks the child, and this one is never cancelled.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first
    }

    // MARK: - Splitting

    /// Cuts `source` into clips of at most `maxClipLength` seconds inside
    /// `outputDirectory`, reporting overall progress as a 0...1 fraction.
    ///
    /// Several clips are cut at once — see ``VideoSplitterKit/encodePlan(clipCount:encoder:activeProcessorCount:)``
    /// for how many, and why. Blocking is deliberate: the caller already runs this in a
    /// detached task, and the worker pool needs a thread to join on.
    ///
    /// A clip that comes out over the cap fails the whole run and the clips are
    /// removed: this tool's entire promise is that everything it writes is uploadable,
    /// and a folder that is silently one clip short of usable is worse than an error.
    public func split(
        source: URL,
        maxClipLength: TimeInterval,
        outputDirectory: URL,
        encoder: VideoSplitterKit.Encoder,
        tools: VideoSplitterTools,
        progress: @escaping @Sendable (Double) -> Void
    ) -> Result<Summary, Failure> {
        let sourceDuration = duration(of: source, tools: tools)
        let plan = VideoSplitterKit.plan(duration: sourceDuration, maxClipLength: maxClipLength)
        guard !plan.isEmpty else {
            return .failure(.unreadableDuration)
        }

        do {
            try prepareOutputDirectory(outputDirectory, for: source)
        } catch {
            return .failure(.outputDirectoryUnwritable)
        }

        let encodePlan = VideoSplitterKit.encodePlan(clipCount: plan.count, encoder: encoder)
        let sourceBitrate = bitrate(of: source, tools: tools)

        // Workers pull from one queue rather than taking a fixed slice each, so a long
        // clip on one worker can't leave the others idle at the end of the run.
        let pending = SegmentQueue(plan)
        let tracker = ProgressTracker(clipCount: plan.count, publish: progress)
        let firstFailure = FailureBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "com.havokentity.mactools.videosplitter.encode",
            qos: .userInitiated,
            attributes: .concurrent
        )

        for _ in 0..<encodePlan.workerCount {
            queue.async(group: group) { [self] in
                while let segment = pending.next() {
                    guard !cancelled, !firstFailure.hasFailure else {
                        return
                    }

                    let outputURL = VideoSplitterKit.clipURL(
                        for: source,
                        index: segment.index,
                        in: outputDirectory
                    )
                    let arguments = VideoSplitterKit.clipArguments(
                        source: source,
                        segment: segment,
                        outputURL: outputURL,
                        encoder: encoder,
                        threadCount: encodePlan.threadsPerWorker,
                        sourceBitrate: sourceBitrate
                    )

                    let clipResult = runFFmpeg(
                        tools: tools,
                        arguments: arguments,
                        clipDuration: segment.length
                    ) { clipFraction in
                        tracker.report(clipIndex: segment.index, fraction: clipFraction)
                    }

                    if case let .failure(failure) = clipResult {
                        firstFailure.record(failure)
                        // The clips still encoding are now pointless; stop them rather
                        // than making the user wait for work that is about to be deleted.
                        // Not `cancel()`: this run failed, but the next video in the
                        // queue has not been cancelled and must still be attempted.
                        terminateRunningProcesses()
                        return
                    }
                }
            }
        }
        group.wait()

        if let failure = firstFailure.failure {
            removeClips(of: source, in: outputDirectory)
            return .failure(failure)
        }
        if cancelled {
            removeClips(of: source, in: outputDirectory)
            return .failure(.cancelled)
        }

        let clips = writtenClips(of: source, in: outputDirectory)
        guard !clips.isEmpty else {
            return .failure(.ffmpeg("ffmpeg produced no clips"))
        }

        let cap = maxClipLength + VideoSplitterKit.minimumClipLength
        if clips.contains(where: { duration(of: $0, tools: tools) > cap }) {
            removeClips(of: source, in: outputDirectory)
            return .failure(.oversizedClip)
        }

        progress(1)
        return .success(Summary(clipCount: clips.count, outputDirectory: outputDirectory))
    }

    /// Runs one ffmpeg, streaming its `-progress` output back as it goes.
    private func runFFmpeg(
        tools: VideoSplitterTools,
        arguments: [String],
        clipDuration: TimeInterval,
        progress: (Double) -> Void
    ) -> Result<Void, Failure> {
        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        // ffmpeg writes far more to stderr than a pipe buffer holds, and it blocks once
        // that fills — so stderr is drained on its own thread for the whole run instead
        // of being read after the process exits.
        let errorText = CollectedOutput()
        let errorHandle = standardError.fileHandleForReading
        let drain = Thread {
            errorText.append(errorHandle.readDataToEndOfFile())
        }
        drain.start()

        do {
            try process.run()
        } catch {
            return .failure(.ffmpeg("Couldn't start ffmpeg"))
        }

        lock.lock()
        runningProcesses[ObjectIdentifier(process)] = process
        let alreadyCancelled = isCancelled
        lock.unlock()
        if alreadyCancelled {
            process.terminate()
        }

        let outputHandle = standardOutput.fileHandleForReading
        var buffer = Data()
        while true {
            let data = outputHandle.availableData
            if data.isEmpty {
                break
            }
            buffer.append(data)
            if let fraction = VideoSplitterKit.progressFraction(
                from: String(decoding: buffer, as: UTF8.self),
                duration: clipDuration
            ) {
                progress(fraction)
            }
        }

        process.waitUntilExit()

        lock.lock()
        runningProcesses[ObjectIdentifier(process)] = nil
        lock.unlock()

        guard !cancelled else {
            return .failure(.cancelled)
        }

        guard process.terminationStatus == 0 else {
            let reason = VideoSplitterKit.conciseError(from: errorText.text) ?? "ffmpeg failed"
            return .failure(.ffmpeg(reason))
        }

        progress(1)
        return .success(())
    }

    // MARK: - Output directory

    /// Creates the clips folder, and clears out any clip of this same source left by an
    /// earlier run so a shorter split can't leave the tail of a longer one behind.
    /// Only files this tool named are touched — see ``VideoSplitterKit/isStaleClip(_:of:)``.
    private func prepareOutputDirectory(_ directory: URL, for source: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeClips(of: source, in: directory)
    }

    private func removeClips(of source: URL, in directory: URL) {
        for clip in writtenClips(of: source, in: directory) {
            try? FileManager.default.removeItem(at: clip)
        }
    }

    private func writtenClips(of source: URL, in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        return contents
            .filter { VideoSplitterKit.isStaleClip($0, of: source) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// The clips still waiting to be cut. Workers pull one at a time, so the pool
/// self-balances when clips take unequal time (the last one is usually a short tail).
private final class SegmentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [VideoSplitterKit.ClipSegment]

    init(_ segments: [VideoSplitterKit.ClipSegment]) {
        remaining = segments
    }

    func next() -> VideoSplitterKit.ClipSegment? {
        lock.lock()
        defer { lock.unlock() }
        return remaining.isEmpty ? nil : remaining.removeFirst()
    }
}

/// Turns per-clip progress arriving from several workers at once into one overall
/// fraction. Each clip's newest fraction is kept and the whole set re-totalled, so a
/// slow worker's stale value can never pull the bar backwards.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Int: Double] = [:]
    private let clipCount: Int
    private let publish: @Sendable (Double) -> Void

    init(clipCount: Int, publish: @escaping @Sendable (Double) -> Void) {
        self.clipCount = max(clipCount, 1)
        self.publish = publish
    }

    func report(clipIndex: Int, fraction: Double) {
        lock.lock()
        fractions[clipIndex] = max(fractions[clipIndex] ?? 0, fraction)
        let total = fractions.values.reduce(0, +) / Double(clipCount)
        lock.unlock()
        publish(min(max(total, 0), 1))
    }
}

/// Keeps the first failure any worker hit. Later ones are noise — they are usually
/// just the other workers noticing they were stopped.
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VideoSplitterRunner.Failure?

    func record(_ failure: VideoSplitterRunner.Failure) {
        lock.lock()
        if stored == nil {
            stored = failure
        }
        lock.unlock()
    }

    var failure: VideoSplitterRunner.Failure? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var hasFailure: Bool { failure != nil }
}

/// Accumulates a child process's stderr from the draining thread so the runner can
/// read it once the process has exited.
private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
