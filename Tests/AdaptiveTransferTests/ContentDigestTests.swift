import XCTest
@testable import AdaptiveTransfer

final class ContentDigestTests: XCTestCase {

    /// The load-bearing test for resumption correctness.
    ///
    /// These constants were computed outside this process and are checked in,
    /// which is the only way to catch a per-process-seeded hash. The obvious
    /// test — hash the same bytes twice in one process and assert the results
    /// match — passes for `Hasher` too, and `Hasher` would silently break
    /// resumption across app launches.
    func testDigestMatchesGoldenVectors() {
        // Canonical FNV-1a/64 vectors.
        XCTAssertEqual(ContentDigest(hashing: [UInt8]()).value, 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(ContentDigest(hashing: Array("a".utf8)).value, 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(ContentDigest(hashing: Array("foobar".utf8)).value, 0x8594_4171_f739_67e8)
    }

    func testDescriptionIsSixteenHexDigits() {
        XCTAssertEqual(ContentDigest(value: 0).description, "0000000000000000")
        XCTAssertEqual(ContentDigest(value: 0xff).description, "00000000000000ff")
        XCTAssertEqual(ContentDigest(hashing: Array("a".utf8)).description, "af63dc4c8601ec8c")
    }

    func testDifferentContentProducesDifferentDigest() {
        let a = ContentDigest(hashing: Array("chunk-0".utf8))
        let b = ContentDigest(hashing: Array("chunk-1".utf8))
        XCTAssertNotEqual(a, b)
    }

}
