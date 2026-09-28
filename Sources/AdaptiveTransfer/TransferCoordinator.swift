/// What a caller asks for.
public struct TransferRequest: Sendable, Equatable {
    public let transferID: String
    public let totalBytes: Int
    public let priority: TransferPriority
    /// Fingerprint of the source, used to decide whether resumption is safe.
    public let fingerprint: TransferManifest.SourceFingerprint

    public init(
        transferID: String,
        totalBytes: Int,
        priority: TransferPriority,
        fingerprint: TransferManifest.SourceFingerprint
    ) {
        self.transferID = transferID
        self.totalBytes = max(0, totalBytes)
        self.priority = priority
        self.fingerprint = fingerprint
    }
}

/// What happened.
public struct TransferOutcome: Sendable, Equatable {
    public let transferID: String
    public let manifest: TransferManifest
    /// Chunks the server refused permanently.
    public let terminallyFailedChunks: [Int]
    public let resumeReason: TransferManifest.ResumeDecision.Reason
    public let totalAttempts: Int
    /// The limit the controller ended on — the single most useful number to log.
    public let finalLimit: Int

    public var isComplete: Bool { manifest.isComplete }
}

/// Somewhere to keep a manifest between launches.
public protocol ManifestStore: Sendable {
    func load(transferID: String) async -> TransferManifest?
    func save(_ manifest: TransferManifest) async
}

/// An in-memory store. Production conformances write to the file system; this
/// one exists so the coordinator can be tested without one.
public actor InMemoryManifestStore: ManifestStore {
    private var manifests: [String: TransferManifest] = [:]

    public init(seeded: [TransferManifest] = []) {
        for manifest in seeded { manifests[manifest.transferID] = manifest }
    }

    public func load(transferID: String) async -> TransferManifest? {
        manifests[transferID]
    }

    public func save(_ manifest: TransferManifest) async {
        manifests[manifest.transferID] = manifest
    }
}

