import XCTest
@testable import AdaptiveTransfer

/// A transport whose behaviour is scripted per chunk index.
private final actor ScriptedTransport: ChunkTransport {

    enum Behaviour: Sendable {
        case succeed(milliseconds: Int)
        /// Fails `times` times, then succeeds.
        case failThenSucceed(kind: ChunkTransportError.Kind, times: Int)
        /// Fails forever.
        case alwaysFail(kind: ChunkTransportError.Kind)
    }

    private let behaviours: [Int: Behaviour]
    private let defaultBehaviour: Behaviour
    private var failureCounts: [Int: Int] = [:]
    private(set) var sentIndices: [Int] = []

    init(default defaultBehaviour: Behaviour = .succeed(milliseconds: 40),
         behaviours: [Int: Behaviour] = [:]) {
        self.defaultBehaviour = defaultBehaviour
        self.behaviours = behaviours
    }

    func send(chunk: ChunkDescriptor, transferID: String) async throws -> ChunkReceipt {
        sentIndices.append(chunk.index)
        switch behaviours[chunk.index] ?? defaultBehaviour {
        case .succeed(let milliseconds):
            return receipt(for: chunk, milliseconds: milliseconds)

        case .failThenSucceed(let kind, let times):
            let seen = failureCounts[chunk.index] ?? 0
            if seen < times {
                failureCounts[chunk.index] = seen + 1
                throw ChunkTransportError(kind: kind, chunkIndex: chunk.index)
            }
            return receipt(for: chunk, milliseconds: 40)

        case .alwaysFail(let kind):
            failureCounts[chunk.index] = (failureCounts[chunk.index] ?? 0) + 1
            throw ChunkTransportError(kind: kind, chunkIndex: chunk.index)
        }
    }

    func attempts(for index: Int) -> Int {
        sentIndices.filter { $0 == index }.count
    }

    private func receipt(for chunk: ChunkDescriptor, milliseconds: Int) -> ChunkReceipt {
        ChunkReceipt(
            chunkIndex: chunk.index,
            digest: ContentDigest(hashing: Array("chunk-\(chunk.index)".utf8)),
            roundTrip: .milliseconds(milliseconds)
        )
    }
}

/// Records the highest number of sends that were ever simultaneously in
/// flight, which is the only evidence that the limit bounds anything.
private final actor ConcurrencyWitness: ChunkTransport {
    private var inFlight = 0
    private(set) var peakConcurrency = 0

    func send(chunk: ChunkDescriptor, transferID: String) async throws -> ChunkReceipt {
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        // Yields enough times that a genuinely concurrent caller overlaps and a
        // serial one does not.
        for _ in 0..<8 { await Task.yield() }
        inFlight -= 1
        return ChunkReceipt(
            chunkIndex: chunk.index,
            digest: ContentDigest(value: UInt64(truncatingIfNeeded: chunk.index)),
            roundTrip: .milliseconds(40)
        )
    }
}

/// Succeeds, but slowly enough that a second caller can overlap it.
private final actor SlowTransport: ChunkTransport {
    func send(chunk: ChunkDescriptor, transferID: String) async throws -> ChunkReceipt {
        try? await Task.sleep(for: .milliseconds(50))
        return ChunkReceipt(
            chunkIndex: chunk.index,
            digest: ContentDigest(value: UInt64(truncatingIfNeeded: chunk.index)),
            roundTrip: .milliseconds(40)
        )
    }
}

final class TransferCoordinatorTests: XCTestCase {

    private let planner = ChunkPlanner(
        configuration: .init(preferredChunkSize: 100, minimumChunkSize: 10)
    )

    private func request(
        _ id: String = "t1",
        totalBytes: Int = 1_000,
        priority: TransferPriority = .interactive,
        payload: String = "payload-v1"
    ) -> TransferRequest {
        TransferRequest(
            transferID: id,
            totalBytes: totalBytes,
            priority: priority,
            fingerprint: .init(hashing: Array(payload.utf8))
        )
    }

    /// Fast retry policy so the tests do not actually sleep for seconds.
    private let fastPolicy = RetryPolicy(
        maximumAttemptsPerChunk: 3,
        baseDelay: .microseconds(1),
        multiplier: 1,
        maximumDelay: .microseconds(2)
    )

