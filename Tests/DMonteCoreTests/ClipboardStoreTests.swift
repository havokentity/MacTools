import Foundation
import XCTest
@testable import DMonteCore

/// Covers `ClipboardStore`'s dedup key. A capture whose hash collides with an existing entry is
/// never recorded — the old entry is promoted in its place — so the hash decides what history
/// keeps and what a paste re-emits. Driven through the pure `contentHash(for:)` with synthetic
/// captures, so no pasteboard, disk, or store instance is involved.
final class ClipboardStoreTests: XCTestCase {

    private func hash(_ captured: CapturedPasteboard) async -> String {
        await ClipboardStore.contentHash(for: captured)
    }

    // MARK: - Namespacing by representation

    /// Finder's Copy as Pathname emits exactly the string that a preceding file copy hashed, so
    /// an un-namespaced key made the path text promote the file entry — and pasting it back put
    /// a file URL into the target app instead of the text the user copied.
    func testFileCopyAndItsPathTextHashDifferently() async {
        let file = CapturedPasteboard(filePaths: ["/a/b.txt"])
        let text = CapturedPasteboard(string: "/a/b.txt")

        let fileHash = await hash(file)
        let textHash = await hash(text)

        XCTAssertNotEqual(fileHash, textHash)
    }

    func testImageDataAndIdenticalTextBytesHashDifferently() async {
        let image = CapturedPasteboard(imageData: Data("payload".utf8), imageIsPNG: true)
        let text = CapturedPasteboard(string: "payload")

        let imageHash = await hash(image)
        let textHash = await hash(text)

        XCTAssertNotEqual(imageHash, textHash)
    }

    // MARK: - Representation priority

    /// `makeEntry` classifies filePaths first, so the hash must too. Hashing the attached
    /// preview image instead let two different files sharing icon/preview data collide.
    func testFilesAreHashedByPathEvenWhenAPreviewImageIsAttached() async {
        let preview = Data("shared-preview".utf8)
        let first = CapturedPasteboard(imageData: preview, imageIsPNG: true, filePaths: ["/a/one.txt"])
        let second = CapturedPasteboard(imageData: preview, imageIsPNG: true, filePaths: ["/a/two.txt"])

        let firstHash = await hash(first)
        let secondHash = await hash(second)
        let pathOnlyHash = await hash(CapturedPasteboard(filePaths: ["/a/one.txt"]))

        XCTAssertNotEqual(firstHash, secondHash)
        XCTAssertEqual(firstHash, pathOnlyHash)
    }

    // MARK: - Formatting is part of a text entry's identity

    func testSameTextWithDifferentRichTextHashesDifferently() async {
        let red = CapturedPasteboard(string: "Total", rtfData: Data("{\\rtf red}".utf8))
        let blue = CapturedPasteboard(string: "Total", rtfData: Data("{\\rtf blue}".utf8))

        let redHash = await hash(red)
        let blueHash = await hash(blue)

        XCTAssertNotEqual(redHash, blueHash)
    }

    /// A plain copy followed by a rich copy of the same words used to collide, leaving a `.text`
    /// entry that could only ever paste unformatted.
    func testPlainAndRichCopiesOfTheSameTextHashDifferently() async {
        let plain = CapturedPasteboard(string: "Total")
        let rich = CapturedPasteboard(string: "Total", rtfData: Data("{\\rtf red}".utf8))

        let plainHash = await hash(plain)
        let richHash = await hash(rich)

        XCTAssertNotEqual(plainHash, richHash)
    }

    /// HTML is deliberately excluded from the key while a string or RTF is present: apps such as
    /// Google Docs stamp a fresh GUID into every export, and hashing it would file each repeat
    /// copy of one selection as a new entry.
    func testSameTextWithDifferingHTMLIsStillADuplicate() async {
        let first = CapturedPasteboard(string: "Total", htmlData: Data("<p id=\"guid-1\">Total</p>".utf8))
        let second = CapturedPasteboard(string: "Total", htmlData: Data("<p id=\"guid-2\">Total</p>".utf8))

        let firstHash = await hash(first)
        let secondHash = await hash(second)

        XCTAssertEqual(firstHash, secondHash)
    }

    /// The HTML exclusion is conditional on the string actually carrying the content. Some apps
    /// pair `public.html` with a blank `public.utf8-plain-text`; skipping their HTML would hash
    /// every such copy to the same "no content" key and collapse them into one history entry.
    func testHTMLIsHashedWhenThePlainStringIsBlank() async {
        let first = CapturedPasteboard(string: "", htmlData: Data("<p>first</p>".utf8))
        let second = CapturedPasteboard(string: "", htmlData: Data("<p>second</p>".utf8))

        let firstHash = await hash(first)
        let secondHash = await hash(second)

        XCTAssertNotEqual(firstHash, secondHash)
    }

    /// A missing string and a blank one are the same absence of content, so the key must not
    /// depend on which of the two the source app happened to write.
    func testBlankAndAbsentStringsWithTheSameHTMLHashAlike() async {
        let blank = CapturedPasteboard(string: "", htmlData: Data("<p>Total</p>".utf8))
        let absent = CapturedPasteboard(htmlData: Data("<p>Total</p>".utf8))

        let blankHash = await hash(blank)
        let absentHash = await hash(absent)

        XCTAssertEqual(blankHash, absentHash)
    }

    // MARK: - Dedup still holds

    func testIdenticalCapturesHashAlike() async {
        let first = CapturedPasteboard(string: "Total", rtfData: Data("{\\rtf red}".utf8))
        let second = CapturedPasteboard(string: "Total", rtfData: Data("{\\rtf red}".utf8))

        let firstHash = await hash(first)
        let secondHash = await hash(second)

        XCTAssertEqual(firstHash, secondHash)
    }

    /// The source app is metadata, not content: re-copying the same text elsewhere must still
    /// promote the existing entry rather than pile up near-identical rows.
    func testSourceAppDoesNotAffectTheHash() async {
        let fromEditor = CapturedPasteboard(string: "Total", sourceAppBundleID: "com.apple.TextEdit")
        let fromTerminal = CapturedPasteboard(string: "Total", sourceAppBundleID: "com.apple.Terminal")

        let editorHash = await hash(fromEditor)
        let terminalHash = await hash(fromTerminal)

        XCTAssertEqual(editorHash, terminalHash)
    }
}
