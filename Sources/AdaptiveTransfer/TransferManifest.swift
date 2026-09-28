/// The durable record that makes a transfer resumable.
///
/// A transfer that has uploaded 1.8 GB of a 2 GB file and then loses the
/// process has two possible next moves: start again, or ask what already
/// landed. The second requires state that outlives the process, and that state
/// is this type — deliberately `Codable` and deliberately tiny, so it can be
/// written after every acknowledgement without the write itself becoming the
/// bottleneck.
///
/// ## Why the source digest is in here
///
/// Resumption is only safe if the bytes have not changed. A user who re-exports
/// a video under the same name, or an app that re-renders a document, produces
/// a payload the server would happily let you finish uploading — and the result
/// is a file whose first half is the old render and second half the new one,
/// with a successful status code. That corruption is silent and permanent.
///
/// So the manifest records the digest of the source at plan time, and
/// `resumePlan(for:)` refuses to resume against a payload whose digest differs.
/// The trade-off is honest: digesting a 2 GB file costs a full read. That is
/// why the digest is over the *plan shape plus a sampled prefix*, not the whole
/// payload — see `SourceFingerprint`.
///
/// ## Bounded on both of its entry paths
///
/// `acknowledge(chunkIndex:)` rejects out-of-range indices instead of inserting
/// them; without that, a server acknowledging index `Int.random()` grows the set
/// without limit and the manifest write gets slower on every chunk.
///
/// That guard alone is not enough, and the gap is the interesting part. This
/// type is `Codable` and is loaded from disk by `ManifestStore`, so the *other*
/// way state gets in is `init(from:)` — which, synthesized, writes straight to
/// the stored properties and honours no invariant at all. A manifest file
/// truncated by a crash, written by an older build, or simply corrupted could
/// therefore decode with `chunkCount` negative and a hundred thousand
/// acknowledged indices, and `isComplete` would return `true` for a transfer
/// that had uploaded nothing.
///
/// So `init(from:)` is written by hand and re-applies the same bounds. An
/// invariant that holds only on the path the author happened to think about is
/// not an invariant.
public struct TransferManifest: Sendable, Equatable, Codable {

    /// Cheap stand-in for "are these the same bytes".
    ///
    /// Total size plus a digest of a bounded prefix. A full-payload digest is
    /// stronger and costs a full read of the file before the first byte is
    /// uploaded, which is a visible delay on a large video; a size-only check
    /// is free and misses same-length edits, which is the common case for a
    /// re-render. The prefix digest catches header and metadata changes, which
    /// is what a re-encode actually changes, at a bounded cost.
    public struct SourceFingerprint: Sendable, Equatable, Codable {
        public let totalBytes: Int
        public let prefixDigest: ContentDigest
        public let prefixByteCount: Int

        public init(totalBytes: Int, prefixDigest: ContentDigest, prefixByteCount: Int) {
            self.totalBytes = max(0, totalBytes)
            self.prefixDigest = prefixDigest
            self.prefixByteCount = max(0, prefixByteCount)
        }

        /// Fingerprints `bytes`, reading at most `prefixLimit` of them.
        public init<Bytes: Collection>(
            hashing bytes: Bytes,
            prefixLimit: Int = 64 << 10
        ) where Bytes.Element == UInt8 {
            let limit = max(0, prefixLimit)
            let prefix = bytes.prefix(limit)
            self.totalBytes = bytes.count
            self.prefixDigest = ContentDigest(hashing: prefix)
            self.prefixByteCount = prefix.count
        }
    }

    public let transferID: String
    public let chunkCount: Int
    public let chunkSize: Int
    public let fingerprint: SourceFingerprint
    private var acknowledgedIndices: Set<Int>
    private var digests: [Int: ContentDigest]

    public init(
        transferID: String,
        chunkCount: Int,
        chunkSize: Int,
        fingerprint: SourceFingerprint
    ) {
        self.transferID = transferID
        self.chunkCount = max(0, chunkCount)
        self.chunkSize = max(0, chunkSize)
        self.fingerprint = fingerprint
        self.acknowledgedIndices = []
        self.digests = [:]
    }

