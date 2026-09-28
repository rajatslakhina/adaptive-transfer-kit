/// One unit of transferable work.
public struct ChunkDescriptor: Sendable, Equatable, Hashable, Codable {
    /// Position in the plan. Also the resumption key.
    public let index: Int
    /// Byte offset into the source.
    public let offset: Int
    /// Length in bytes. Always `> 0`.
    public let byteCount: Int

    /// Clamps its inputs rather than trusting them.
    ///
    /// This initializer is public and the type is `Codable`, so its arguments
    /// can arrive from a decoded manifest written by an older build or a
    /// different process — not only from `ChunkPlanner`. Without the clamp a
    /// negative `byteCount` produces a `Range` whose `lowerBound` exceeds its
    /// `upperBound`, and `Range.init` traps on that. Saturating the arithmetic
    /// is not enough on its own when the saturated result is then handed to a
    /// type with its own precondition.
    public init(index: Int, offset: Int, byteCount: Int) {
        self.index = max(0, index)
        self.offset = max(0, offset)
        self.byteCount = max(0, byteCount)
    }

    /// Byte range, half-open. Never trapping: `byteCount` is non-negative by
    /// construction and the upper bound saturates rather than overflowing, so
    /// `lowerBound <= upperBound` always holds.
    public var range: Range<Int> {
        let upper = Saturating.add(offset, byteCount)
        return offset..<max(offset, upper)
    }
}

/// Splits a payload into chunks, and decides how big a chunk should be.
///
/// The chunk size is the single parameter that ties together three things that
/// pull in different directions, which is why it gets its own type rather than
/// being a constant at the call site:
///
/// * **Resumption granularity.** Work lost to a dropped connection is bounded
///   by one chunk, so smaller is better for a flaky network.
/// * **Per-request overhead.** Every chunk is a request: TLS resumption,
///   headers, a server-side write, an acknowledgement. Smaller means the
///   fixed cost dominates.
/// * **Control-loop resolution.** The limiter learns from completed requests.
///   A transfer split into three chunks produces three samples and the
///   controller never converges; a transfer split into three hundred gives it
///   room to find capacity. This is the consideration teams miss, and it
///   argues for *more* chunks than overhead alone would suggest.
///
/// The planner also refuses to produce an unbounded number of chunks. A
/// 40 GB file at a 256 KB chunk size is 160,000 descriptors, and holding that
/// plan plus its acknowledgement set in memory for several concurrent
/// transfers is how a background upload gets killed by the watchdog. Past
/// `maximumChunkCount` the chunk size grows instead of the chunk count, and
/// the resumption granularity degrades gracefully rather than the process
/// dying.
public struct ChunkPlanner: Sendable {

    public struct Configuration: Sendable {
        public var preferredChunkSize: Int
        public var minimumChunkSize: Int
        public var maximumChunkCount: Int

        public init(
            preferredChunkSize: Int = 1 << 20,   // 1 MiB
            minimumChunkSize: Int = 64 << 10,    // 64 KiB
            maximumChunkCount: Int = 4096
        ) {
            self.minimumChunkSize = max(1, minimumChunkSize)
            self.preferredChunkSize = max(self.minimumChunkSize, preferredChunkSize)
            self.maximumChunkCount = max(1, maximumChunkCount)
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// The chunk size actually used for a payload of `totalBytes`.
    ///
    /// Grows past `preferredChunkSize` only when the preferred size would
    /// exceed `maximumChunkCount`.
    public func chunkSize(forTotalBytes totalBytes: Int) -> Int {
        guard totalBytes > 0 else { return configuration.preferredChunkSize }
        let preferred = configuration.preferredChunkSize
        let countAtPreferred = Saturating.ceilingDivide(totalBytes, by: preferred)
        guard countAtPreferred > configuration.maximumChunkCount else { return preferred }
        let grown = Saturating.ceilingDivide(totalBytes, by: configuration.maximumChunkCount)
        return max(grown, preferred)
    }

    /// Splits `totalBytes` into descriptors.
    ///
    /// A zero-byte payload produces an empty plan rather than one empty chunk:
    /// a chunk with no bytes has nothing to acknowledge, and the callers that
    /// treat "no chunks left" as done would otherwise never finish. A negative
    /// count — which can only arrive from an overflowed size calculation
    /// upstream — is also an empty plan.
    public func plan(totalBytes: Int) -> [ChunkDescriptor] {
        guard totalBytes > 0 else { return [] }

        let size = chunkSize(forTotalBytes: totalBytes)
        guard size > 0 else { return [] }

        let count = Saturating.ceilingDivide(totalBytes, by: size)
        guard count > 0, count <= configuration.maximumChunkCount else {
            // Unreachable given `chunkSize(forTotalBytes:)`, which is exactly
            // why it is asserted rather than assumed: if that invariant is
            // ever broken by a future edit, this returns an empty plan (the
            // transfer reports "nothing to do") instead of allocating a
            // multi-million-element array.
            assertionFailure("chunkSize(forTotalBytes:) produced \(count) chunks")
            return []
        }

        var descriptors: [ChunkDescriptor] = []
        descriptors.reserveCapacity(count)
        var offset = 0
        var index = 0
        while offset < totalBytes {
            let remaining = Saturating.subtract(totalBytes, offset)
            let byteCount = min(size, remaining)
            guard byteCount > 0 else { break }   // cannot happen; cannot loop forever either
            descriptors.append(
                ChunkDescriptor(index: index, offset: offset, byteCount: byteCount)
            )
            offset = Saturating.add(offset, byteCount)
            index = Saturating.add(index, 1)
        }
        return descriptors
    }
}
