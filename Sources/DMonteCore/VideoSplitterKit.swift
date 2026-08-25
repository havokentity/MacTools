import Foundation

/// Pure, UI-free core of the Video Splitter: how a duration divides into clips, the
/// exact ffmpeg invocation each clip needs, where the clips are written, and how
/// ffmpeg's progress stream is read back.
///
/// Foundation only and everything `nonisolated`, so the controller can call it from a
/// detached task and the headless test target can pin the arguments without ever
/// spawning ffmpeg — which tests must not do.
public enum VideoSplitterKit {
    /// Containers the splitter accepts. Deliberately narrow: these are what the
    /// bundled ffmpeg demuxes reliably and what the social platforms this tool
    /// exists for accept back.
    public static let supportedExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv"]

    /// Clip-length choices offered in the UI, in seconds. 60 is the default because
    /// the platforms this tool exists for (Reels, Shorts, Status) cap there.
    public static let clipLengthChoices: [Int] = [15, 30, 60, 90]
    public static let defaultClipLengthSeconds = 60

    /// How far under the cap each clip is actually cut. The cap is a hard limit — an
    /// upload of 60.02s is rejected as flatly as one of 90s — and a re-encode can land
    /// a frame past the `-t` it was given, so every clip is aimed just short of it.
    public static let safetyMargin: TimeInterval = 0.1

    /// A tail shorter than this is dropped rather than written: it is floating-point
    /// residue from the segment arithmetic, not a clip anyone wants.
    public static let minimumClipLength: TimeInterval = 0.01

