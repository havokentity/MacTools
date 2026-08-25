import Foundation
import XCTest
@testable import DMonteCore

/// Pins the splitter's pure core: the segment plan, the ffmpeg arguments it produces,
/// where clips land, and how ffmpeg's output is read back. Nothing here spawns ffmpeg.
final class VideoSplitterKitTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/Videos/Bibi Beats Mimi.mp4")

    // MARK: - Planning

    func testPlanCutsEveryClipUnderTheCap() {
        let plan = VideoSplitterKit.plan(duration: 200, maxClipLength: 60)

        XCTAssertEqual(plan.count, 4)
        for segment in plan {
            XCTAssertLessThanOrEqual(
                segment.length, 60,
                "Clip \(segment.index) is \(segment.length)s — over the 60s cap the whole tool exists to respect"
            )
        }
    }

    func testPlanCoversTheWholeVideoWithoutGapsOrOverlap() {
        let plan = VideoSplitterKit.plan(duration: 200, maxClipLength: 60)

        XCTAssertEqual(plan.first?.start, 0)
        for (previous, next) in zip(plan, plan.dropFirst()) {
            XCTAssertEqual(previous.start + previous.length, next.start, accuracy: 0.0001)
        }
        let last = try? XCTUnwrap(plan.last)
        XCTAssertEqual((last?.start ?? 0) + (last?.length ?? 0), 200, accuracy: 0.0001)
    }

    func testPlanKeepsClipsJustUnderTheCapRatherThanWellUnderIt() {
        // A 59.9s target is the point: cutting at, say, 55s would need an extra clip.
        let plan = VideoSplitterKit.plan(duration: 200, maxClipLength: 60)
        XCTAssertEqual(plan[0].length, 59.9, accuracy: 0.0001)
    }

    func testPlanOfShorterThanOneClipIsASingleClip() {
        let plan = VideoSplitterKit.plan(duration: 12.5, maxClipLength: 60)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].start, 0)
        XCTAssertEqual(plan[0].length, 12.5, accuracy: 0.0001)
    }

    func testPlanDropsAFloatResidueTail() {
        // An exact multiple of the 59.9s target: `ceil` can land on 3.0000001 and invent
        // a zero-length third clip, which must not be written.
        let plan = VideoSplitterKit.plan(duration: 59.9 * 3, maxClipLength: 60)

        XCTAssertEqual(plan.count, 3)
        XCTAssertTrue(plan.allSatisfy { $0.length > VideoSplitterKit.minimumClipLength })
    }

    func testPlanOfUnreadableDurationIsEmpty() {
        XCTAssertTrue(VideoSplitterKit.plan(duration: 0, maxClipLength: 60).isEmpty)
        XCTAssertTrue(VideoSplitterKit.plan(duration: -4, maxClipLength: 60).isEmpty)
        XCTAssertTrue(VideoSplitterKit.plan(duration: 90, maxClipLength: 0).isEmpty)
    }

    func testPlanHonoursEveryOfferedClipLength() {
        for seconds in VideoSplitterKit.clipLengthChoices {
            let cap = TimeInterval(seconds)
            let plan = VideoSplitterKit.plan(duration: 500, maxClipLength: cap)

            XCTAssertFalse(plan.isEmpty, "\(seconds)s produced no plan")
            XCTAssertTrue(
                plan.allSatisfy { $0.length <= cap },
                "\(seconds)s produced a clip over its own cap"
            )
        }
    }

    // MARK: - Output locations

    func testOutputDirectoryIsNamedForTheSourceAndTheCap() {
        let directory = VideoSplitterKit.outputDirectory(for: source, maxClipLength: 60)

        XCTAssertEqual(directory.lastPathComponent, "Bibi Beats Mimi_60s_clips")
        XCTAssertEqual(directory.deletingLastPathComponent().path, "/Videos")
    }

    func testChosenDestinationStillGetsAPerVideoFolder() {
        let directory = VideoSplitterKit.outputDirectory(
            for: source,
            maxClipLength: 30,
            destination: URL(fileURLWithPath: "/Users/me/Desktop")
        )

        XCTAssertEqual(directory.lastPathComponent, "Bibi Beats Mimi_30s_clips")
        XCTAssertEqual(directory.deletingLastPathComponent().path, "/Users/me/Desktop")
    }

    func testClipNamesAreZeroPaddedSoTheySortInPlaybackOrder() {
        let directory = URL(fileURLWithPath: "/Videos/clips")
        let names = [2, 10].map { VideoSplitterKit.clipURL(for: source, index: $0, in: directory).lastPathComponent }

        XCTAssertEqual(names, ["Bibi Beats Mimi_part_002.mp4", "Bibi Beats Mimi_part_010.mp4"])
        XCTAssertTrue(names[0] < names[1])
    }

    func testOnlyThisToolsOwnClipsCountAsStale() {
        let directory = URL(fileURLWithPath: "/Videos/clips")

        XCTAssertTrue(VideoSplitterKit.isStaleClip(
            directory.appendingPathComponent("Bibi Beats Mimi_part_000.mp4"), of: source
        ))
        // A destination the user picked can hold their own videos. Clearing anything but
        // our own naming would destroy files nobody asked us to touch.
        XCTAssertFalse(VideoSplitterKit.isStaleClip(
            directory.appendingPathComponent("Holiday.mp4"), of: source
        ))
        XCTAssertFalse(VideoSplitterKit.isStaleClip(
            directory.appendingPathComponent("Another Video_part_000.mp4"), of: source
        ))
        XCTAssertFalse(VideoSplitterKit.isStaleClip(
            directory.appendingPathComponent("Bibi Beats Mimi_part_000.txt"), of: source
        ))
    }

    // MARK: - ffmpeg arguments

    func testClipArgumentsSeekBeforeInputAndBoundTheSegment() {
        let arguments = VideoSplitterKit.clipArguments(
            source: source,
            segment: VideoSplitterKit.ClipSegment(index: 1, start: 59.9, length: 59.9),
            outputURL: URL(fileURLWithPath: "/Videos/clips/out.mp4"),
            encoder: .cpu,
            threadCount: 6,
            sourceBitrate: 4_000_000
        )

        let seekIndex = try? XCTUnwrap(arguments.firstIndex(of: "-ss"))
        let inputIndex = try? XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertLessThan(seekIndex ?? .max, inputIndex ?? 0, "-ss must precede -i for a fast seek")

        XCTAssertEqual(arguments[(seekIndex ?? 0) + 1], "59.900")
        XCTAssertEqual(arguments[(try? XCTUnwrap(arguments.firstIndex(of: "-t"))).map { $0 + 1 } ?? 0], "59.900")
        XCTAssertEqual(arguments.last, "/Videos/clips/out.mp4")
        XCTAssertTrue(arguments.contains("-progress"))
    }

    func testClipArgumentsMakeAudioOptionalSoSilentVideosStillSplit() {
        let arguments = VideoSplitterKit.clipArguments(
            source: source,
            segment: VideoSplitterKit.ClipSegment(index: 0, start: 0, length: 30),
            outputURL: URL(fileURLWithPath: "/Videos/clips/out.mp4"),
            encoder: .cpu,
            threadCount: 4,
            sourceBitrate: 0
        )

        XCTAssertTrue(arguments.contains("0:a?"), "A source with no audio track must not fail the split")
    }

    func testQualityArgumentsTrackTheSourceBitrateOnEitherEncoder() {
        for encoder in VideoSplitterKit.Encoder.allCases {
            XCTAssertEqual(
                VideoSplitterKit.qualityArguments(encoder: encoder, sourceBitrate: 4_000_000),
                ["-b:v", "4000000", "-maxrate", "6000000", "-bufsize", "12000000"],
                "\(encoder) should honour the source bitrate"
            )
        }
    }

    func testQualityFallbackUsesTheKnobEachEncoderActuallyHonours() {
        // Matroska often states no bitrate; a clip must not come out visibly softer.
        // VideoToolbox ignores CRF outright, so the GPU path needs -q:v instead.
        XCTAssertEqual(VideoSplitterKit.qualityArguments(encoder: .cpu, sourceBitrate: 0), ["-crf", "18"])
        XCTAssertEqual(VideoSplitterKit.qualityArguments(encoder: .hardware, sourceBitrate: 0), ["-q:v", "65"])
    }

    // MARK: - Hardware encoding

    func testHardwareClipUsesVideoToolboxAndAllowsItsSoftwareFallback() {
        let arguments = VideoSplitterKit.clipArguments(
            source: source,
            segment: VideoSplitterKit.ClipSegment(index: 0, start: 0, length: 30),
            outputURL: URL(fileURLWithPath: "/Videos/clips/out.mp4"),
            encoder: .hardware,
            threadCount: 4,
            sourceBitrate: 4_000_000
        )

        XCTAssertTrue(arguments.contains("h264_videotoolbox"))
        XCTAssertFalse(arguments.contains("libx264"))
        // x264-only knobs must not leak into the hardware invocation.
        XCTAssertFalse(arguments.contains("-preset"))
        XCTAssertFalse(arguments.contains("-crf"))
        // Keeps a Mac with no hardware encoder working instead of failing every clip.
        XCTAssertEqual(arguments[(try? XCTUnwrap(arguments.firstIndex(of: "-allow_sw"))).map { $0 + 1 } ?? 0], "1")
    }

    // MARK: - Parallelism

    func testEncodePlanCutsSeveralClipsAtOnceOnAManyCoreMac() {
        // The measured best config on a 16-core M4 Max: 4 workers x 3 threads finished
        // four 60s clips in 19s against 26s for one worker on 14 threads.
        let plan = VideoSplitterKit.encodePlan(clipCount: 12, encoder: .cpu, activeProcessorCount: 16)

        XCTAssertEqual(plan.workerCount, 4)
        XCTAssertEqual(plan.threadsPerWorker, 3)
    }

    func testASingleClipGetsTheWholeMachineRatherThanOneWorkersShare() {
        let plan = VideoSplitterKit.encodePlan(clipCount: 1, encoder: .cpu, activeProcessorCount: 16)

        XCTAssertEqual(plan.workerCount, 1)
        XCTAssertEqual(plan.threadsPerWorker, 14)
    }

    func testEncodePlanNeverStartsMoreWorkersThanThereAreClips() {
        for clipCount in 1...5 {
            let plan = VideoSplitterKit.encodePlan(
                clipCount: clipCount, encoder: .cpu, activeProcessorCount: 16
            )
            XCTAssertLessThanOrEqual(plan.workerCount, clipCount)
        }
    }

    func testHardwareEncodingUsesFewerWorkersBecauseTheMediaEngineIsShared() {
        let cpu = VideoSplitterKit.encodePlan(clipCount: 12, encoder: .cpu, activeProcessorCount: 16)
        let gpu = VideoSplitterKit.encodePlan(clipCount: 12, encoder: .hardware, activeProcessorCount: 16)

        XCTAssertEqual(gpu.workerCount, 3)
        XCTAssertLessThan(gpu.workerCount, cpu.workerCount)
    }

    func testEncodePlanStaysSaneOnSmallMachines() {
        for cores in 1...8 {
            for encoder in VideoSplitterKit.Encoder.allCases {
                let plan = VideoSplitterKit.encodePlan(
                    clipCount: 20, encoder: encoder, activeProcessorCount: cores
                )
                XCTAssertGreaterThanOrEqual(plan.workerCount, 1, "\(cores) cores, \(encoder)")
                XCTAssertGreaterThanOrEqual(plan.threadsPerWorker, 2, "\(cores) cores, \(encoder)")
                XCTAssertLessThanOrEqual(plan.workerCount, 4, "\(cores) cores, \(encoder)")
            }
        }
    }

    // MARK: - Reading ffmpeg back

    func testProgressReadsOutTimeAsMicroseconds() {
        // Despite the name, out_time_ms is microseconds. Reading it as milliseconds
        // would peg the bar at 100% one frame in.
        let fraction = VideoSplitterKit.progressFraction(
            from: "frame=120\nout_time_ms=30000000\nspeed=2.1x\n",
            duration: 60
        )

        XCTAssertEqual(try XCTUnwrap(fraction), 0.5, accuracy: 0.0001)
    }

    func testProgressUsesTheNewestReportedPosition() {
        let fraction = VideoSplitterKit.progressFraction(
            from: "out_time_ms=6000000\nprogress=continue\nout_time_ms=48000000\nprogress=continue\n",
            duration: 60
        )

        XCTAssertEqual(try XCTUnwrap(fraction), 0.8, accuracy: 0.0001)
    }

    func testProgressIsClampedAndNilWithoutAPosition() {
        XCTAssertEqual(
            try XCTUnwrap(VideoSplitterKit.progressFraction(from: "out_time_ms=90000000", duration: 60)),
            1
        )
        XCTAssertNil(VideoSplitterKit.progressFraction(from: "frame=1\nfps=0.0\n", duration: 60))
        XCTAssertNil(VideoSplitterKit.progressFraction(from: "out_time_ms=1000", duration: 0))
    }

    func testConciseErrorPicksTheComplaintOutOfFFmpegsPreamble() {
        let stderr = """
        ffmpeg version 8.1.1 Copyright (c) 2000-2026 the FFmpeg developers
          configuration: --enable-gpl --enable-libx264
        Stream #0:0: Video: h264, yuv420p, 1920x1080
        /Videos/broken.mp4: Invalid data found when processing input
        """

        XCTAssertEqual(
            VideoSplitterKit.conciseError(from: stderr),
            "/Videos/broken.mp4: Invalid data found when processing input"
        )
    }

    func testConciseErrorFallsBackToTheLastLine() {
        XCTAssertEqual(VideoSplitterKit.conciseError(from: "something odd\nlast word\n"), "last word")
        XCTAssertNil(VideoSplitterKit.conciseError(from: "  \n\n"))
    }

    // MARK: - Source types

    func testOnlySupportedContainersAreAccepted() {
        for ext in ["mp4", "MOV", "m4v", "mkv"] {
            XCTAssertTrue(VideoSplitterKit.isSupportedVideo(URL(fileURLWithPath: "/Videos/clip.\(ext)")))
        }
        for ext in ["png", "mp3", "avi", ""] {
            XCTAssertFalse(VideoSplitterKit.isSupportedVideo(URL(fileURLWithPath: "/Videos/clip.\(ext)")))
        }
    }

    // MARK: - Bundled tool discovery

    func testSiblingLookupPointsAtTheVideoDownloadersBundledBinaries() {
        // Both helpers sit in the container's Contents/Helpers, so the splitter can use
        // the ffmpeg pair already shipped (and signed) with the Video Downloader instead
        // of adding a second 126 MB copy to the download.
        let helper = URL(fileURLWithPath: "/Applications/DMonte Tool Box.app/Contents/Helpers/DMonte Video Splitter.app")

        XCTAssertEqual(
            VideoSplitterTools.siblingVideoDownloaderBinDirectory(helperBundleURL: helper).path,
            "/Applications/DMonte Tool Box.app/Contents/Helpers/DMonte Video Downloader.app/Contents/Resources/bin"
        )
    }
}