    func testUploadsEveryChunkAndAcknowledgesThem() async throws {
        let transport = ScriptedTransport()
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy
        )
        let outcome = try await coordinator.upload(request())

        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.manifest.acknowledged, Array(0..<10))
        XCTAssertTrue(outcome.terminallyFailedChunks.isEmpty)
        let sent = await transport.sentIndices.sorted()
        XCTAssertEqual(sent, Array(0..<10))
    }

    func testAnEmptyPayloadCompletesWithoutSendingAnything() async throws {
        let transport = ScriptedTransport()
        let coordinator = TransferCoordinator(transport: transport, planner: planner)
        let outcome = try await coordinator.upload(request(totalBytes: 0, payload: ""))
        XCTAssertTrue(outcome.isComplete)
        let sent = await transport.sentIndices
        XCTAssertEqual(sent, [])
    }

    func testResumesFromAStoredManifestWithoutResendingAcknowledgedChunks() async throws {
        let fingerprint = TransferManifest.SourceFingerprint(hashing: Array("payload-v1".utf8))
        var stored = TransferManifest(
            transferID: "t1", chunkCount: 10, chunkSize: 100, fingerprint: fingerprint
        )
        for index in 0..<6 { stored.acknowledge(chunkIndex: index) }

        let transport = ScriptedTransport()
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy,
            store: InMemoryManifestStore(seeded: [stored])
        )
        let outcome = try await coordinator.upload(request())

        let sent = await transport.sentIndices.sorted()
        XCTAssertEqual(outcome.resumeReason, .resumed)
        XCTAssertEqual(sent, [6, 7, 8, 9])
        XCTAssertTrue(outcome.isComplete)
    }

    func testAChangedSourceForcesAFullResend() async throws {
        var stored = TransferManifest(
            transferID: "t1",
            chunkCount: 10,
            chunkSize: 100,
            fingerprint: .init(hashing: Array("payload-v1".utf8))
        )
        for index in 0..<9 { stored.acknowledge(chunkIndex: index) }

        let transport = ScriptedTransport()
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy,
            store: InMemoryManifestStore(seeded: [stored])
        )
        let outcome = try await coordinator.upload(request(payload: "payload-v2"))

        let sent = await transport.sentIndices.sorted()
        XCTAssertEqual(outcome.resumeReason, .sourceChanged)
        XCTAssertEqual(sent, Array(0..<10))
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.manifest.fingerprint.prefixDigest,
                       ContentDigest(hashing: Array("payload-v2".utf8)))
    }

    func testRetriesARetryableFailureAndSucceeds() async throws {
        let transport = ScriptedTransport(
            behaviours: [3: .failThenSucceed(kind: .throttled, times: 2)]
        )
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy
        )
        let outcome = try await coordinator.upload(request())

        let attempts = await transport.attempts(for: 3)
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(outcome.terminallyFailedChunks.isEmpty)
    }

    func testATerminalFailureIsNotRetried() async throws {
        let transport = ScriptedTransport(behaviours: [2: .alwaysFail(kind: .rejected)])
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy
        )
        let outcome = try await coordinator.upload(request())

        let attempts = await transport.attempts(for: 2)
        XCTAssertEqual(attempts, 1, "a rejected chunk must not be retried")
        XCTAssertEqual(outcome.terminallyFailedChunks, [2])
        XCTAssertFalse(outcome.isComplete)
    }

    /// Head-of-line blocking, end to end: one permanently broken chunk must not
    /// stop the other nine from landing.
    func testOnePoisonedChunkDoesNotStopTheOthersUnderThePerChunkBudget() async throws {
        let transport = ScriptedTransport(behaviours: [5: .alwaysFail(kind: .timedOut)])
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy,
            budgetShape: .perChunk(globalBackstop: 1_000)
        )
        let outcome = try await coordinator.upload(request())

        XCTAssertEqual(outcome.terminallyFailedChunks, [5])
        XCTAssertEqual(outcome.manifest.acknowledged, [0, 1, 2, 3, 4, 6, 7, 8, 9])
        let attempts = await transport.attempts(for: 5)
        XCTAssertEqual(attempts, 3)
    }

    /// The budget shape this package argues against, on the workload that
    /// actually distinguishes them: a flaky path where *every* chunk fails once.
    ///
    /// A single shared pool cannot tell "one permanently broken chunk" from "a
    /// network having a bad ten seconds", so it spends the same allowance on
    /// both and abandons a transfer the per-chunk shape completes. Note that one
    /// poisoned chunk alone does *not* reproduce this here, because the
    /// admission loop defers a failed chunk's retry behind fresh work — which is
    /// itself a fairness property worth knowing about.
    func testAGlobalOnlyBudgetAbandonsAFlakyTransferThePerChunkShapeCompletes() async throws {
        var flaky: [Int: ScriptedTransport.Behaviour] = [:]
        for index in 0..<10 {
            flaky[index] = .failThenSucceed(kind: .timedOut, times: 1)
        }

        let lenient = TransferCoordinator(
            transport: ScriptedTransport(behaviours: flaky),
            planner: planner,
            policy: fastPolicy,
            budgetShape: .perChunk(globalBackstop: 1_000)
        )
        let lenientOutcome = try await lenient.upload(request())
        XCTAssertTrue(
            lenientOutcome.isComplete,
            "per-chunk budgets should ride out a transient failure on every chunk"
        )

        // Ten chunks each fail once, so ten retries are needed. A shared pool
        // of six covers the first six failures and refuses the rest: the chunks
        // that happen to fail late are abandoned, for no reason having anything
        // to do with those chunks.
        let strict = TransferCoordinator(
            transport: ScriptedTransport(behaviours: flaky),
            planner: planner,
            policy: fastPolicy,
            budgetShape: .globalOnly(attempts: 6)
        )
        let strictOutcome = try await strict.upload(request())
        XCTAssertFalse(
            strictOutcome.isComplete,
            "a shared pool is supposed to run out and abandon healthy chunks"
        )
        XCTAssertFalse(strictOutcome.terminallyFailedChunks.isEmpty)
    }

    /// The corruption the claim flag exists to prevent, reproduced against the
    /// fixed implementation.
    ///
    /// Before `claim()`, two concurrent `upload(_:)` calls on one coordinator
    /// raced across the `await store.load(...)` suspension: `resolve()` reset
    /// the limiter, scheduler, budget and manifest mid-flight, and the first
    /// call then returned the *second* transfer's manifest as its own result —
    /// a 50-chunk upload reporting `isComplete == true` while carrying a
    /// 3-chunk manifest, with no error raised anywhere.
    func testASecondConcurrentUploadIsRejectedRatherThanCorruptingTheFirst() async throws {
        let transport = SlowTransport()
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy
        )

        // Both requests are built before the `async let`, so the concurrent
        // closure captures a `Sendable` value rather than the test case.
        let requestA = request("A", totalBytes: 5_000, payload: "A")
        let requestB = request("B", totalBytes: 300, payload: "B")

        async let first = coordinator.upload(requestA)
        // Long enough for the first call to get past its `await store.load`,
        // short enough that it is still running: 50 chunks at 50 ms each,
        // bounded by the limiter, takes several hundred milliseconds.
        try await Task.sleep(for: .milliseconds(30))

        do {
            _ = try await coordinator.upload(requestB)
            XCTFail("a second concurrent upload must not be admitted")
        } catch let error as TransferCoordinatorError {
            XCTAssertEqual(error, .busy)
        }

        let outcome = try await first
        XCTAssertEqual(outcome.transferID, "A")
        XCTAssertEqual(outcome.manifest.transferID, "A", "the manifest belonged to another transfer")
        XCTAssertEqual(outcome.manifest.chunkCount, 50)
        XCTAssertTrue(outcome.isComplete)
    }

    /// And the claim is released, so the coordinator is reusable.
    func testTheClaimIsReleasedAfterATransferFinishes() async throws {
        let coordinator = TransferCoordinator(
            transport: ScriptedTransport(),
            planner: planner,
            policy: fastPolicy
        )
        _ = try await coordinator.upload(request("A", payload: "A"))
        let second = try await coordinator.upload(request("B", payload: "B"))
        XCTAssertTrue(second.isComplete)
    }

    /// Every chunk must end up either acknowledged or reported as failed.
    ///
    /// The retry path was fixed to check `requeue`'s result; the *admission*
    /// path was still discarding `enqueue`'s. With a plan larger than the
    /// scheduler's queue cap, the surplus descriptors were dropped on the floor
    /// and the transfer ended neither complete nor with those indices in
    /// `terminallyFailedChunks` — the outcome the fix was written to prevent,
    /// surviving on the sibling call in the same function.
    ///
    /// The queue is now sized from the plan, so this asserts the accounting
    /// identity directly rather than the mechanism.
    func testEveryChunkIsEitherAcknowledgedOrReportedAsFailed() async throws {
        // A planner configured for fine resumption granularity on a large file
        // — exactly what the package's own documentation argues for — which
        // used to exceed the scheduler's default cap.
        let finePlanner = ChunkPlanner(
            configuration: .init(
                preferredChunkSize: 10,
                minimumChunkSize: 10,
                maximumChunkCount: 20_000
            )
        )
        let coordinator = TransferCoordinator(
            transport: ScriptedTransport(),
            planner: finePlanner,
            policy: fastPolicy
        )
        let outcome = try await coordinator.upload(
            request(totalBytes: 200_000, payload: "big")
        )

        XCTAssertEqual(outcome.manifest.chunkCount, 20_000)
        XCTAssertEqual(
            Saturating.add(
                outcome.manifest.acknowledgedCount,
                outcome.terminallyFailedChunks.count
            ),
            outcome.manifest.chunkCount,
            "chunks went missing: neither acknowledged nor reported as failed"
        )
        XCTAssertTrue(outcome.isComplete)
    }

    /// The limit is meant to bound real concurrency, not just be reported. A
    /// transport that records its own high-water mark is the only way to tell
    /// the difference between a working limiter and a serial upload loop that
    /// happens to print plausible limits.
    func testConcurrencyIsGenuinelyBoundedByTheLimit() async throws {
        let transport = ConcurrencyWitness()
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy,
            limiterConfiguration: .init(minimumLimit: 1, maximumLimit: 3, initialLimit: 3)
        )
        let outcome = try await coordinator.upload(request(totalBytes: 4_000))

        let peak = await transport.peakConcurrency
        XCTAssertTrue(outcome.isComplete)
        XCTAssertGreaterThan(peak, 1, "the coordinator uploaded serially; the limit does nothing")
        XCTAssertLessThanOrEqual(peak, 3, "the coordinator exceeded the limiter's ceiling")
    }

    func testFailuresFeedTheLimiterAsDropsAndShrinkIt() async throws {
        let transport = ScriptedTransport(
            default: .alwaysFail(kind: .timedOut)
        )
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: planner,
            policy: fastPolicy,
            limiterConfiguration: .init(minimumLimit: 1, maximumLimit: 32, initialLimit: 16)
        )
        let outcome = try await coordinator.upload(request())
        XCTAssertLessThan(outcome.finalLimit, 16)
        XCTAssertEqual(outcome.terminallyFailedChunks.count, 10)
    }

    func testTheManifestIsPersistedSoASecondRunResumes() async throws {
        let store = InMemoryManifestStore()
        let firstTransport = ScriptedTransport(behaviours: [9: .alwaysFail(kind: .rejected)])
        let first = TransferCoordinator(
            transport: firstTransport, planner: planner, policy: fastPolicy, store: store
        )
        let firstOutcome = try await first.upload(request())
        XCTAssertEqual(firstOutcome.terminallyFailedChunks, [9])

        let secondTransport = ScriptedTransport()
        let second = TransferCoordinator(
            transport: secondTransport, planner: planner, policy: fastPolicy, store: store
        )
        let secondOutcome = try await second.upload(request())

        let sent = await secondTransport.sentIndices
        XCTAssertEqual(secondOutcome.resumeReason, .resumed)
        XCTAssertEqual(sent, [9])
        XCTAssertTrue(secondOutcome.isComplete)
    }

    func testAnUnexpectedErrorIsTreatedAsRetryableRatherThanCrashing() async throws {
        struct Weird: Error {}
        final actor Throwing: ChunkTransport {
            private(set) var calls = 0
            func send(chunk: ChunkDescriptor, transferID: String) async throws -> ChunkReceipt {
                calls += 1
                throw Weird()
            }
            func callCount() -> Int { calls }
        }
        let transport = Throwing()
        let coordinator = TransferCoordinator(
            transport: transport,
            planner: ChunkPlanner(configuration: .init(preferredChunkSize: 1_000)),
            policy: fastPolicy
        )
        let outcome = try await coordinator.upload(request(totalBytes: 500))
        XCTAssertFalse(outcome.isComplete)
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 3, "a non-ChunkTransportError should retry")
    }
}
