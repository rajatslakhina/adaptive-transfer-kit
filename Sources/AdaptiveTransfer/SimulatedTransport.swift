/// A server whose capacity is known, and can change.
///
/// This is not a mock in the usual sense — it is not there so a test can assert
/// a method was called. It is a *model*: a queueing server with a stated
/// service discipline, so that the claim "a fixed concurrency limit converts
/// excess load into invisible latency" can be demonstrated by running the real
/// control law against it rather than argued in prose.
///
/// The model, stated plainly so it can be criticised:
///
/// * The server serves at most `capacity` requests concurrently.
/// * A request issued while `inFlight <= capacity` takes `serviceTime`.
/// * A request issued while `inFlight > capacity` takes
///   `serviceTime * inFlight / capacity` — a linear queueing delay, which is
///   the standard first-order approximation and is *optimistic*: real servers
///   degrade worse than linearly under overload, so every latency number this
///   produces understates the problem.
/// * Beyond `rejectionThreshold * capacity` in flight, the server starts
///   dropping, which is what a real load shedder does.
///
/// What it deliberately does **not** model: TCP slow start, TLS handshake cost,
/// head-of-line blocking in HTTP/2, or bandwidth as distinct from concurrency.
/// Those all make the fixed-limit case worse, not better, so leaving them out
/// keeps the comparison conservative.
public struct SimulatedServer: Sendable {

    public struct CapacityChange: Sendable, Equatable {
        public let atMilliseconds: Int
        public let capacity: Int

        public init(atMilliseconds: Int, capacity: Int) {
            self.atMilliseconds = max(0, atMilliseconds)
            self.capacity = max(1, capacity)
        }
    }

    public let initialCapacity: Int
    public let serviceTimeMilliseconds: Int
    public let capacityChanges: [CapacityChange]
    public let rejectionThreshold: Double

    public init(
        initialCapacity: Int = 8,
        serviceTimeMilliseconds: Int = 40,
        capacityChanges: [CapacityChange] = [],
        rejectionThreshold: Double = 4.0
    ) {
        self.initialCapacity = max(1, initialCapacity)
        self.serviceTimeMilliseconds = max(1, serviceTimeMilliseconds)
        self.capacityChanges = capacityChanges.sorted { $0.atMilliseconds < $1.atMilliseconds }
        self.rejectionThreshold =
            rejectionThreshold.isFinite && rejectionThreshold >= 1 ? rejectionThreshold : 4.0
    }

    /// Capacity in force at `milliseconds`.
    public func capacity(atMilliseconds milliseconds: Int) -> Int {
        var current = initialCapacity
        for change in capacityChanges where change.atMilliseconds <= milliseconds {
            current = change.capacity
        }
        return current
    }

    /// Service time for a request issued at `milliseconds` with `inFlight`
    /// requests outstanding (including itself).
    public func serviceTimeMilliseconds(
        atMilliseconds milliseconds: Int,
        inFlight: Int
    ) -> Int {
        let capacity = capacity(atMilliseconds: milliseconds)
        guard inFlight > capacity else { return serviceTimeMilliseconds }
        let scaled = Double(serviceTimeMilliseconds) * Double(inFlight) / Double(capacity)
        return max(serviceTimeMilliseconds, Saturating.int(scaled.rounded(), clampedTo: 1...Int.max))
    }

    /// Whether a request issued with `inFlight` outstanding is shed.
    public func rejects(atMilliseconds milliseconds: Int, inFlight: Int) -> Bool {
        let capacity = capacity(atMilliseconds: milliseconds)
        let threshold = Double(capacity) * rejectionThreshold
        return Double(inFlight) > threshold
    }
}
