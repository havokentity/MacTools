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
        // Audio-only is the only mode that adds flags; video mode must keep producing
        // exactly what it did before the mode switch existed.
        XCTAssertEqual(
            VideoDownloaderKit.mediaSelectionArguments(mode: .video, quality: .high, audioFormat: .mp3),
            ["-f", VideoQuality.high.ytDlpFormat]
        )
    }

    func testAudioOnlyArgumentsUseExtractAudioWithTheChosenFormat() {
        for format in VideoAudioFormat.allCases {
            let arguments = VideoDownloaderKit.mediaSelectionArguments(
                mode: .audioOnly,
                quality: .maximum,
                audioFormat: format
            )

            XCTAssertTrue(arguments.contains("-x"), format.rawValue)
            guard let formatIndex = arguments.firstIndex(of: "--audio-format") else {
                return XCTFail("no --audio-format for \(format.rawValue)")
            }
            XCTAssertEqual(arguments[formatIndex + 1], format.rawValue)

            // The video quality tier must not leak into an audio-only run: it would
            // pull down a video stream that the extract step throws away.
            XCTAssertFalse(arguments.contains(VideoQuality.maximum.ytDlpFormat), format.rawValue)
        }
    }

    func testAudioOnlySelectsAnAudioOnlyStreamAndPrefersM4ANatively() {
        // M4A can be remuxed straight from YouTube's m4a stream; asking for the best
        // audio outright would land on Opus and force a pointless re-encode.
        XCTAssertTrue(VideoAudioFormat.m4a.ytDlpFormat.hasPrefix("bestaudio[ext=m4a]"))
        XCTAssertTrue(VideoAudioFormat.mp3.ytDlpFormat.hasPrefix("bestaudio"))

        for format in VideoAudioFormat.allCases {
            // Sources with no audio-only stream still have to work.
            XCTAssertTrue(format.ytDlpFormat.hasSuffix("/best"), format.rawValue)
        }
    }

    func testAudioOnlyRequestsBestQualityForTheTranscode() {
        let arguments = VideoDownloaderKit.mediaSelectionArguments(mode: .audioOnly, quality: .low, audioFormat: .mp3)
        guard let index = arguments.firstIndex(of: "--audio-quality") else {
            return XCTFail("no --audio-quality")
        }
        XCTAssertEqual(arguments[index + 1], "0")
    }

    func testOutputTemplateLeavesTheExtensionToYTDLP() {
        // yt-dlp's extract-audio step renames the file to the audio format itself, so
        // the template stays extension-agnostic in both modes.
        let template = VideoDownloaderKit.outputTemplate(saveDirectory: temporaryDirectory)
        XCTAssertEqual(template, temporaryDirectory.appendingPathComponent("%(title).200B.%(ext)s").path)
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

    private func makeDownloadItem(
        url: String,
        state: VideoDownloaderModel.DownloadState
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
            outputFilePath: nil
        )
    }
}
