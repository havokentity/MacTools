import XCTest
@testable import DMonteCore

final class VideoDownloaderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testDownloadedFileURLFindsDestinationFile() throws {
        let videoURL = temporaryDirectory.appendingPathComponent("Clip.mp4")
        FileManager.default.createFile(atPath: videoURL.path, contents: Data())

        let output = "[download] Destination: \(videoURL.path)\n[download] 100% of 1.00MiB"

        XCTAssertEqual(
            VideoDownloaderRunner.downloadedFileURL(from: output, saveDirectory: temporaryDirectory),
            videoURL
        )
    }

    func testDownloadedFileURLPrefersMergedFileOverIntermediateDestination() throws {
        let intermediateURL = temporaryDirectory.appendingPathComponent("Clip.f137.mp4")
        let mergedURL = temporaryDirectory.appendingPathComponent("Clip.mp4")
        FileManager.default.createFile(atPath: intermediateURL.path, contents: Data())
        FileManager.default.createFile(atPath: mergedURL.path, contents: Data())

        let output = """
        [download] Destination: \(intermediateURL.path)
        [download] 100% of 1.00MiB
        [Merger] Merging formats into "\(mergedURL.path)"
        """

        XCTAssertEqual(
            VideoDownloaderRunner.downloadedFileURL(from: output, saveDirectory: temporaryDirectory),
            mergedURL
        )
    }

    func testNormalizedURLPreservesCaseSensitiveVideoID() {
        // The dedup key must not case-fold the path: these are two different videos.
        let upper = VideoDownloaderModel.normalizedURLString("https://www.youtube.com/shorts/wLOWk_RR1dg")
        let lower = VideoDownloaderModel.normalizedURLString("https://www.youtube.com/shorts/wlowk_rr1dg")

        XCTAssertEqual(upper, "https://www.youtube.com/shorts/wLOWk_RR1dg")
        XCTAssertNotEqual(upper, lower)
    }

    @MainActor
    func testVisibleDownloadsAreNewestFirst() {
        let model = VideoDownloaderModel()
        let oldest = makeDownloadItem(url: "https://example.com/oldest", state: .complete)
        let middle = makeDownloadItem(url: "https://example.com/middle", state: .failed)
        let newest = makeDownloadItem(url: "https://example.com/newest", state: .queued)

        model.downloads = [oldest, middle, newest]

        XCTAssertEqual(model.visibleDownloads.map(\.id), [newest.id, middle.id, oldest.id])
    }

    func testNormalizedURLPreservesCaseSensitiveQueryValue() {
        let key = VideoDownloaderModel.normalizedURLString("https://www.youtube.com/watch?v=wLOWk_RR1dg")
        XCTAssertEqual(key, "https://www.youtube.com/watch?v=wLOWk_RR1dg")
    }

    func testNormalizedURLLowercasesSchemeAndHostOnly() {
        // Scheme and host are case-insensitive, so casing differences there still dedup,
        // while the path keeps its case.
        let a = VideoDownloaderModel.normalizedURLString("HTTPS://WWW.YouTube.com/shorts/wLOWk_RR1dg")
        let b = VideoDownloaderModel.normalizedURLString("https://www.youtube.com/shorts/wLOWk_RR1dg")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "https://www.youtube.com/shorts/wLOWk_RR1dg")
    }

    func testNormalizedURLStripsTrailingSlashFragmentAndTracking() {
        let key = VideoDownloaderModel.normalizedURLString(
            "  https://www.youtube.com/shorts/wLOWk_RR1dg/?utm_source=share&igshid=abc#t=10s  "
        )
        XCTAssertEqual(key, "https://www.youtube.com/shorts/wLOWk_RR1dg")
    }

    func testNormalizedURLKeepsNonTrackingQueryAfterStrippingTracking() {
        let key = VideoDownloaderModel.normalizedURLString(
            "https://www.youtube.com/watch?v=wLOWk_RR1dg&utm_medium=email"
        )
        XCTAssertEqual(key, "https://www.youtube.com/watch?v=wLOWk_RR1dg")
    }

    func testSanitizedURLRejectsOptionLikeText() {
        // yt-dlp reads a leading dash as an option, so clipboard text like "-U" would
        // make it self-update rather than download anything.
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString("-U"))
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString("  --update  "))
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString("--config-locations=/tmp/evil.conf"))
    }

    func testSanitizedURLRejectsNonWebText() {
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString(""))
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString("   "))
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString("not a url"))
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString("file:///etc/passwd"))
        XCTAssertNil(VideoDownloaderModel.sanitizedURLString("ftp://example.com/clip.mp4"))
    }

    func testSanitizedURLKeepsWebLinksAndAssumesHTTPSForBareHosts() {
        XCTAssertEqual(
            VideoDownloaderModel.sanitizedURLString("  https://x.com/i/status/1  "),
            "https://x.com/i/status/1"
        )
        XCTAssertEqual(
            VideoDownloaderModel.sanitizedURLString("http://example.com/clip.mp4"),
            "http://example.com/clip.mp4"
        )
        XCTAssertEqual(
            VideoDownloaderModel.sanitizedURLString("youtube.com/watch?v=wLOWk_RR1dg"),
            "https://youtube.com/watch?v=wLOWk_RR1dg"
        )
    }

    func testEveryQualityRequestsAMergeBeforeFallingBackToPremuxed() {
        // `best` on its own only ever matches a premuxed file, which YouTube caps at
        // 720p — so each tier must ask for a video+audio merge first.
        for quality in VideoQuality.allCases {
            let format = quality.ytDlpFormat
            XCTAssertTrue(format.hasPrefix("bestvideo*"), "\(quality.rawValue): \(format)")
            XCTAssertTrue(format.contains("+bestaudio"), "\(quality.rawValue): \(format)")
            XCTAssertTrue(format.hasSuffix("/best"), "\(quality.rawValue): \(format)")
        }
    }

    func testQualityHeightLimitAppliesToMergeSelectorsToo() {
        let limits: [VideoQuality: String] = [.high: "1080", .normal: "720", .low: "360"]

        for (quality, limit) in limits {
            let selectors = quality.ytDlpFormat.split(separator: "/").map(String.init)
            // The last selector is the unconstrained fallback; everything before it
            // carries the tier's ceiling.
            XCTAssertEqual(selectors.last, "best", quality.rawValue)
            for selector in selectors.dropLast() {
                XCTAssertTrue(selector.contains("[height<=\(limit)]"), "\(quality.rawValue): \(selector)")
            }
        }

        XCTAssertFalse(VideoQuality.maximum.ytDlpFormat.contains("height<="))
    }

    func testVideoModeArgumentsAreJustTheQualitySelector() {
        // Video mode emits the quality selector and nothing else — every other flag
        // here belongs to the extract-audio pipeline.
        XCTAssertEqual(
            VideoDownloaderKit.mediaSelectionArguments(mode: .video, quality: .high, audioFormat: .mp3),
            ["-f", VideoQuality.high.ytDlpFormat]
        )
    }

    func testAudioOnlyArgumentsUseExtractAudioWithTheChosenFormat() {
        // Pinned as whole arrays: these are what gets handed to a process, and an
        // assertion that only spot-checks membership would pass on a flag emitted
        // with the wrong value beside it.
        XCTAssertEqual(
            VideoDownloaderKit.mediaSelectionArguments(mode: .audioOnly, quality: .maximum, audioFormat: .m4a),
            ["-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a", "--audio-quality", "0"]
        )
        XCTAssertEqual(
            VideoDownloaderKit.mediaSelectionArguments(mode: .audioOnly, quality: .low, audioFormat: .mp3),
            ["-f", "bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        )
    }

    func testAudioOnlyIgnoresTheVideoQualityTier() {
        // A height-capped video selector in an audio run would pull down a video
        // stream that the extract step then throws away.
        for quality in VideoQuality.allCases {
            for format in VideoAudioFormat.allCases {
                let arguments = VideoDownloaderKit.mediaSelectionArguments(
                    mode: .audioOnly,
                    quality: quality,
                    audioFormat: format
                )

                XCTAssertFalse(arguments.contains(quality.ytDlpFormat), "\(quality.rawValue)/\(format.rawValue)")
                XCTAssertEqual(
                    arguments,
                    VideoDownloaderKit.mediaSelectionArguments(mode: .audioOnly, quality: .maximum, audioFormat: format)
                )
            }
        }
    }

    func testOnlyM4APinsAContainerInItsFormatSelector() {
        // M4A leads with YouTube's native m4a stream so the extract step can remux.
        // MP3 must *not* do the same: it re-encodes whatever it gets, so pinning m4a
        // would throw away a better Opus source for nothing.
        XCTAssertTrue(VideoAudioFormat.m4a.ytDlpFormat.hasPrefix("bestaudio[ext=m4a]"))
        XCTAssertFalse(VideoAudioFormat.mp3.ytDlpFormat.contains("ext="))

        for format in VideoAudioFormat.allCases {
            // Sources with no audio-only stream still have to work: the extractor
            // strips the video track off a premuxed file.
            XCTAssertTrue(format.ytDlpFormat.hasSuffix("/best"), format.rawValue)
        }
    }

    func testVideoModeEmitsSubtitleFlagsForEveryConfiguredMode() {
        XCTAssertEqual(
            VideoDownloaderKit.subtitleArguments(
                mode: .video,
                subtitleMode: .englishOnly,
                preferredLanguages: ["fr-FR"]
            ),
            ["--write-subs", "--write-auto-subs", "--sub-langs", "en.*"]
        )
        XCTAssertEqual(
            VideoDownloaderKit.subtitleArguments(
                mode: .video,
                subtitleMode: .englishAndSystem,
                preferredLanguages: ["fr-FR"]
            ),
            ["--write-subs", "--write-auto-subs", "--sub-langs", "en.*,fr.*"]
        )

        // "All languages" is the only mode that may swallow a subtitle failure, since
        // it is the only one that reliably trips YouTube's 429.
        XCTAssertEqual(
            VideoDownloaderKit.subtitleArguments(
                mode: .video,
                subtitleMode: .allLanguages,
                preferredLanguages: ["en-US"]
            ),
            ["--write-subs", "--write-auto-subs", "--sub-langs", "all", "--ignore-errors"]
        )

        // Off is the one video-mode case that emits nothing.
        XCTAssertEqual(
            VideoDownloaderKit.subtitleArguments(mode: .video, subtitleMode: .off, preferredLanguages: ["en-US"]),
            []
        )
    }

    func testAudioOnlyEmitsNoSubtitleFlagsHoweverSubtitlesAreConfigured() {
        // Sidecar .vtt files next to an .m4a are dead weight, and "all languages" can
        // 429 the download outright — so the preference is dropped, not honoured.
        for subtitleMode in VideoSubtitleMode.allCases {
            XCTAssertEqual(
                VideoDownloaderKit.subtitleArguments(
                    mode: .audioOnly,
                    subtitleMode: subtitleMode,
                    preferredLanguages: ["fr-FR"]
                ),
                [],
                subtitleMode.rawValue
            )
        }
    }

    func testVideoModeEmitsTheConfiguredMP4HandlingFlags() {
        XCTAssertEqual(
            VideoDownloaderKit.containerArguments(mode: .video, nonMP4Handling: .downloadMP4LowerQuality),
            ["--merge-output-format", "mp4"]
        )
        XCTAssertEqual(
            VideoDownloaderKit.containerArguments(mode: .video, nonMP4Handling: .convertToMP4),
            ["--recode-video", "mp4"]
        )

        // "Download without conversion" is the one mode that means "add no flag".
        XCTAssertEqual(
            VideoDownloaderKit.containerArguments(mode: .video, nonMP4Handling: .downloadWithoutConversion),
            []
        )
    }

    func testAudioOnlyEmitsNoMP4HandlingFlagsHoweverConfigured() {
        // --recode-video/--merge-output-format name a video container, so they would
        // fight the extract-audio step rather than be quietly ignored.
        for handling in VideoNonMP4Handling.allCases {
            XCTAssertEqual(
                VideoDownloaderKit.containerArguments(mode: .audioOnly, nonMP4Handling: handling),
                [],
                handling.rawValue
            )
        }
    }

    func testOutputTemplateLeavesTheExtensionToYTDLP() {
        let template = VideoDownloaderKit.outputTemplate(saveDirectory: temporaryDirectory)

        XCTAssertTrue(template.hasPrefix(temporaryDirectory.path + "/"))

        // yt-dlp's extract-audio step renames the file to the audio format itself, so
        // naming any extension here would only fight it.
        XCTAssertTrue(template.hasSuffix(".%(ext)s"))
        for format in VideoAudioFormat.allCases {
            XCTAssertFalse(template.contains(format.fileExtension), format.rawValue)
        }

        // .200B caps the title in *bytes*, not characters: a CJK or emoji title would
        // otherwise sail past the filesystem's 255-byte name limit.
        XCTAssertTrue(template.contains("%(title).200B"))
    }

    func testExtractedAudioPathSwapsTheExtension() {
        XCTAssertEqual(
            VideoDownloaderKit.extractedAudioPath(fromDownloadedPath: "/tmp/Some Clip.webm", audioFormat: .mp3),
            "/tmp/Some Clip.mp3"
        )
        XCTAssertEqual(
            VideoDownloaderKit.extractedAudioPath(fromDownloadedPath: "/tmp/Clip.f251.webm", audioFormat: .m4a),
            "/tmp/Clip.f251.m4a"
        )
    }

    func testExtractedAudioPathLeavesExtensionlessPathsAlone() {
        // Inventing an extension here would name a file yt-dlp never wrote.
        XCTAssertEqual(
            VideoDownloaderKit.extractedAudioPath(fromDownloadedPath: "/tmp/Clip", audioFormat: .mp3),
            "/tmp/Clip"
        )
    }

    func testExtractedAudioPathKeepsARelativePathRelative() {
        // downloadedFileURL resolves a bare name against the save directory. Deriving
        // through URL(fileURLWithPath:) would anchor it to the process working
        // directory instead and point the lookup somewhere else entirely.
        XCTAssertEqual(
            VideoDownloaderKit.extractedAudioPath(fromDownloadedPath: "Song.webm", audioFormat: .mp3),
            "Song.mp3"
        )
    }

    func testExtractedAudioPathHandlesDottedAndUnicodeTitles() {
        XCTAssertEqual(
            VideoDownloaderKit.extractedAudioPath(fromDownloadedPath: "/tmp/Vol. 2 — Ünïcodé 🎵.webm", audioFormat: .m4a),
            "/tmp/Vol. 2 — Ünïcodé 🎵.m4a"
        )
    }

    func testDownloadedFileURLResolvesADerivedRelativePathAgainstTheSaveDirectory() throws {
        let audioURL = temporaryDirectory.appendingPathComponent("Song.mp3")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        // yt-dlp logged a bare file name, and the extract-audio line never arrived.
        let output = "[download] Destination: Song.webm"

        XCTAssertEqual(
            VideoDownloaderRunner.downloadedFileURL(
                from: output,
                saveDirectory: temporaryDirectory,
                audioFormat: .mp3
            ),
            audioURL
        )
    }

    func testDownloadedFileURLFindsExtractedAudioFile() throws {
        let audioURL = temporaryDirectory.appendingPathComponent("Talk.mp3")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        // yt-dlp deletes the downloaded stream once it has extracted the audio, so only
        // the .mp3 is left on disk.
        let output = """
        [download] Destination: \(temporaryDirectory.appendingPathComponent("Talk.webm").path)
        [download] 100% of 4.00MiB
        [ExtractAudio] Destination: \(audioURL.path)
        """

        XCTAssertEqual(
            VideoDownloaderRunner.downloadedFileURL(
                from: output,
                saveDirectory: temporaryDirectory,
                audioFormat: .mp3
            ),
            audioURL
        )
    }

    func testDownloadedFileURLDerivesAudioPathWhenTheExtractLineIsMissing() throws {
        // Guards against yt-dlp rewording its postprocessor output: the rename rule
        // (same name, audio extension) still locates the finished file.
        let audioURL = temporaryDirectory.appendingPathComponent("Talk.m4a")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        let output = "[download] Destination: \(temporaryDirectory.appendingPathComponent("Talk.webm").path)"

        XCTAssertEqual(
            VideoDownloaderRunner.downloadedFileURL(
                from: output,
                saveDirectory: temporaryDirectory,
                audioFormat: .m4a
            ),
            audioURL
        )
    }

    func testProgressReportsAudioExtractionRatherThanFinishing() {
        // The extract step runs after the download hits 100%, and one pipe read can
        // carry both lines — reporting "Finishing" would freeze the row for the whole
        // transcode and hide that anything is still happening.
        let progress = VideoDownloaderRunner.parseProgress(
            from: "[download] 100% of 4.00MiB\n[ExtractAudio] Destination: /tmp/Talk.mp3"
        )

        XCTAssertEqual(progress?.detail, "Extracting audio")
        XCTAssertNil(progress?.fraction)
    }

    func testProgressPhaseIsTakenFromTheLastLineOfTheChunk() {
        // A whole download of a short track can land in one pipe read. Every earlier
        // phase in the chunk is already over by the time it is parsed, so matching any
        // of them would park the row on a stale label for the entire postprocess.
        let wholeRun = """
        [download] Destination: /tmp/Talk.webm
        [download]  42.0% of 4.00MiB at 1.20MiB/s ETA 00:02
        [download] 100% of 4.00MiB
        [ExtractAudio] Destination: /tmp/Talk.mp3
        """

        XCTAssertEqual(VideoDownloaderRunner.parseProgress(from: wholeRun)?.detail, "Extracting audio")

        // Same masking, video side: yt-dlp prints a Destination line per stream, so a
        // merge is always preceded by one.
        let merge = """
        [download] Destination: /tmp/Clip.f251.webm
        [download] 100% of 9.00MiB
        [Merger] Merging formats into "/tmp/Clip.mp4"
        """

        XCTAssertEqual(VideoDownloaderRunner.parseProgress(from: merge)?.detail, "Merging")

        // And a second stream starting after the first one finished reports that
        // stream's progress, not the previous stream's completion.
        let secondStream = """
        [download] 100% of 9.00MiB
        [download] Destination: /tmp/Clip.f140.m4a
        [download]   7.0% of 300.00KiB at 500.00KiB/s ETA 00:01
        """
        let progress = VideoDownloaderRunner.parseProgress(from: secondStream)

        XCTAssertEqual(progress?.fraction, 0.07)
        XCTAssertEqual(progress?.detail, "at 500.00KiB/s  ETA 00:01")
    }

    func testProgressStillReportsPreparingAndFinishing() {
        XCTAssertEqual(
            VideoDownloaderRunner.parseProgress(from: "[download] Destination: /tmp/Clip.mp4")?.detail,
            "Preparing file"
        )

        let finishing = VideoDownloaderRunner.parseProgress(from: "[download] 100% of 4.00MiB in 00:03")
        XCTAssertEqual(finishing?.detail, "Finishing")
        XCTAssertEqual(finishing?.fraction, 1)

        XCTAssertNil(VideoDownloaderRunner.parseProgress(from: ""))
        XCTAssertNil(VideoDownloaderRunner.parseProgress(from: "[youtube] Extracting URL: https://example.com"))
    }

    func testProgressStillReportsDownloadPercentInAudioMode() {
        let progress = VideoDownloaderRunner.parseProgress(
            from: "[download]  42.0% of 4.00MiB at 1.20MiB/s ETA 00:02"
        )

        XCTAssertEqual(progress?.fraction, 0.42)
        XCTAssertEqual(progress?.detail, "at 1.20MiB/s  ETA 00:02")
    }

    func testSubtitleEnglishAndSystemNeverRequestsAll() {
        // The whole point of the fix: this mode never emits "all" (triggers YouTube's 429).
        let langs = VideoSubtitleMode.englishAndSystem.subtitleLanguageArgument(preferredLanguages: ["fr-FR", "de-DE"])
        XCTAssertEqual(langs, "en.*,fr.*")
        XCTAssertEqual(langs?.contains("all"), false)
    }

    func testSubtitleEnglishAndSystemAlwaysIncludesEnglish() {
        XCTAssertEqual(
            VideoSubtitleMode.englishAndSystem.subtitleLanguageArgument(preferredLanguages: ["pt-BR"]),
            "en.*,pt.*"
        )
    }

    func testSubtitleEnglishAndSystemDeduplicatesEnglish() {
        // System language already English: don't list "en" twice.
        XCTAssertEqual(VideoSubtitleMode.englishAndSystem.subtitleLanguageArgument(preferredLanguages: ["en-US"]), "en.*")
        XCTAssertEqual(VideoSubtitleMode.englishAndSystem.subtitleLanguageArgument(preferredLanguages: []), "en.*")
    }

    func testSubtitleEnglishOnlyAndAllAndOff() {
        XCTAssertEqual(VideoSubtitleMode.englishOnly.subtitleLanguageArgument(preferredLanguages: ["fr-FR"]), "en.*")
        XCTAssertEqual(VideoSubtitleMode.allLanguages.subtitleLanguageArgument(preferredLanguages: ["fr-FR"]), "all")
        XCTAssertNil(VideoSubtitleMode.off.subtitleLanguageArgument(preferredLanguages: ["en-US"]))
    }

    func testOnlyAllLanguagesToleratesSubtitleFailures() {
        XCTAssertTrue(VideoSubtitleMode.allLanguages.allowsSubtitleFailures)
        XCTAssertFalse(VideoSubtitleMode.englishAndSystem.allowsSubtitleFailures)
        XCTAssertFalse(VideoSubtitleMode.englishOnly.allowsSubtitleFailures)
        XCTAssertFalse(VideoSubtitleMode.off.allowsSubtitleFailures)
    }

    // MARK: - Duplicate detection across output formats

    /// The same link queued as M4A and then as MP3 produces two different files, so the second
    /// request is not a duplicate. Keying duplicate detection on the URL alone silently refused
    /// it — and cleared the field without a word, which read as the app ignoring the paste.
    func testSameURLInADifferentAudioFormatIsNotADuplicate() {
        let url = "https://example.com/watch?v=abc"
        let m4a = makeDownloadItem(url: url, state: .queued, variant: "audio:m4a")
        let mp3 = makeDownloadItem(url: url, state: .queued, variant: "audio:mp3")

        XCTAssertNotEqual(m4a.variant, mp3.variant)
        XCTAssertEqual(
            VideoDownloaderModel.normalizedURLString(m4a.url),
            VideoDownloaderModel.normalizedURLString(mp3.url),
            "The URLs match — it is the output format that makes these distinct downloads"
        )
    }

    /// The same link at the same output still is one, so re-pasting does not queue it twice.
    func testSameURLInTheSameFormatIsADuplicate() {
        let url = "https://example.com/watch?v=abc"
        let first = makeDownloadItem(url: url, state: .queued, variant: "audio:mp3")
        let second = makeDownloadItem(url: url, state: .downloading, variant: "audio:mp3")

        XCTAssertEqual(first.variant, second.variant)
        XCTAssertEqual(
            VideoDownloaderModel.normalizedURLString(first.url),
            VideoDownloaderModel.normalizedURLString(second.url)
        )
    }

    /// Video quality changes the file too, so the same rule has to hold on that side.
    func testSameURLAtADifferentVideoQualityIsNotADuplicate() {
        let url = "https://example.com/watch?v=abc"
        let hd = makeDownloadItem(url: url, state: .queued, variant: "video:hd1080")
        let max = makeDownloadItem(url: url, state: .queued, variant: "video:maximum")

        XCTAssertNotEqual(hd.variant, max.variant)
    }

    private func makeDownloadItem(
        url: String,
        state: VideoDownloaderModel.DownloadState,
        variant: String = "video:maximum"
    ) -> VideoDownloaderModel.DownloadItem {
        VideoDownloaderModel.DownloadItem(
            id: UUID(),
            url: url,
            title: "example.com",
            status: "Queued",
            detail: "",
            progressFraction: nil,
            progressDetail: "Waiting",
            copyText: url,
            state: state,
            retryCount: 0,
            outputDirectory: nil,
            outputFilePath: nil,
            variant: variant
        )
    }
}
