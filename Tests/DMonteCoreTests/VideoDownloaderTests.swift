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
