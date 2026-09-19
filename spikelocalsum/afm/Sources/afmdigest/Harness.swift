import Foundation
import FoundationModels

// A harness for one question: is the on-device model good enough — and fast enough
// — to compress tool output before it enters the conversation?
//
// It is deliberately not wired into the app. The app's prompt is prefix-cached, so
// a digest that changes on every request costs more than it saves; the only place
// this can live is at write time, once, frozen. Whether *that* pays is what the
// numbers here decide.
//
//   swift run afmdigest --candidates ../../data/candidates.jsonl \
//                       --out ../../data/digests-afm.jsonl \
//                       --limit 50 --repeat 10

struct Args {
    var candidates = ""
    var out = ""
    var limit = 0
    var repeatCount = 0
    var useCase = "general"
    var maxInputBytes = 6144
    var verbose = false
}

func parseArgs() -> Args? {
    var args = Args()
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--candidates": i += 1; args.candidates = argv[i]
        case "--out": i += 1; args.out = argv[i]
        case "--limit": i += 1; args.limit = Int(argv[i]) ?? 0
        case "--repeat": i += 1; args.repeatCount = Int(argv[i]) ?? 0
        case "--use-case": i += 1; args.useCase = argv[i]
        case "--max-input-bytes": i += 1; args.maxInputBytes = Int(argv[i]) ?? args.maxInputBytes
        case "--verbose": args.verbose = true
        default:
            FileHandle.standardError.write("unknown argument \(arg)\n".data(using: .utf8)!)
            return nil
        }
        i += 1
    }
    if args.candidates.isEmpty || args.out.isEmpty { return nil }
    return args
}

func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}

/// Cut a candidate's text to the budget, on a line boundary, and say whether it
/// had to. This is the local model's window talking: 4,096 tokens in total, so
/// only a few kilobytes of output fit alongside the instructions and the schema.
/// A production version would size this exactly with `SystemLanguageModel.tokenCount`
/// (macOS 26.4); the spike uses a conservative constant and records the cut.
func fit(_ text: String, to limit: Int) -> (String, Bool) {
    let bytes = Array(text.utf8)
    if bytes.count <= limit { return (text, false) }
    var cut = limit
    while cut > 0 && bytes[cut - 1] != UInt8(ascii: "\n") { cut -= 1 }
    if cut == 0 { cut = limit }
    return (String(decoding: bytes[0..<cut], as: UTF8.self), true)
}

