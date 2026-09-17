import XCTest

@testable import WeiModel

/// What a picture's target means, from the side that has to read it.
///
/// The policy — what may be drawn at all — is pinned in `md/json_test.mbt`, and it is deliberately not
/// re-tested here: this side is only asked which of the shapes it was handed it is looking at. The
/// interesting cases are therefore the ones where the shape and the meaning differ: `file:/x` against
/// `file://host/x`, a `data:` URL that carries bytes against one that carries a document, and a
/// relative path, which reads as a picture to a human and as nothing at all to a host that would have
/// to guess what it is relative to.
final class PictureTests: XCTestCase {
    func testAnAbsolutePathIsAPictureOnThisMachine() {
        XCTAssertEqual(PictureSource.of("/tmp/shot.png"), .file("/tmp/shot.png"))
        XCTAssertEqual(PictureSource.of("/Users/someone/a b/c.jpg"), .file("/Users/someone/a b/c.jpg"))
    }

    func testALocalFileURLIsTheSamePicture() {
        XCTAssertEqual(PictureSource.of("file:///tmp/shot.png"), .file("/tmp/shot.png"))
        XCTAssertEqual(PictureSource.of("file:/tmp/shot.png"), .file("/tmp/shot.png"))
        // Percent escapes are the URL's, and the path on disk is not.
        XCTAssertEqual(PictureSource.of("file:///tmp/a%20b.png"), .file("/tmp/a b.png"))
    }

    func testAFileURLOnAnotherHostIsNotThisMachinesPicture() {
        // A `file:` URL with a host asks to read across a mount. Nothing is read, and the caption is
        // what the reader sees — which is what every picture got before pictures were drawn at all.
        XCTAssertNil(PictureSource.of("file://elsewhere/tmp/shot.png"))
    }

    func testADataURLCarriesItsOwnBytes() {
        // A 1×1 PNG, which is the smallest thing that is really a picture.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
        guard case let .inline(data)? = PictureSource.of("data:image/png;base64,\(png)") else {
            return XCTFail("expected the bytes to come out of the URL")
        }
        // The PNG signature, so this is the picture and not a string that happens to decode.
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testADataURLWithoutBase64IsNotRead() {
        // Percent-encoded bytes in a string: nothing here can turn those back into bytes without
        // being told their encoding, and guessing is how a picture becomes a mess of glyphs.
        XCTAssertNil(PictureSource.of("data:image/png,some%20bytes"))
        XCTAssertNil(PictureSource.of("data:image/png;base64"))  // no payload at all
        XCTAssertNil(PictureSource.of("data:image/png;base64,not base64!!"))
    }

    func testAWebPictureIsFetched() {
        XCTAssertEqual(PictureSource.of("https://example.com/c.png"), .remote(URL(string: "https://example.com/c.png")!))
        XCTAssertEqual(PictureSource.of("http://127.0.0.1:8765/c.png"), .remote(URL(string: "http://127.0.0.1:8765/c.png")!))
    }

    func testATargetThatIsNoneOfThoseIsACaption() {
        XCTAssertNil(PictureSource.of(""))
        XCTAssertNil(PictureSource.of("chart.png"))
        XCTAssertNil(PictureSource.of("./chart.png"))
        XCTAssertNil(PictureSource.of("javascript:alert(1)"))
        XCTAssertNil(PictureSource.of("ftp://example.com/c.png"))
    }
}
