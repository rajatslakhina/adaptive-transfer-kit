/// Why a chunk upload failed.
public struct ChunkTransportError: Error, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The server said "later" — 429, 503, a connection reset.
        case throttled
        /// Network went away mid-request.
        case connectionLost
        /// The request took longer than the transport was willing to wait.
        case timedOut
        /// The server rejected this chunk and will keep rejecting it — a bad
        /// range, a digest mismatch, a 4xx that is not 429.
        case rejected
        /// The source could not be read.
        case sourceUnreadable
    }

    public let kind: Kind
    public let chunkIndex: Int
    public let message: String

    public init(kind: Kind, chunkIndex: Int, message: String = "") {
        self.kind = kind
        self.chunkIndex = chunkIndex
        self.message = message
    }

    /// Whether retrying this chunk could plausibly succeed.
    ///
    /// The mapping is the whole point of having this type: `URLError` and an
    /// HTTP status code do not agree on what is retryable, and getting it
    /// wrong in either direction is expensive. Retrying a `.rejected` chunk
    /// burns the budget on a request that will never succeed; giving up on a
    /// `.throttled` one fails a transfer the server explicitly asked us to
    /// defer.
    public var disposition: FailureDisposition {
        switch kind {
        case .throttled, .connectionLost, .timedOut:
            return .retryable
        case .rejected, .sourceUnreadable:
            return .terminal
        }
    }
}

/// What the server said about a chunk.
public struct ChunkReceipt: Sendable, Equatable {
    public let chunkIndex: Int
    public let digest: ContentDigest
    /// Measured round trip, fed straight into the limiter.
    public let roundTrip: Duration

    public init(chunkIndex: Int, digest: ContentDigest, roundTrip: Duration) {
        self.chunkIndex = chunkIndex
        self.digest = digest
        self.roundTrip = roundTrip
    }
}

/// The one seam between the policy core and the network.
///
/// Everything above this protocol — the limiter, the scheduler, the planner,
/// the retry budget, the coordinator — has no idea `URLSession` exists, which
/// is what allows the entire control loop to be exercised deterministically by
/// `SimulatedTransport` and the whole capacity experiment to run in CI on Linux
/// with no network at all.
///
/// It is deliberately one method. A wider seam (`prepare`, `send`, `finalise`,
/// `abort`) reads more complete and buys nothing: every extra requirement is a
/// requirement each conformance has to satisfy correctly, and the resumption
/// state that a `finalise` step would carry already lives in `TransferManifest`
/// where it can be persisted.
public protocol ChunkTransport: Sendable {
    /// Sends one chunk and returns what the server said.
    ///
    /// Implementations must measure and report the round trip themselves —
    /// timing it in the coordinator would include the time the task spent
    /// waiting to be scheduled by the cooperative pool, which is not a
    /// property of the network and would make the limiter shrink in response
    /// to its own queueing.
    func send(
        chunk: ChunkDescriptor,
        transferID: String
    ) async throws -> ChunkReceipt
}