@main
struct Main {
    static func main() async {
        guard let args = parseArgs() else {
            FileHandle.standardError.write(
                "usage: afmdigest --candidates <f> --out <f> [--limit N] [--repeat N] [--use-case general|contentTagging] [--max-input-bytes N]\n"
                    .data(using: .utf8)!)
            exit(2)
        }

        let useCase: SystemLanguageModel.UseCase =
            args.useCase == "contentTagging" ? .contentTagging : .general
        // `.permissiveContentTransformations` because the job is to transform text a
        // reader already has, and the default guardrails are tuned for a
        // conversation with a person rather than for a pass over a build log.
        let model = SystemLanguageModel(useCase: useCase, guardrails: .permissiveContentTransformations)

        // Report the model's state as the first fact, before any work. Everything
        // below is meaningless if this says unavailable, and "This device does not
        // support Apple Intelligence" is the answer a reader needs rather than a
        // stream of zero-byte digests.
        FileHandle.standardError.write("model: \(model.availability)\n".data(using: .utf8)!)
        FileHandle.standardError.write("contextSize: \(model.contextSize)\n".data(using: .utf8)!)
        FileHandle.standardError.write("useCase: \(args.useCase)\n".data(using: .utf8)!)

        let candidates = try! String(contentsOfFile: args.candidates, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> Candidate? in
                try? JSONDecoder().decode(Candidate.self, from: Data(line.utf8))
            }
        var selected = candidates
        if args.limit > 0 { selected = Array(candidates.prefix(args.limit)) }
        FileHandle.standardError.write(
            "candidates: \(candidates.count), running \(selected.count)\n".data(using: .utf8)!)

        // Prewarm once, outside the timed region: the first call pays for loading
        // the model, and including that in the first candidate's latency would
        // make the numbers useless in the direction that matters.
        let warmup = LanguageModelSession(
            model: model, instructions: Prompt.instructions)
        warmup.prewarm()

        var outcomes: [Outcome] = []
        var totalMs = 0
        for (n, candidate) in selected.enumerated() {
            let (body, cut) = fit(candidate.text, to: args.maxInputBytes)
            var trimmed = candidate
            trimmed = Candidate(
                id: candidate.id, session: candidate.session, index: candidate.index,
                tool: candidate.tool, isError: candidate.isError, bytes: candidate.bytes,
                truncated: candidate.truncated || cut, text: body)

            let started = nowMs()
            do {
                let session = LanguageModelSession(
                    model: model, instructions: Prompt.instructions)
                // Greedy, because a write-time digest has to be reproducible: the
                // same result must compress to the same bytes on a rerun, or the
                // session log stops being a deterministic function of its inputs.
                let response = try await session.respond(
                    to: Prompt.input(for: trimmed),
                    generating: Digest.self,
                    options: GenerationOptions(sampling: .greedy))
                let ms = nowMs() - started
                totalMs += ms

                var repeatable: Bool? = nil
                if args.repeatCount > 0 && n < args.repeatCount {
                    // The same input again, on a fresh session. If the bytes differ
                    // the digest cannot be frozen, and freezing is the only reason
                    // this is affordable at all.
                    let again = LanguageModelSession(
                        model: model, instructions: Prompt.instructions)
                    if let second = try? await again.respond(
                        to: Prompt.input(for: trimmed),
                        generating: Digest.self,
                        options: GenerationOptions(sampling: .greedy)) {
                        repeatable = second.content.gist == response.content.gist
                            && second.content.keep == response.content.keep
                    } else {
                        repeatable = false
                    }
                }

                let text = response.content.gist
                outcomes.append(Outcome(
                    id: candidate.id, tool: candidate.tool, model: modelName(model),
                    inBytes: candidate.bytes, outBytes: text.utf8.count,
                    latencyMs: ms, ok: true, note: nil,
                    digest: text, keep: response.content.keep,
                    droppable: response.content.noise, repeatable: repeatable))
                if args.verbose {
                    FileHandle.standardError.write(
                        "  \(n + 1)/\(selected.count) \(candidate.id) \(candidate.bytes)B -> \(text.utf8.count)B in \(ms)ms\n"
                            .data(using: .utf8)!)
                }
            } catch {
                let ms = nowMs() - started
                totalMs += ms
                outcomes.append(Outcome(
                    id: candidate.id, tool: candidate.tool, model: modelName(model),
                    inBytes: candidate.bytes, outBytes: 0, latencyMs: ms,
                    ok: false, note: describe(error),
                    digest: nil, keep: nil, droppable: nil, repeatable: nil))
            }
        }

        // Write JSONL, one outcome per line, in the order run.
        var out = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for outcome in outcomes {
            let data = try! encoder.encode(outcome)
            out += String(decoding: data, as: UTF8.self) + "\n"
        }
        try! out.write(toFile: args.out, atomically: true, encoding: .utf8)

        let ok = outcomes.filter(\.ok).count
        FileHandle.standardError.write(
            "wrote \(outcomes.count) outcomes (\(ok) ok) -> \(args.out)\n".data(using: .utf8)!)
        if ok > 0 {
            FileHandle.standardError.write(
                "mean latency \(totalMs / outcomes.count) ms\n".data(using: .utf8)!)
        }
    }

    /// The model has no public name; the use case is what a reader can act on.
    static func modelName(_ model: SystemLanguageModel) -> String {
        "apple-foundation-models-ondevice"
    }

    /// A generation error, in words a reader can act on.
    ///
    /// This is the part worth writing carefully, because on-device inference fails
    /// in ways a network call does not: the window is tiny, the guardrails refuse
    /// things, and a locale may not be supported. "Something went wrong" would send
    /// someone to the wrong place.
    static func describe(_ error: Error) -> String {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return "\(error)"
        }
        switch generation {
        case .exceededContextWindowSize:
            return "exceededContextWindowSize"
        case .guardrailViolation:
            return "guardrailViolation"
        case .unsupportedLanguageOrLocale:
            return "unsupportedLanguageOrLocale"
        case .assetsUnavailable:
            return "assetsUnavailable"
        case .decodingFailure:
            return "decodingFailure"
        case .rateLimited:
            return "rateLimited"
        case .concurrentRequests:
            return "concurrentRequests"
        case .refusal:
            return "refusal"
        default:
            return "\(generation)"
        }
    }
}
