import Foundation
import FoundationModels

/// The task, as the model sees it.
///
/// Two decisions are baked into this, and both are about what a small model can
/// actually be trusted to do.
///
/// **It is asked for a judgement, not a rewrite.** The output is a one-line gist, a
/// list of line ranges to keep, and a flag. The exact strings — paths, commands,
/// error text — are kept by *quoting line ranges of the input*, not by being
/// reproduced from memory. That is the whole reason this shape was chosen over
/// "write a summary": a 3B model paraphrasing `src/agent/loop.ts` into "the agent
/// loop file" has lost the thing the reader needed, and a line range cannot.
///
/// **It is asked in the same language as the input.** The model supports Chinese,
/// and this repository's sessions are largely Chinese; an English-only instruction
/// gets English digests of Chinese output, which costs the reader twice.
enum Prompt {
    /// `useCase: .contentTagging` on the model, because the task is selecting from
    /// given content rather than composing prose, which is what that use case is
    /// tuned for.
    static let instructions = """
    You compress tool output from a coding agent so it costs fewer tokens. \
    You are given one tool result. Reply with:
    - a one-sentence gist of what it contains (in the same language as the input);
    - up to 3 line ranges to keep verbatim, written as "12-40" (1-based, inclusive). \
    Keep the lines that carry file paths, commands, test names, or error messages. \
    Keep nothing else;
    - whether the whole result is noise that a reader could lose.
    Do not invent paths, commands, or numbers. Quote them by line range instead. \
    Be terse.
    """

    /// One tool result, with the context a reader would have: which tool produced
    /// it and whether it came back as an error.
    static func input(for candidate: Candidate) -> String {
        var lines: [String] = []
        lines.append("tool: \(candidate.tool ?? "unknown")")
        if candidate.isError { lines.append("status: error") }
        if candidate.truncated {
            lines.append("note: only the first part is shown; the result is longer")
        }
        lines.append("--- output ---")
        // Numbered, because the answer refers to line ranges. Numbering is the
        // whole interface: without it the model has to count lines, which it
        // cannot do reliably.
        let body = candidate.text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in body.enumerated() {
            lines.append("\(i + 1)\t\(line)")
        }
        return lines.joined(separator: "\n")
    }
}

/// What the model is asked to produce, as a constrained schema.
///
/// `@Generable` turns this into a grammar the runtime enforces, so the output is
/// never a paragraph that has to be parsed with a regex. That is most of why the
/// Apple model is worth testing at all: the failure mode of a small model is
/// usually rambling format, and constrained decoding removes it.
@Generable
struct Digest {
    @Guide(description: "One sentence, in the language of the input.")
    var gist: String

    @Guide(description: "Up to three line ranges to keep verbatim, as in \"12-40\".")
    var keep: [String]

    @Guide(description: "True only when the entire output is noise with nothing worth keeping.")
    var noise: Bool
}
