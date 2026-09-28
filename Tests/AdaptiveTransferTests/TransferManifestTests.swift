import XCTest
@testable import AdaptiveTransfer

final class TransferManifestTests: XCTestCase {

    private let planner = ChunkPlanner(
        configuration: .init(preferredChunkSize: 100, minimumChunkSize: 10)
    )

    private func fingerprint(_ text: String) -> TransferManifest.SourceFingerprint {
        TransferManifest.SourceFingerprint(hashing: Array(text.utf8))
    }

    func testResumeSkipsAcknowledgedChunks() {
        let plan = planner.plan(totalBytes: 1_000)     // 10 chunks
        let print = fingerprint("payload-v1")
        var manifest = TransferManifest(
            transferID: "t1",
            chunkCount: plan.count,
            chunkSize: 100,
            fingerprint: print
        )
        for index in 0..<4 { manifest.acknowledge(chunkIndex: index) }

        let decision = manifest.resumePlan(for: plan, fingerprint: print)
        XCTAssertEqual(decision.reason, .resumed)
        XCTAssertEqual(decision.skippedChunkCount, 4)
        XCTAssertEqual(decision.chunks.map(\.index), [4, 5, 6, 7, 8, 9])
    }

    /// The silent-corruption case. A manifest that resumes against changed
    /// bytes produces a file whose first half is the old render and second half
    /// the new one, with a 200 from the server.
    func testResumeRefusesWhenTheSourceChanged() {
        let plan = planner.plan(totalBytes: 1_000)
        var manifest = TransferManifest(
            transferID: "t1",
            chunkCount: plan.count,
            chunkSize: 100,
            fingerprint: fingerprint("payload-v1")
        )
        for index in 0..<8 { manifest.acknowledge(chunkIndex: index) }

        let decision = manifest.resumePlan(for: plan, fingerprint: fingerprint("payload-v2"))
        XCTAssertEqual(decision.reason, .sourceChanged)
        XCTAssertEqual(decision.skippedChunkCount, 0)
        XCTAssertEqual(decision.chunks.count, plan.count)
    }

    func testResumeRefusesWhenThePlanShapeChanged() {
        let print = fingerprint("payload-v1")
        var manifest = TransferManifest(
            transferID: "t1",
            chunkCount: 10,
            chunkSize: 100,
            fingerprint: print
        )
        manifest.acknowledge(chunkIndex: 0)
        let differentPlan = planner.plan(totalBytes: 2_000)   // 20 chunks
        let decision = manifest.resumePlan(for: differentPlan, fingerprint: print)
        XCTAssertEqual(decision.reason, .planShapeChanged)
        XCTAssertEqual(decision.chunks.count, 20)
    }

    /// The memory bound. A server acknowledging indices we never sent must not
    /// grow the manifest.
    func testOutOfRangeAcknowledgementsAreRejected() {
        var manifest = TransferManifest(
            transferID: "t1",
            chunkCount: 5,
            chunkSize: 100,
            fingerprint: fingerprint("x")
        )
        XCTAssertFalse(manifest.acknowledge(chunkIndex: -1))
        XCTAssertFalse(manifest.acknowledge(chunkIndex: 5))
        XCTAssertFalse(manifest.acknowledge(chunkIndex: Int.max))
        XCTAssertFalse(manifest.acknowledge(chunkIndex: Int.min))
        XCTAssertEqual(manifest.acknowledgedCount, 0)
        XCTAssertTrue(manifest.acknowledge(chunkIndex: 4))
        XCTAssertEqual(manifest.acknowledgedCount, 1)
    }

    func testAcknowledgementIsIdempotent() {
        var manifest = TransferManifest(
            transferID: "t1", chunkCount: 3, chunkSize: 10, fingerprint: fingerprint("x")
        )
        manifest.acknowledge(chunkIndex: 1)
        manifest.acknowledge(chunkIndex: 1)
        XCTAssertEqual(manifest.acknowledgedCount, 1)
    }

    func testCompletionRequiresEveryChunk() {
        var manifest = TransferManifest(
            transferID: "t1", chunkCount: 3, chunkSize: 10, fingerprint: fingerprint("x")
        )
        XCTAssertFalse(manifest.isComplete)
        for index in 0..<3 { manifest.acknowledge(chunkIndex: index) }
        XCTAssertTrue(manifest.isComplete)
    }

    func testAnEmptyPlanIsCompleteRatherThanStuck() {
        let manifest = TransferManifest(
            transferID: "t1", chunkCount: 0, chunkSize: 10, fingerprint: fingerprint("")
        )
        XCTAssertTrue(manifest.isComplete)
    }

    /// Round-trips through the encoder the store would use, because a manifest
    /// that cannot be read back is not durable state, whatever the type says.
    func testCodableRoundTripPreservesAcknowledgements() throws {
        var manifest = TransferManifest(
            transferID: "t1", chunkCount: 4, chunkSize: 100, fingerprint: fingerprint("v1")
        )
        manifest.acknowledge(chunkIndex: 0, digest: ContentDigest(value: 7))
        manifest.acknowledge(chunkIndex: 2)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(TransferManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.acknowledged, [0, 2])
        XCTAssertEqual(decoded.digest(forChunkIndex: 0), ContentDigest(value: 7))
        XCTAssertNil(decoded.digest(forChunkIndex: 2))
    }

    func testFingerprintReadsABoundedPrefix() {
        let bytes = Array(repeating: UInt8(7), count: 1_000)
        let print = TransferManifest.SourceFingerprint(hashing: bytes, prefixLimit: 64)
        XCTAssertEqual(print.totalBytes, 1_000)
        XCTAssertEqual(print.prefixByteCount, 64)
    }

    func testFingerprintDistinguishesSameLengthDifferentHeader() {
        // The re-encode case: identical byte count, different container header.
        let a = Array("MOOVv1".utf8) + Array(repeating: UInt8(0), count: 500)
        let b = Array("MOOVv2".utf8) + Array(repeating: UInt8(0), count: 500)
        XCTAssertNotEqual(
            TransferManifest.SourceFingerprint(hashing: a),
            TransferManifest.SourceFingerprint(hashing: b)
        )
    }
}
