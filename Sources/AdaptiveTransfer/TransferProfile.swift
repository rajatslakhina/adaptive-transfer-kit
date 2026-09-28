/// The numbers an *app* owns, as opposed to the policy the library owns.
///
/// Chunk count, the concurrency ceiling a team would otherwise hard-code, and
/// what counts as a plausible server for a given product are product decisions
/// — how much of a metered connection this app is willing to spend, how long a
/// preemption may take. A library that baked them in would be making those
/// calls on behalf of every app that adopts it.
///
/// ## Why this lives in the core module and not in the UI one
///
/// It used to live beside `TransferDashboardView`, which was wrong for a reason
/// worth recording: everything in `AdaptiveTransferUI` is inside
/// `#if canImport(SwiftUI)`, so on Linux that module compiles to nothing and
/// the test target cannot see it. A type that decides what the demo computes
/// was therefore, structurally, a type no test could reach — and the one real
/// defect in this package's first cut was exactly there. Anything that holds a
/// decision belongs where a test can get at it; the UI module should hold only
/// the drawing.
public struct TransferProfile: Sendable, Equatable {

    public let name: String
    /// How many chunks the modelled transfer is split into.
    public let chunkCount: Int
    /// The fixed limit this app would otherwise have hard-coded.
    public let fixedLimit: Int
    /// The server's usable concurrency before it degrades.
    public let serverCapacity: Int
    /// Base service time per request, with no queueing.
    public let serviceTimeMilliseconds: Int
    /// When the server's capacity collapses.
    ///
    /// Early on purpose. A drop near the end of a transfer is real but
    /// uninteresting — most of the work has already completed at full capacity,
    /// so it barely moves the aggregate, and the percentiles end up describing
    /// a regime the user never sat through. Worse, if it lands *after* the
    /// transfer would have finished, it never happens at all, and every control
    /// that changes its severity silently stops doing anything.
    public let degradeAtMilliseconds: Int

    public init(
        name: String,
        chunkCount: Int = 300,
        fixedLimit: Int = 8,
        serverCapacity: Int = 8,
        serviceTimeMilliseconds: Int = 40,
        degradeAtMilliseconds: Int = 200
    ) {
        self.name = name
        // Bounded for the same reason `CapacityExperiment.Scenario` is: the
        // simulation materialises one element per chunk.
        self.chunkCount = min(
            max(1, chunkCount),
            CapacityExperiment.Scenario.maximumChunkCount
        )
        self.fixedLimit = max(1, fixedLimit)
        self.serverCapacity = max(1, serverCapacity)
        self.serviceTimeMilliseconds = max(1, serviceTimeMilliseconds)
        self.degradeAtMilliseconds = max(0, degradeAtMilliseconds)
    }

    public static let photoUpload = TransferProfile(name: "Photo upload")

    /// The range a UI control may move the degraded capacity over.
    public var degradedCapacityRange: ClosedRange<Int> { 1...max(2, serverCapacity) }

    /// A sensible starting point for that control: a genuine collapse, not a
    /// graze.
    public var defaultDegradedCapacity: Int {
        min(max(1, serverCapacity / 4), degradedCapacityRange.upperBound)
    }

    /// Runs both strategies against this profile with the server degrading to
    /// `degradedCapacity`.
    public func compare(degradedCapacity: Int) -> CapacityExperiment.Comparison {
        let capacity = min(
            max(degradedCapacity, degradedCapacityRange.lowerBound),
            degradedCapacityRange.upperBound
        )
        return CapacityExperiment.compare(
            scenario: CapacityExperiment.Scenario(
                chunkCount: chunkCount,
                server: SimulatedServer(
                    initialCapacity: serverCapacity,
                    serviceTimeMilliseconds: serviceTimeMilliseconds,
                    capacityChanges: [
                        .init(atMilliseconds: degradeAtMilliseconds, capacity: capacity)
                    ]
                )
            ),
            fixedLimit: fixedLimit
        )
    }

    /// How a comparison should be read, in one sentence.
    ///
    /// Deliberately honest in both directions. At mild degradation a fixed
    /// limit that happens to be close to the truth really does win, and a demo
    /// that hid that would be a sales pitch rather than a measurement. The
    /// argument was never "adaptive is always faster" — it is that nobody can
    /// know in advance which of these rows they are in.
    public enum Verdict: String, Sendable, Equatable {
        /// The fixed limit did not finish the transfer.
        case fixedLimitCollapsed
        /// The controller's tail latency is materially better.
        case adaptiveWins
        /// The fixed guess happened to be close enough to beat the probing cost.
        case fixedGuessHappenedToBeRight
    }

    public func verdict(for comparison: CapacityExperiment.Comparison) -> Verdict {
        if comparison.fixed.completedChunks < chunkCount { return .fixedLimitCollapsed }
        return comparison.p95Ratio > 1.05 ? .adaptiveWins : .fixedGuessHappenedToBeRight
    }
}