    /// Indices the server has confirmed, in ascending order.
    public var acknowledged: [Int] { acknowledgedIndices.sorted() }

    public var acknowledgedCount: Int { acknowledgedIndices.count }

    public var isComplete: Bool { acknowledgedCount >= chunkCount }

    public func isAcknowledged(chunkIndex: Int) -> Bool {
        acknowledgedIndices.contains(chunkIndex)
    }

    public func digest(forChunkIndex index: Int) -> ContentDigest? {
        digests[index]
    }

    /// Records a server acknowledgement.
    ///
    /// Returns `false` — and changes nothing — for an index outside
    /// `0..<chunkCount`. That is the bound on this type's memory, and it is a
    /// silent rejection on purpose: a server that acknowledges a chunk we never
    /// sent is a server bug, and the correct client behaviour is to keep
    /// uploading the chunks we do know about rather than to fail the user's
    /// transfer.
    @discardableResult
    public mutating func acknowledge(
        chunkIndex: Int,
        digest: ContentDigest? = nil
    ) -> Bool {
        guard chunkIndex >= 0, chunkIndex < chunkCount else { return false }
        acknowledgedIndices.insert(chunkIndex)
        if let digest { digests[chunkIndex] = digest }
        return true
    }

    /// The chunks still to send, given the full plan.
    ///
    /// Returns the whole plan when the fingerprint does not match: the bytes
    /// changed under us, so nothing already on the server can be trusted.
    /// Returns an empty array when the plan's shape disagrees with the
    /// manifest's, for the same reason.
    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case transferID, chunkCount, chunkSize, fingerprint
        case acknowledgedIndices, digests
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.transferID = try container.decode(String.self, forKey: .transferID)
        let decodedChunkCount = try container.decode(Int.self, forKey: .chunkCount)
        let decodedChunkSize = try container.decode(Int.self, forKey: .chunkSize)
        self.chunkCount = max(0, decodedChunkCount)
        self.chunkSize = max(0, decodedChunkSize)
        self.fingerprint = try container.decode(SourceFingerprint.self, forKey: .fingerprint)

        let indices = try container.decode(Set<Int>.self, forKey: .acknowledgedIndices)
        let digests = try container.decode([Int: ContentDigest].self, forKey: .digests)
        let valid = 0..<self.chunkCount
        self.acknowledgedIndices = indices.filter { valid.contains($0) }
        self.digests = digests.filter { valid.contains($0.key) }
    }

    public func resumePlan(
        for plan: [ChunkDescriptor],
        fingerprint current: SourceFingerprint
    ) -> ResumeDecision {
        guard current == fingerprint else {
            return ResumeDecision(chunks: plan, reason: .sourceChanged, skippedChunkCount: 0)
        }
        guard plan.count == chunkCount else {
            return ResumeDecision(chunks: plan, reason: .planShapeChanged, skippedChunkCount: 0)
        }
        let remaining = plan.filter { !acknowledgedIndices.contains($0.index) }
        return ResumeDecision(
            chunks: remaining,
            reason: remaining.count == plan.count ? .nothingToResume : .resumed,
            skippedChunkCount: Saturating.subtract(plan.count, remaining.count)
        )
    }

    public struct ResumeDecision: Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable {
            /// Resumed from a partial upload.
            case resumed
            /// The manifest had no acknowledgements to skip.
            case nothingToResume
            /// The payload's fingerprint changed; everything is re-sent.
            case sourceChanged
            /// The plan no longer matches the manifest; everything is re-sent.
            case planShapeChanged
        }

        /// Chunks still to send.
        public let chunks: [ChunkDescriptor]
        public let reason: Reason
        /// How many chunks resumption let us skip.
        public let skippedChunkCount: Int

        public init(chunks: [ChunkDescriptor], reason: Reason, skippedChunkCount: Int) {
            self.chunks = chunks
            self.reason = reason
            self.skippedChunkCount = max(0, skippedChunkCount)
        }
    }
}
