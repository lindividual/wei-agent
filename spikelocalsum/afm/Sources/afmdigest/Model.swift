import Foundation

/// One tool result offered for compression, as `corpus.py` wrote it.
struct Candidate: Decodable {
    let id: String
    let session: String
    let index: Int
    let tool: String?
    let isError: Bool
    let bytes: Int
    let truncated: Bool
    let text: String

    enum CodingKeys: String, CodingKey {
        case id, session, index, tool, bytes, truncated, text
        case isError = "is_error"
    }
}

/// What the harness writes back for one candidate.
///
/// The shape is the contract with `score.py`, and it is deliberately the shape a
/// real implementation would store: the digest, the line ranges to keep verbatim,
/// and how long the call took. `score.py` scores the digest text; a real
/// implementation would use `keep` to assemble the pyresult from the original
/// bytes, which is what makes the exact strings exact.
struct Outcome: Encodable {
    let id: String
    let tool: String?
    let model: String
    let inBytes: Int
    let outBytes: Int
    let latencyMs: Int
    let ok: Bool
    let note: String?
    /// The one-line gist, if the model produced one.
    let digest: String?
    /// Line ranges (1-based, inclusive) worth keeping verbatim.
    let keep: [String]?
    /// True when the model judged the whole result to be noise.
    let droppable: Bool?
    /// A byte-identical rerun of the same input, to see whether a frozen digest is
    /// even reproducible — which is what a write-time reduction needs.
    let repeatable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, tool, model, digest, keep, droppable, repeatable, ok, note
        case inBytes = "in_bytes"
        case outBytes = "out_bytes"
        case latencyMs = "latency_ms"
    }
}

extension Outcome {
    /// The text `score.py` grades, if it wants to grade recall against anything but
    /// `digest`. Keeping both makes the two readings comparable.
    var flatDigest: String { digest ?? "" }
}
