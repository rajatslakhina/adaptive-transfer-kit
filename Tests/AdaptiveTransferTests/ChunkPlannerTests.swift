import XCTest
import Foundation
@testable import AdaptiveTransfer

final class ChunkPlannerTests: XCTestCase {

    func testZeroBytesProducesNoChunks() {
        // Not one empty chunk: a chunk with nothing to acknowledge would leave
        // every caller that waits for "no chunks left" waiting forever.
        XCTAssertTrue(ChunkPlanner().plan(totalBytes: 0).isEmpty)
    }

    func testNegativeTotalProducesNoChunks() {
        XCTAssertTrue(ChunkPlanner().plan(totalBytes: -1).isEmpty)
        XCTAssertTrue(ChunkPlanner().plan(totalBytes: Int.min).isEmpty)
    }

    func testChunksCoverThePayloadExactlyWithNoGapsOrOverlaps() {
        let planner = ChunkPlanner(
            configuration: .init(preferredChunkSize: 1_000, minimumChunkSize: 100)
        )
        for total in [1, 999, 1_000, 1_001, 3_500, 10_000] {
            let plan = planner.plan(totalBytes: total)
            XCTAssertEqual(plan.map(\.byteCount).reduce(0, +), total, "total \(total)")
            XCTAssertEqual(plan.first?.offset, 0, "total \(total)")
            for (previous, next) in zip(plan, plan.dropFirst()) {
                XCTAssertEqual(previous.range.upperBound, next.offset, "total \(total)")
            }
            XCTAssertEqual(plan.last?.range.upperBound, total, "total \(total)")
            XCTAssertEqual(plan.map(\.index), Array(0..<plan.count), "total \(total)")
            XCTAssertTrue(plan.allSatisfy { $0.byteCount > 0 }, "total \(total)")
        }
    }

    /// The memory bound. A 40 GB file at a 1 MiB chunk size is 40,960
    /// descriptors; the planner has to grow the chunk size instead of the
    /// count, and degrade resumption granularity rather than the process.
    func testChunkCountIsBoundedAndSizeGrowsInstead() {
        let planner = ChunkPlanner(
            configuration: .init(preferredChunkSize: 1 << 20, maximumChunkCount: 1_000)
        )
        let fortyGigabytes = 40 * (1 << 30)
        let plan = planner.plan(totalBytes: fortyGigabytes)
        XCTAssertLessThanOrEqual(plan.count, 1_000)
        XCTAssertGreaterThan(planner.chunkSize(forTotalBytes: fortyGigabytes), 1 << 20)
        XCTAssertEqual(plan.map(\.byteCount).reduce(0, +), fortyGigabytes)
    }

    func testChunkCountStaysBoundedAtIntMax() {
        // `Int.max` bytes is not a real file; it is what an overflowed size
        // calculation upstream produces, and it must not allocate.
        let planner = ChunkPlanner(configuration: .init(maximumChunkCount: 512))
        XCTAssertLessThanOrEqual(planner.plan(totalBytes: Int.max).count, 512)
    }

    func testConfigurationSanitisesSizes() {
        let configuration = ChunkPlanner.Configuration(
            preferredChunkSize: 10,
            minimumChunkSize: 5_000,
            maximumChunkCount: 0
        )
        XCTAssertEqual(configuration.minimumChunkSize, 5_000)
        XCTAssertEqual(configuration.preferredChunkSize, 5_000)
        XCTAssertEqual(configuration.maximumChunkCount, 1)
    }

    /// `ChunkDescriptor` is public and `Codable`, so its initializer's
    /// arguments can arrive from a decoded manifest rather than from the
    /// planner. A negative `byteCount` used to produce a `Range` whose lower
    /// bound exceeded its upper bound, and `Range.init` traps on that — a
    /// crash reachable straight through the public API, in a package whose
    /// README claims no arithmetic can trap.
    func testChunkDescriptorClampsItsInputsAndItsRangeNeverTraps() {
        let negative = ChunkDescriptor(index: -1, offset: -100, byteCount: -1)
        XCTAssertEqual(negative.index, 0)
        XCTAssertEqual(negative.offset, 0)
        XCTAssertEqual(negative.byteCount, 0)
        XCTAssertEqual(negative.range, 0..<0)

        let overflowing = ChunkDescriptor(index: 0, offset: Int.max, byteCount: Int.max)
        XCTAssertEqual(overflowing.range.lowerBound, Int.max)
        XCTAssertEqual(overflowing.range.upperBound, Int.max)
        XCTAssertTrue(overflowing.range.isEmpty)

        let ordinary = ChunkDescriptor(index: 2, offset: 200, byteCount: 100)
        XCTAssertEqual(ordinary.range, 200..<300)
    }

    /// The clamp has to hold on the *decode* path, which is the path its own
    /// documentation names. A synthesized `init(from:)` writes the stored
    /// properties directly, so an earlier version of this test — which only
    /// exercised the memberwise initializer — passed while the decode path was
    /// completely unprotected.
    func testDecodingAChunkDescriptorAlsoClamps() throws {
        let hostile = #"{"index":-7,"offset":-3,"byteCount":-9223372036854775808}"#
        let decoded = try JSONDecoder().decode(
            ChunkDescriptor.self,
            from: Data(hostile.utf8)
        )
        XCTAssertEqual(decoded.index, 0)
        XCTAssertEqual(decoded.offset, 0)
        XCTAssertEqual(decoded.byteCount, 0)
        XCTAssertEqual(decoded.range, 0..<0)

        let ordinary = try JSONDecoder().decode(
            ChunkDescriptor.self,
            from: Data(#"{"index":2,"offset":200,"byteCount":100}"#.utf8)
        )
        XCTAssertEqual(ordinary.range, 200..<300)
    }

    func testSmallPayloadUsesThePreferredSize() {
        let planner = ChunkPlanner(
            configuration: .init(preferredChunkSize: 4_096, minimumChunkSize: 512)
        )
        XCTAssertEqual(planner.chunkSize(forTotalBytes: 100), 4_096)
        XCTAssertEqual(planner.plan(totalBytes: 100).count, 1)
        XCTAssertEqual(planner.plan(totalBytes: 100).first?.byteCount, 100)
    }
}
