import XCTest
@testable import AdaptiveTransfer

final class TransferSchedulerTests: XCTestCase {

    private func item(
        _ transferID: String,
        _ index: Int,
        _ priority: TransferPriority
    ) -> ChunkWorkItem {
        ChunkWorkItem(
            transferID: transferID,
            descriptor: ChunkDescriptor(index: index, offset: index * 100, byteCount: 100),
            priority: priority
        )
    }

    func testRespectsTheLimit() {
        var scheduler = TransferScheduler()
        for index in 0..<10 { scheduler.enqueue(item("t", index, .background)) }

        var admitted = 0
        while scheduler.next(limit: 3) != nil { admitted += 1 }
        XCTAssertEqual(admitted, 3)
        XCTAssertEqual(scheduler.inFlightCount, 3)
    }

    func testALimitOfZeroStillAdmitsOneRatherThanDeadlocking() {
        var scheduler = TransferScheduler()
        scheduler.enqueue(item("t", 0, .background))
        XCTAssertNotNil(scheduler.next(limit: 0))
        var negative = TransferScheduler()
        negative.enqueue(item("t", 0, .background))
        XCTAssertNotNil(negative.next(limit: -5))
    }

    func testInteractiveWorkGoesFirst() {
        var scheduler = TransferScheduler()
        for index in 0..<5 { scheduler.enqueue(item("backfill", index, .background)) }
        scheduler.enqueue(item("share", 0, .interactive))

        let first = scheduler.next(limit: 1)
        XCTAssertEqual(first?.transferID, "share")
    }

    /// Preemption is by admission, not cancellation: the interactive item wins
    /// the next free slot and nothing in flight is touched, so no byte already
    /// pushed across a metered connection is pushed again.
    func testInteractiveWorkDoesNotDisturbInFlightWork() {
        var scheduler = TransferScheduler()
        for index in 0..<4 { scheduler.enqueue(item("backfill", index, .background)) }
        let inFlight = (0..<2).compactMap { _ in scheduler.next(limit: 2) }
        XCTAssertEqual(inFlight.count, 2)

        scheduler.enqueue(item("share", 0, .interactive))
        XCTAssertNil(scheduler.next(limit: 2), "no slot is free, so nothing is admitted")
        XCTAssertEqual(scheduler.inFlightCount, 2)

        scheduler.complete(inFlight[0].id)
        XCTAssertEqual(scheduler.next(limit: 2)?.transferID, "share")
    }

    /// Strict priority starves backfill forever under a steady interactive
    /// stream. Aging is the bounded fairness leak that prevents it.
    func testBackgroundWorkIsEventuallyPromoted() {
        var scheduler = TransferScheduler(configuration: .init(agingThreshold: 4))
        scheduler.enqueue(item("backfill", 0, .background))

        var sawBackfill = false
        for round in 0..<20 {
            scheduler.enqueue(item("share", round, .interactive))
            guard let admitted = scheduler.next(limit: 1) else { continue }
            if admitted.transferID == "backfill" { sawBackfill = true; break }
            scheduler.complete(admitted.id)
        }
        XCTAssertTrue(sawBackfill, "background work starved under a steady interactive stream")
    }

    /// Within one priority class, a 4,000-chunk video must not block a
    /// 2-chunk thumbnail set enqueued a millisecond later. Both are background,
    /// so priority cannot help — only round-robin can.
    func testRoundRobinAcrossTransfersInTheSamePriorityClass() {
        var scheduler = TransferScheduler()
        for index in 0..<50 { scheduler.enqueue(item("video", index, .background)) }
        for index in 0..<2 { scheduler.enqueue(item("thumbnails", index, .background)) }

        var thumbnailsSeenWithin = Int.max
        for round in 0..<10 {
            guard let admitted = scheduler.next(limit: 1) else { break }
            if admitted.transferID == "thumbnails" {
                thumbnailsSeenWithin = round
                break
            }
            scheduler.complete(admitted.id)
        }
        XCTAssertLessThanOrEqual(
            thumbnailsSeenWithin, 2,
            "a small transfer waited behind a large one in the same priority class"
        )
    }

    func testTheQueueIsBounded() {
        var scheduler = TransferScheduler(configuration: .init(maximumQueuedItems: 4))
        for index in 0..<10 {
            let accepted = scheduler.enqueue(item("t", index, .background))
            XCTAssertEqual(accepted, index < 4, "index \(index)")
        }
        XCTAssertEqual(scheduler.queuedCount, 4)
    }

    func testDuplicateEnqueueIsRejected() {
        var scheduler = TransferScheduler()
        XCTAssertTrue(scheduler.enqueue(item("t", 0, .background)))
        XCTAssertFalse(scheduler.enqueue(item("t", 0, .background)))
        XCTAssertEqual(scheduler.queuedCount, 1)
    }

    func testCompletingAnUnknownIdIsANoOpRatherThanACrash() {
        var scheduler = TransferScheduler()
        scheduler.complete(ChunkWorkItem.ID(transferID: "nope", chunkIndex: 99))
        scheduler.complete(ChunkWorkItem.ID(transferID: "nope", chunkIndex: 99))
        XCTAssertEqual(scheduler.inFlightCount, 0)
    }

    func testRequeuePutsWorkBackWithoutLeakingTheSlot() {
        var scheduler = TransferScheduler()
        scheduler.enqueue(item("t", 0, .background))
        guard let admitted = scheduler.next(limit: 1) else { return XCTFail("nothing admitted") }
        XCTAssertEqual(scheduler.inFlightCount, 1)
        XCTAssertTrue(scheduler.requeue(admitted))
        XCTAssertEqual(scheduler.inFlightCount, 0)
        XCTAssertEqual(scheduler.queuedCount, 1)
    }

    /// Drains a mixed workload completely. A scheduler that loses an item or
    /// spins is caught here and nowhere else.
    func testDrainsEveryItemExactlyOnce() {
        var scheduler = TransferScheduler()
        var expected: Set<ChunkWorkItem.ID> = []
        for index in 0..<30 {
            let work = item(index.isMultiple(of: 3) ? "a" : "b", index, index.isMultiple(of: 5) ? .interactive : .background)
            expected.insert(work.id)
            scheduler.enqueue(work)
        }

        var seen: Set<ChunkWorkItem.ID> = []
        var iterations = 0
        while let admitted = scheduler.next(limit: 4) {
            XCTAssertTrue(seen.insert(admitted.id).inserted, "\(admitted.id) admitted twice")
            scheduler.complete(admitted.id)
            iterations += 1
            if iterations > 1_000 { return XCTFail("scheduler did not terminate") }
        }
        XCTAssertEqual(seen, expected)
        XCTAssertEqual(scheduler.queuedCount, 0)
    }
}
