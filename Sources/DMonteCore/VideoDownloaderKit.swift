import Foundation

/// Pure, UI-free construction of the yt-dlp invocation DMonte Download Video makes.
/// Everything here is value-in/value-out so the headless test target can pin the
/// exact flags a preference combination produces — the runner itself can only be
/// exercised by actually spawning yt-dlp, which tests must not do.
public enum VideoDownloaderKit {
    /// The format-selection flags for one download: a video format selector, or
    /// yt-dlp's extract-audio pipeline when the user asked for audio only.
    ///
    /// `--audio-quality 0` is yt-dlp's best-quality setting and only bites when the
    /// extractor actually re-encodes (MP3 always does; M4A usually remuxes) — left
    /// at the default, a transcode would land at a lossy 5/10 VBR.
    public static func mediaSelectionArguments(
        mode: VideoDownloadMode,
        quality: VideoQuality,
        audioFormat: VideoAudioFormat
    ) -> [String] {
        switch mode {
        case .video:
            return ["-f", quality.ytDlpFormat]
        case .audioOnly:
            return [
                "-f", audioFormat.ytDlpFormat,
                "-x",
                "--audio-format", audioFormat.ytDlpAudioFormat,
                "--audio-quality", "0"
            ]
        }
    }

    /// The `-o` template for a download into `saveDirectory`.
    ///
    /// One template serves both modes: `%(ext)s` resolves to the extension of the
    /// stream yt-dlp downloaded, and in audio-only mode the extract-audio
    /// postprocessor renames that file to the chosen audio format when it finishes —
    /// so hard-coding the audio extension here would only fight yt-dlp. `.200B` caps
    /// the title at 200 *bytes* rather than characters, because a CJK or emoji title
    /// would otherwise sail past the filesystem's 255-byte name limit.
    public static func outputTemplate(saveDirectory: URL) -> String {
        saveDirectory.appendingPathComponent("%(title).200B.%(ext)s").path
    }

    /// The path yt-dlp's extract-audio step renames `downloadedPath` to: it swaps the
    /// downloaded container's extension (.webm, .m4a, …) for the audio format's and
    /// keeps everything else. Used as a last resort when locating the finished file,
    /// since the wording of yt-dlp's postprocessor log lines drifts between versions
    /// while this naming rule has not.
    public static func extractedAudioPath(
        fromDownloadedPath downloadedPath: String,
        audioFormat: VideoAudioFormat
    ) -> String {
        let url = URL(fileURLWithPath: downloadedPath)
        // A path with no extension is left alone: appending one would invent a file
        // name yt-dlp never wrote.
        guard !url.pathExtension.isEmpty else {
            return downloadedPath
        }

        return url.deletingPathExtension().appendingPathExtension(audioFormat.fileExtension).path
    }
}