    /// Which encoder cuts the clips.
    ///
    /// Not a fast/slow choice — measured on a 16-core M4 Max splitting a 1080p30
    /// 21 Mbps source, x264 at `veryfast` finishes ahead of VideoToolbox (19s vs 24s
    /// for four 60-second clips). What hardware encoding buys is the *machine*: the
    /// encode runs on the media block instead of saturating a dozen cores, which is
    /// what matters on battery, while something else is rendering, or on a Mac with
    /// far fewer performance cores than this one — where it also wins outright.
    public enum Encoder: String, CaseIterable, Sendable, Identifiable {
        case cpu
        case hardware

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .cpu: "CPU"
            case .hardware: "GPU"
            }
        }

        public var detail: String {
            switch self {
            case .cpu: "x264 — best quality per megabyte, uses most of the machine."
            case .hardware: "VideoToolbox — encodes on the media engine, leaving the CPU (and your battery) alone."
            }
        }

        /// The ffmpeg encoder name, and what identifies it in `ffmpeg -encoders`.
        public var ffmpegName: String {
            switch self {
            case .cpu: "libx264"
            case .hardware: "h264_videotoolbox"
            }
        }
    }

    /// How many clips are cut at once, and how many threads each of those gets.
    public struct EncodePlan: Equatable, Sendable {
        public let workerCount: Int
        public let threadsPerWorker: Int

        public init(workerCount: Int, threadsPerWorker: Int) {
            self.workerCount = workerCount
            self.threadsPerWorker = threadsPerWorker
        }
    }

    /// One clip to cut: its ordinal (drives the file name) and its window in the source.
    public struct ClipSegment: Equatable, Sendable {
        public let index: Int
        public let start: TimeInterval
        public let length: TimeInterval

        public init(index: Int, start: TimeInterval, length: TimeInterval) {
            self.index = index
            self.start = start
            self.length = length
        }
    }

    public static func isSupportedVideo(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Planning

    /// Divides `duration` into consecutive clips no longer than `maxClipLength`.
    ///
    /// Segments are cut at `maxClipLength - safetyMargin` (see ``safetyMargin``), so a
    /// 60-second cap yields 59.9-second clips and the last one takes whatever is left.
    /// Returns an empty plan for a non-positive duration or cap — the caller reports
    /// that as a failure rather than writing nothing and calling it success.
    public static func plan(duration: TimeInterval, maxClipLength: TimeInterval) -> [ClipSegment] {
        guard duration > 0, maxClipLength > 0 else {
            return []
        }

        let target = max(maxClipLength - safetyMargin, maxClipLength / 2)
        let estimatedCount = max(Int(ceil(duration / target)), 1)

        return (0..<estimatedCount).compactMap { index in
            let start = Double(index) * target
            let length = min(target, duration - start)
            // Drops both the float-residue tail described on `minimumClipLength` and any
            // segment `ceil` over-counted past the end of the video.
            guard length > minimumClipLength else {
                return nil
            }
            return ClipSegment(index: index, start: start, length: length)
        }
    }

    // MARK: - Output locations

    /// The per-source folder clips are written into: `<name>_60s_clips` beside the
    /// source, or inside `destination` when the user picked one.
    ///
    /// Clips always land in a folder of their own, never loose in the chosen
    /// destination. A split of a 20-minute video is 20 files; and only a folder this
    /// tool named itself is safe to clear stale clips out of (see ``isStaleClip``).
    public static func outputDirectory(
        for source: URL,
        maxClipLength: TimeInterval,
        destination: URL? = nil
    ) -> URL {
        let seconds = max(Int(maxClipLength.rounded()), 1)
        let parent = destination ?? source.deletingLastPathComponent()
        return parent.appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)_\(seconds)s_clips",
            isDirectory: true
        )
    }

    /// `<name>_part_007.mp4`. Zero-padded so the clips sort in playback order in
    /// Finder and in any uploader's file picker.
    public static func clipURL(for source: URL, index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(clipNamePrefix(for: source))\(String(format: "%03d", index)).mp4"
        )
    }

    /// The `<name>_part_` prefix every clip of `source` shares.
    public static func clipNamePrefix(for source: URL) -> String {
        "\(source.deletingPathExtension().lastPathComponent)_part_"
    }

    /// Whether `url` is a leftover clip of `source` from an earlier run, i.e. safe for
    /// this run to delete.
    ///
    /// Matched by this tool's own naming rather than "any video in the folder": the
    /// destination can be a folder the user chose, and clearing videos it did not
    /// write would destroy files nobody asked it to touch.
    public static func isStaleClip(_ url: URL, of source: URL) -> Bool {
        url.lastPathComponent.hasPrefix(clipNamePrefix(for: source))
            && url.pathExtension.lowercased() == "mp4"
    }

    // MARK: - ffmpeg invocation

    /// The full argument list for cutting one clip.
    ///
    /// Re-encodes rather than stream-copies: a copy can only cut on keyframes, which
    /// on a typical source overshoots the cap by seconds. `-ss` precedes `-i` so
    /// ffmpeg seeks the input instead of decoding and discarding everything before the
    /// segment — with a re-encode that is still frame-accurate, and it keeps the last
    /// clip of a long video as fast to cut as the first. `-map 0:a?` makes the audio
    /// track optional so a silent source splits instead of failing.
    public static func clipArguments(
        source: URL,
        segment: ClipSegment,
        outputURL: URL,
        encoder: Encoder,
        threadCount: Int,
        sourceBitrate: Int
    ) -> [String] {
        var arguments = [
            "-y",
            "-hide_banner",
            "-nostats",
            "-ss", String(format: "%.3f", segment.start),
            "-i", source.path,
            "-t", String(format: "%.3f", segment.length),
            "-map", "0:v:0",
            "-map", "0:a?",
            "-c:v", encoder.ffmpegName
        ]
        switch encoder {
        case .cpu:
            arguments += ["-preset", "veryfast"]
        case .hardware:
            // `-allow_sw 1` keeps the clip from failing outright on a Mac with no
            // hardware H.264 encoder (older Intel models, some VMs): VideoToolbox
            // falls back to its own software path instead of refusing the session.
            arguments += ["-profile:v", "high", "-allow_sw", "1"]
        }
        arguments += qualityArguments(encoder: encoder, sourceBitrate: sourceBitrate)
        arguments += [
            "-pix_fmt", "yuv420p",
            "-threads", "\(max(threadCount, 1))",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            outputURL.path
        ]
        return arguments
    }

    /// Quality fallback when the source states no bitrate. CRF is x264's; VideoToolbox
    /// ignores CRF entirely and takes `-q:v` on a 1–100 scale, where 65 lands within a
    /// few percent of the source bitrate on hard 1080p content.
    public static let fallbackCRF = "18"
    public static let fallbackHardwareQuality = "65"

    /// Rate control for the re-encode: match the source's own bitrate when ffprobe
    /// could read it, so a clip is neither visibly softer than the video it came from
    /// nor several times its size. With no readable bitrate (common in Matroska), fall
    /// back to whichever near-visually-lossless quality knob this encoder honours.
    public static func qualityArguments(encoder: Encoder, sourceBitrate: Int) -> [String] {
        guard sourceBitrate > 0 else {
            switch encoder {
            case .cpu: return ["-crf", fallbackCRF]
            case .hardware: return ["-q:v", fallbackHardwareQuality]
            }
        }

        return [
            "-b:v", "\(sourceBitrate)",
            "-maxrate", "\(Int(Double(sourceBitrate) * 1.5))",
            "-bufsize", "\(Int(Double(sourceBitrate) * 3.0))"
        ]
    }

    /// How to spread `clipCount` clips across the machine.
    ///
    /// Clips are wholly independent — each ffmpeg seeks its own start and writes its own
    /// file — so cutting several at once beats handing one clip every core: x264 scales
    /// poorly past a few threads, and a lone encode leaves most of the machine idle.
    /// Measured on a 16-core M4 Max (four 60s clips of a 1080p30 21 Mbps source):
    /// 26s with one worker on 14 threads, 19s with four workers on 3 threads each.
    ///
    /// The ceilings are where that stopped paying: 5 workers regressed to 19s (the
    /// threads each one lost cost more than the overlap gained), and hardware encoding
    /// shares one media block, so a fourth concurrent session only adds contention.
    /// Fewer clips than workers means fewer workers — a single clip gets the whole
    /// machine rather than a quarter of it. Two cores are always left for everything
    /// else the user is doing.
    public static func encodePlan(
        clipCount: Int,
        encoder: Encoder,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> EncodePlan {
        let usableCores = max(1, activeProcessorCount - 2)
        let ceiling = encoder == .cpu ? 4 : 3
        let coreDerived = encoder == .cpu ? usableCores / 3 : activeProcessorCount / 4

        let workerCount = max(1, min(min(max(clipCount, 1), ceiling), max(coreDerived, 1)))
        return EncodePlan(
            workerCount: workerCount,
            threadsPerWorker: max(2, usableCores / workerCount)
        )
    }

    // MARK: - Reading ffmpeg back

    /// Fraction (0...1) of a clip of `duration` that ffmpeg's `-progress pipe:1` stream
    /// reports as written, or nil if the buffer holds no position yet.
    ///
    /// The newest line wins, so a growing buffer is re-parsed cheaply from the end.
    /// Despite its name `out_time_ms` carries *microseconds* — a long-standing ffmpeg
    /// quirk; reading it as milliseconds would peg the bar at 100% almost at once.
    public static func progressFraction(from text: String, duration: TimeInterval) -> Double? {
        guard duration > 0 else {
            return nil
        }

        for line in text.split(separator: "\n").reversed() {
            guard line.hasPrefix("out_time_ms="),
                  let microseconds = Double(line.dropFirst("out_time_ms=".count)) else {
                continue
            }
            return min(max((microseconds / 1_000_000) / duration, 0), 1)
        }
        return nil
    }

    /// The one line of an ffmpeg failure worth showing: its last complaint, else its
    /// last output at all. ffmpeg's stderr is dozens of lines of build configuration
    /// and stream metadata before it ever gets to what went wrong.
    public static func conciseError(from text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.last { line in
            line.localizedCaseInsensitiveContains("error")
                || line.localizedCaseInsensitiveContains("invalid")
                || line.localizedCaseInsensitiveContains("failed")
        } ?? lines.last
    }
}
