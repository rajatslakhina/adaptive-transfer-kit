/// A content address for a chunk.
///
/// ## Why not `Hasher`
///
/// The obvious implementation is `hashValue` or `Hasher`, and it is wrong for
/// anything durable. Swift's `Hasher` is seeded per process, so the same bytes
/// hash to different values across two launches of the same app. A manifest
/// written before a crash and read after relaunch would therefore report every
/// chunk as changed, and the whole point of resumption is lost.
///
/// The bug is close to invisible, because the test that would catch it is the
/// test nobody writes: hashing the same bytes twice *inside one process* and
/// asserting the results match passes for `Hasher` too. It has to be checked
/// against constants fixed outside the process — see
/// `ContentDigestTests.testDigestMatchesGoldenVectors`.
///
/// FNV-1a/64 is specified here instead: no seed, no platform variance, and
/// cheap enough to run over a 1 MiB chunk on the upload path. It is not a
/// cryptographic hash and is not used as one — its job is to notice that a
/// file changed under a resumed transfer, not to resist an adversary. Where
/// integrity against tampering matters the server's own checksum is
/// authoritative; `ChunkTransport` carries the digest so a server that
/// verifies can reject a mismatch.
public struct ContentDigest: Sendable, Equatable, Hashable, Codable,
                             CustomStringConvertible {

    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// FNV-1a/64 over `bytes`.
    public init<Bytes: Sequence>(hashing bytes: Bytes) where Bytes.Element == UInt8 {
        var hash = Self.offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            // Unsigned multiplication overflow is the algorithm, so `&*` is
            // correct here and is not a suppressed trap.
            hash = hash &* Self.prime
        }
        self.value = hash
    }

    public var description: String {
        // 16 lowercase hex digits, stable across platforms.
        String(value, radix: 16).leftPadded(to: 16, with: "0")
    }
}

extension String {
    fileprivate func leftPadded(to width: Int, with pad: Character) -> String {
        guard count < width else { return self }
        return String(repeating: pad, count: width - count) + self
    }
}
