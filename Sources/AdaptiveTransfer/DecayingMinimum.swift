/// A minimum that is allowed to forget.
///
/// A latency-gradient controller compares the round-trip time it is seeing now
/// against the round-trip time it sees when nothing is queued. Getting that
/// second number right is the hard part, and the naive answer — "keep the
/// smallest RTT ever observed" — fails in a specific, nasty way: one lucky
/// 8 ms sample on a warm connection pins the floor forever, so when the device
/// moves to a network whose genuine floor is 60 ms the controller reads a
/// gradient of 0.13, decides it is catastrophically congested, and collapses
/// the limit to the floor for the rest of the process's life. Throughput goes
/// to almost nothing and no error is ever logged.
///
/// So the held minimum decays upward. Any lower sample replaces it
/// immediately (congestion relief must be recognised at once), but every
/// `decayInterval` samples the held value is multiplied by `decayFactor`, so a
/// stale floor drifts back toward current conditions on its own.
///
/// **Rejected alternative:** a sliding window of the last N samples, which is
/// what a textbook implementation does. It costs O(N) memory *per transfer*,
/// and — the reason it was actually rejected — it does not solve the problem
/// any better. A 200-sample window still holds a 3-minute-old floor on a slow
/// link, and shrinking the window to fix that makes the floor noisy, which
/// shows up as limit oscillation. Decay gives a single tunable that trades
/// staleness against stability with one `Double` of state.
public struct DecayingMinimum: Sendable {

    /// How much the held minimum is inflated each decay step. Must be `> 1`.
    public let decayFactor: Double
    /// How many samples pass between decay steps. Must be `>= 1`.
    public let decayInterval: Int
    /// Value reported before any sample has arrived.
    public let initialValue: Double

    private var held: Double
    private var samplesSinceDecay: Int = 0
    private var hasSample: Bool = false

    public init(
        initialValue: Double,
        decayFactor: Double = 1.05,
        decayInterval: Int = 50
    ) {
        self.initialValue = initialValue.isFinite && initialValue > 0 ? initialValue : 1
        self.decayFactor = decayFactor.isFinite && decayFactor > 1 ? decayFactor : 1.05
        self.decayInterval = max(1, decayInterval)
        self.held = self.initialValue
    }

    /// The current estimate of the no-load value.
    public var value: Double { held }

    /// True once at least one sample has been folded in.
    public var isPrimed: Bool { hasSample }

    /// Offer a new observation.
    public mutating func offer(_ candidate: Double) {
        guard candidate.isFinite, candidate > 0 else { return }

        if !hasSample || candidate < held {
            held = candidate
            hasSample = true
            samplesSinceDecay = 0
            return
        }

        samplesSinceDecay = Saturating.add(samplesSinceDecay, 1)
        guard samplesSinceDecay >= decayInterval else { return }
        samplesSinceDecay = 0

        let decayed = held * decayFactor
        // The decayed floor is never allowed past the sample that is
        // currently keeping it honest; otherwise a long run of slow samples
        // ratchets the floor up past reality and the gradient reads 1.0
        // forever, which silently disables the controller.
        held = decayed.isFinite ? min(decayed, candidate) : candidate
    }
}
