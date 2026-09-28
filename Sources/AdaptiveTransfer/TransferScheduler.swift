/// How urgent a chunk is.
public enum TransferPriority: Int, Sendable, Comparable, CaseIterable, Codable {
    /// Somebody is looking at a progress bar right now.
    case interactive = 0
    /// Backfill. Nobody is waiting; it must still finish.
    case background = 1

    public static func < (lhs: TransferPriority, rhs: TransferPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One admission-ready unit of work.
public struct ChunkWorkItem: Sendable, Equatable, Hashable, Identifiable {
    public struct ID: Sendable, Equatable, Hashable {
        public let transferID: String
        public let chunkIndex: Int
        public init(transferID: String, chunkIndex: Int) {
            self.transferID = transferID
            self.chunkIndex = chunkIndex
        }
    }

    public let transferID: String
    public let descriptor: ChunkDescriptor
    public let priority: TransferPriority
    /// How many admission rounds this item has been passed over. Drives aging.
    public internal(set) var passedOver: Int = 0
    /// How long the worker must back off before sending this attempt.
    ///
    /// Carried on the item rather than slept for in the admission loop, so a
    /// chunk that is backing off does not stall admission of every other chunk.
    /// It does keep its admission slot while it waits, which is deliberate: a
    /// backing-off chunk reducing the offered load during a failure episode is
    /// free backpressure, and the alternative — releasing the slot, admitting
    /// fresh work, then contending again on retry — offers the *most* load
    /// exactly when the path is least able to absorb it.
    public internal(set) var retryDelay: Duration = .zero

    public var id: ID { ID(transferID: transferID, chunkIndex: descriptor.index) }

    public init(
        transferID: String,
        descriptor: ChunkDescriptor,
        priority: TransferPriority
    ) {
        self.transferID = transferID
        self.descriptor = descriptor
        self.priority = priority
    }
}

/// Decides which chunk goes next, given how many may be in flight.
///
/// Admission and capacity are kept apart on purpose. `ConcurrencyLimiter`
/// answers *how many*; this type answers *which*. Fusing them — the usual
/// shape, a priority queue that also knows the limit — makes it impossible to
/// test either decision in isolation, and makes swapping the control law a
/// change to the scheduler.
///
/// ## Preemption without losing work
///
/// An interactive transfer that arrives behind 400 queued background chunks has
/// to go first. The tempting implementation cancels in-flight background
/// requests to free a slot immediately, and it is the wrong one: a cancelled
/// chunk is bytes already pushed across a metered connection that must be
/// pushed again. On a cellular link that is the user's data and the user's
/// battery, spent twice, to save a few hundred milliseconds.
///
/// So preemption here is **by admission, not by cancellation**. An interactive
/// item wins every free slot from the moment it is enqueued, but nothing
/// already in flight is touched. The cost is bounded and stated: the
/// interactive item waits at most one background chunk's service time. That is
/// the real argument for keeping chunks small — chunk size *is* the preemption
/// latency, which is not obvious from looking at either type alone.
///
/// ## Starvation
///
/// Strict priority starves background work forever under a steady interactive
/// stream — a photo-library backfill that never advances while the user keeps
/// sharing. So items age: once a background item has been passed over
/// `agingThreshold` times it is promoted ahead of interactive work for one
/// admission. That is a deliberate, bounded fairness leak, and the trade-off is
/// explicit — with `agingThreshold` of 32 an interactive transfer yields at most
/// one slot in 33 to backfill.
///
/// ## Fairness across transfers
///
/// Within a priority class, admission round-robins across transfer IDs rather
/// than draining one transfer at a time. Strict FIFO means a 4,000-chunk video
/// blocks a 3-chunk thumbnail set that was enqueued one millisecond later, and
/// both are "background", so priority cannot help.
public struct TransferScheduler: Sendable {

    public struct Configuration: Sendable {
        /// Passes over a background item before it is promoted once.
        public var agingThreshold: Int
        /// Hard cap on queued items. Enqueue beyond this is rejected.
        public var maximumQueuedItems: Int

        public init(agingThreshold: Int = 32, maximumQueuedItems: Int = 16_384) {
            self.agingThreshold = max(1, agingThreshold)
            self.maximumQueuedItems = max(1, maximumQueuedItems)
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    /// Queued items per priority, each a FIFO list per transfer ID, plus the
    /// round-robin cursor over transfer IDs.
    private var queues: [TransferPriority: PriorityQueue] = [:]
    private var inFlight: Set<ChunkWorkItem.ID> = []

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        for priority in TransferPriority.allCases {
            queues[priority] = PriorityQueue()
        }
    }

    public var queuedCount: Int {
        queues.values.reduce(0) { Saturating.add($0, $1.count) }
    }

    public var inFlightCount: Int { inFlight.count }

    /// Enqueues `item`. Returns `false` if the queue is at its cap or the item
    /// is already queued or in flight.
    ///
    /// The cap is the bound on this type's memory. Without it, a caller that
    /// enqueues a plan on every retry — an easy mistake — grows the queue
    /// without limit, and the failure looks like a memory leak rather than a
    /// scheduling bug.
    @discardableResult
    public mutating func enqueue(_ item: ChunkWorkItem) -> Bool {
        guard queuedCount < configuration.maximumQueuedItems else { return false }
        guard !inFlight.contains(item.id) else { return false }
        guard var queue = queues[item.priority] else { return false }
        guard !queue.contains(item.id) else { return false }
        queue.append(item)
        queues[item.priority] = queue
        return true
    }

    /// Picks the next item to run, or `nil` if none may start.
    ///
    /// `limit` comes from the `ConcurrencyLimiter`; it is read fresh on every
    /// call rather than captured, because it changes underneath a long transfer
    /// and a stale copy is exactly the bug the limiter exists to prevent.
    public mutating func next(limit: Int) -> ChunkWorkItem? {
        guard inFlight.count < max(1, limit) else { return nil }

        // Aging first: a background item that has waited long enough outranks
        // interactive work for exactly one admission.
        if let aged = takeAgedItem() {
            inFlight.insert(aged.id)
            return aged
        }

        for priority in TransferPriority.allCases.sorted() {
            guard var queue = queues[priority], !queue.isEmpty else { continue }
            guard let item = queue.popRoundRobin() else { continue }
            queues[priority] = queue
            markPassedOver(below: priority)
            inFlight.insert(item.id)
            return item
        }
        return nil
    }

    /// Releases the slot held by `id`.
    ///
    /// Idempotent: releasing an unknown id is a no-op rather than a
    /// precondition failure, because a retry path that double-releases would
    /// otherwise crash the app over an accounting mistake.
    public mutating func complete(_ id: ChunkWorkItem.ID) {
        inFlight.remove(id)
    }

    /// Re-queues `item` after a retryable failure, preserving its age.
    @discardableResult
    public mutating func requeue(_ item: ChunkWorkItem) -> Bool {
        inFlight.remove(item.id)
        return enqueue(item)
    }

    private mutating func takeAgedItem() -> ChunkWorkItem? {
        guard var queue = queues[.background], !queue.isEmpty else { return nil }
        guard queue.hasItemPassedOver(atLeast: configuration.agingThreshold) else { return nil }
        guard let item = queue.popFirstPassedOver(atLeast: configuration.agingThreshold) else {
            return nil
        }
        queues[.background] = queue
        return item
    }

    private mutating func markPassedOver(below priority: TransferPriority) {
        for lower in TransferPriority.allCases where lower > priority {
            queues[lower]?.incrementPassedOver()
        }
    }

    /// FIFO per transfer ID, with a round-robin cursor across transfer IDs.
    private struct PriorityQueue: Sendable {
        private var order: [String] = []
        private var lanes: [String: [ChunkWorkItem]] = [:]
        private var cursor: Int = 0

        var count: Int { lanes.values.reduce(0) { Saturating.add($0, $1.count) } }
        var isEmpty: Bool { count == 0 }

        func contains(_ id: ChunkWorkItem.ID) -> Bool {
            lanes[id.transferID]?.contains(where: { $0.id == id }) ?? false
        }

        mutating func append(_ item: ChunkWorkItem) {
            if lanes[item.transferID] == nil {
                lanes[item.transferID] = []
                order.append(item.transferID)
            }
            lanes[item.transferID]?.append(item)
        }

        /// Pops from the lane the cursor points at, then advances. Empty lanes
        /// are pruned so the cursor cannot walk forever over dead transfers.
        mutating func popRoundRobin() -> ChunkWorkItem? {
            guard !order.isEmpty else { return nil }
            // Bounded by the number of lanes, so this cannot spin.
            for _ in 0..<order.count {
                guard !order.isEmpty else { return nil }
                let index = Saturating.remainder(cursor, order.count)
                guard index >= 0, index < order.count else { cursor = 0; continue }
                let laneID = order[index]
                if var lane = lanes[laneID], !lane.isEmpty {
                    let item = lane.removeFirst()
                    if lane.isEmpty {
                        lanes[laneID] = nil
                        order.remove(at: index)
                        cursor = order.isEmpty ? 0 : Saturating.remainder(index, max(1, order.count))
                    } else {
                        lanes[laneID] = lane
                        cursor = Saturating.remainder(Saturating.add(index, 1), order.count)
                    }
                    return item
                }
                lanes[laneID] = nil
                order.remove(at: index)
                cursor = order.isEmpty ? 0 : Saturating.remainder(index, max(1, order.count))
            }
            return nil
        }

        mutating func incrementPassedOver() {
            for laneID in order {
                guard var lane = lanes[laneID] else { continue }
                for i in lane.indices {
                    lane[i].passedOver = Saturating.add(lane[i].passedOver, 1)
                }
                lanes[laneID] = lane
            }
        }

        func hasItemPassedOver(atLeast threshold: Int) -> Bool {
            lanes.values.contains { $0.contains { $0.passedOver >= threshold } }
        }

        mutating func popFirstPassedOver(atLeast threshold: Int) -> ChunkWorkItem? {
            for laneID in order {
                guard var lane = lanes[laneID] else { continue }
                guard let position = lane.firstIndex(where: { $0.passedOver >= threshold })
                else { continue }
                var item = lane.remove(at: position)
                item.passedOver = 0
                if lane.isEmpty {
                    lanes[laneID] = nil
                    if let orderIndex = order.firstIndex(of: laneID) {
                        order.remove(at: orderIndex)
                    }
                    cursor = 0
                } else {
                    lanes[laneID] = lane
                }
                return item
            }
            return nil
        }
    }
}