/// The only actor in this package.
///
/// ## Why only one
///
/// Every other type here — limiter, scheduler, planner, manifest, retry budget
/// — is a `struct` with no concurrency of its own. That is not stylistic
/// tidiness. Actor isolation is cheap to add and expensive to reason about: the
/// moment a piece of state lives behind an actor, every read of it is a
/// potential suspension point, and every sequence of reads is a potential
/// interleaving. Keeping the policy state in value types means the control law
/// has exactly one owner, and the interesting question — "can two completions
/// interleave and corrupt the limit?" — has a mechanical answer instead of a
/// careful argument.
///
/// ## The reentrancy rule, stated so it can be checked
///
/// Swift actors are reentrant: an `await` inside an actor method releases the
/// actor, and other work runs before the method resumes. So the classic bug is
/// check-then-act across a suspension:
///
///     // WRONG — `limit` may be stale by the time the send returns, and two
///     // callers can both pass the check before either increments inFlight.
///     guard inFlight < limiter.currentLimit else { return }
///     let receipt = try await transport.send(...)
///     inFlight += 1
///
/// The rule this type follows: **every mutation of scheduler, limiter, budget
/// and manifest happens inside a synchronous private method that contains no
/// `await`.** Those methods are the critical sections, and the compiler
/// enforces their atomicity for free, because an actor method with no
/// suspension point cannot be interleaved. The only `await` in the whole
/// coordinator is the transport call in `perform(_:)`, and it is deliberately
/// placed in a `nonisolated` free function so it *cannot* touch actor state
/// even by accident — a reviewer can verify the rule by grepping for `await`
/// rather than by tracing control flow.
public actor TransferCoordinator {

    private let transport: any ChunkTransport
    private let planner: ChunkPlanner
    private let policy: RetryPolicy
    private let store: any ManifestStore
    private let budgetShape: RetryBudget.Shape
    private let limiterConfiguration: GradientLimiter.Configuration

    public init(
        transport: any ChunkTransport,
        planner: ChunkPlanner = ChunkPlanner(),
        policy: RetryPolicy = .default,
        store: any ManifestStore = InMemoryManifestStore(),
        budgetShape: RetryBudget.Shape = .perChunk(globalBackstop: 1024),
        limiterConfiguration: GradientLimiter.Configuration = .uploadPipeline
    ) {
        self.transport = transport
        self.planner = planner
        self.policy = policy
        self.store = store
        self.budgetShape = budgetShape
        self.limiterConfiguration = limiterConfiguration
    }

    /// Mutable state. Only the `-- critical section --` methods below touch it,
    /// and none of those contain `await`.
    private var limiter = GradientLimiter()
    private var scheduler = TransferScheduler()
    private var budget = RetryBudget()
    private var manifest: TransferManifest?
    private var terminalChunks: Set<Int> = []
    private var jitter = JitterSource(seed: 0xA11C_E000)

    /// Uploads `request`, resuming from the stored manifest if one is usable.
    ///
    /// The loop is the whole reason this type exists, so it is worth reading
    /// carefully. Work is admitted into a `TaskGroup` until the scheduler says
    /// the limiter's current limit is reached; each completion is folded into
    /// the limiter, the manifest and the retry budget inside one synchronous
    /// critical section; and then admission is re-attempted against the *new*
    /// limit. A shrinking limit therefore takes effect on the next completion,
    /// not on the next transfer.
    public func upload(_ request: TransferRequest) async throws -> TransferOutcome {
        let plan = planner.plan(totalBytes: request.totalBytes)
        let chunkSize = planner.chunkSize(forTotalBytes: request.totalBytes)

        let stored = await store.load(transferID: request.transferID)
        let decision = resolve(
            stored: stored,
            plan: plan,
            chunkSize: chunkSize,
            request: request
        )

        let transport = self.transport

        await withTaskGroup(of: CompletedAttempt.self) { group in
            var running = 0

            // `claimNextItem()` consults the limiter every call, so admission
            // tracks capacity as it is discovered rather than being fixed at
            // the start of the transfer.
            while let item = claimNextItem() {
                group.addTask { await Self.perform(transport: transport, item: item) }
                running = Saturating.add(running, 1)
            }

            while running > 0 {
                guard let attempt = await group.next() else { break }
                running = Saturating.subtract(running, 1)

                // Every mutation happens here, after the suspension, inside a
                // method with no `await` in it.
                settle(item: attempt.item, result: attempt.result)
                if let manifest { await store.save(manifest) }

                while let item = claimNextItem() {
                    group.addTask { await Self.perform(transport: transport, item: item) }
                    running = Saturating.add(running, 1)
                }
            }
        }

        let finalManifest = manifest ?? TransferManifest(
            transferID: request.transferID,
            chunkCount: plan.count,
            chunkSize: chunkSize,
            fingerprint: request.fingerprint
        )
        await store.save(finalManifest)

        return TransferOutcome(
            transferID: request.transferID,
            manifest: finalManifest,
            terminallyFailedChunks: terminalChunks.sorted(),
            resumeReason: decision.reason,
            totalAttempts: budget.totalAttempts,
            finalLimit: limiter.currentLimit
        )
    }

    /// The controller's view, for a dashboard.
    public var limiterSnapshot: (limit: Int, noLoadSeconds: Double, samples: Int) {
        (limiter.currentLimit, limiter.estimatedNoLoadSeconds, limiter.samplesObserved)
    }

    // MARK: - Critical sections. No `await` below this line.

    private func resolve(
        stored: TransferManifest?,
        plan: [ChunkDescriptor],
        chunkSize: Int,
        request: TransferRequest
    ) -> TransferManifest.ResumeDecision {
        limiter = GradientLimiter(configuration: limiterConfiguration)
        budget = RetryBudget(shape: budgetShape)
        scheduler = TransferScheduler()
        terminalChunks = []

        let base = stored ?? TransferManifest(
            transferID: request.transferID,
            chunkCount: plan.count,
            chunkSize: chunkSize,
            fingerprint: request.fingerprint
        )
        let decision = base.resumePlan(for: plan, fingerprint: request.fingerprint)

        switch decision.reason {
        case .sourceChanged, .planShapeChanged:
            // The bytes or the plan moved; nothing already on the server can be
            // trusted, so start from a clean manifest rather than inheriting
            // acknowledgements for a payload that no longer exists.
            manifest = TransferManifest(
                transferID: request.transferID,
                chunkCount: plan.count,
                chunkSize: chunkSize,
                fingerprint: request.fingerprint
            )
        case .resumed, .nothingToResume:
            manifest = base
        }

        for descriptor in decision.chunks {
            scheduler.enqueue(
                ChunkWorkItem(
                    transferID: request.transferID,
                    descriptor: descriptor,
                    priority: request.priority
                )
            )
        }
        return decision
    }

    private func claimNextItem() -> ChunkWorkItem? {
        scheduler.next(limit: limiter.currentLimit)
    }

    /// Folds one finished request into every piece of state.
    ///
    /// No `await` anywhere in here, which is what makes it atomic with respect
    /// to other completions: an actor method with no suspension point cannot be
    /// interleaved, so the check-then-act hazard has no window to open in.
    private func settle(
        item: ChunkWorkItem,
        result: Result<ChunkReceipt, ChunkTransportError>
    ) {
        budget.recordAttempt(chunkIndex: item.descriptor.index)
        scheduler.complete(item.id)

        switch result {
        case .success(let receipt):
            limiter.observe(
                RequestSample(
                    roundTrip: receipt.roundTrip,
                    inFlight: Saturating.add(scheduler.inFlightCount, 1),
                    outcome: .completed
                )
            )
            manifest?.acknowledge(chunkIndex: receipt.chunkIndex, digest: receipt.digest)

        case .failure(let error):
            limiter.observe(
                RequestSample(
                    roundTrip: .zero,
                    inFlight: Saturating.add(scheduler.inFlightCount, 1),
                    outcome: .dropped
                )
            )

            let attempts = budget.attempts(forChunkIndex: item.descriptor.index)
            let retryable = error.disposition == .retryable
                && budget.permitsRetry(chunkIndex: item.descriptor.index, policy: policy)
                && policy.shouldRetry(attemptsSoFar: attempts, disposition: error.disposition)

            guard retryable else {
                terminalChunks.insert(item.descriptor.index)
                return
            }

            // The backoff rides on the item, so the admission loop never sleeps
            // and one slow-retrying chunk cannot stall the other 199.
            var retry = item
            retry.retryDelay = policy.delay(
                beforeAttempt: Saturating.add(attempts, 1),
                jitter: &jitter
            )
            scheduler.requeue(retry)
        }
    }

    // MARK: - The network

    /// One attempt's outcome, paired with the item it belongs to.
    private struct CompletedAttempt: Sendable {
        let item: ChunkWorkItem
        let result: Result<ChunkReceipt, ChunkTransportError>
    }

    /// Deliberately `nonisolated` and `static`: it has no access to the actor's
    /// state, so the suspensions inside it — the backoff sleep and the network
    /// call — provably cannot observe a half-updated limiter or scheduler. That
    /// is the mechanism behind the reentrancy rule above, and a reviewer can
    /// confirm the rule by grepping for `await` rather than tracing control
    /// flow: every one of them is in this function or in `upload(_:)`'s own
    /// loop, never inside a state mutation.
    private nonisolated static func perform(
        transport: any ChunkTransport,
        item: ChunkWorkItem
    ) async -> CompletedAttempt {
        if item.retryDelay > .zero {
            try? await Task.sleep(for: item.retryDelay)
        }
        do {
            let receipt = try await transport.send(
                chunk: item.descriptor,
                transferID: item.transferID
            )
            return CompletedAttempt(item: item, result: .success(receipt))
        } catch let error as ChunkTransportError {
            return CompletedAttempt(item: item, result: .failure(error))
        } catch {
            // An unexpected error is treated as a lost connection — retryable —
            // rather than terminal. Guessing "terminal" here would abandon a
            // user's upload over an error type nobody anticipated.
            return CompletedAttempt(
                item: item,
                result: .failure(
                    ChunkTransportError(
                        kind: .connectionLost,
                        chunkIndex: item.descriptor.index,
                        message: "\(error)"
                    )
                )
            )
        }
    }
}
