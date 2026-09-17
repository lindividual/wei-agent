import Foundation

/// Where a markdown picture's bytes come from, worked out from the target the model wrote.
///
/// **This is not the policy.** What may be drawn at all is decided once, in `md/walk.mbt`, and what
/// arrives here has already passed that test: an absolute path, a local `file:` URL, a `data:` URL
/// the parser vouched for, or `http(s)`. Asking the same question twice is how two answers get out of
/// step, and this repo has that failure written down — the host's own format list alongside the
/// shell's — which is why this side only works out *which of those four shapes* it was handed, and
/// never re-judges the shape itself.
///
/// That part is a fact about the conversation rather than about the window, so it lives here, where a
/// test can check it: which target reads from a file, which carries its own bytes, which needs the
/// network, and which is none of those. The reading is in `WeiShell/Picture.swift`.
public enum PictureSource: Equatable, Sendable {
    /// A picture on this machine, by path.
    case file(String)
    /// A picture carried inside the answer: the bytes are right there, so nothing can fail to load.
    case inline(Data)
    /// A picture to be fetched.
    case remote(URL)

    /// The target → what reading it would take, or `nil` when it is not a shape this host reads.
    public static func of(_ target: String) -> PictureSource? {
        guard !target.isEmpty else { return nil }
        // A bare path. The commonest shape by far, because it is what a model writes for a picture
        // it has just saved.
        if target.hasPrefix("/") { return .file(target) }

        let lower = target.lowercased()
        if lower.hasPrefix("file:") { return localFile(target) }
        if lower.hasPrefix("data:") { return inlinePicture(target) }
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            guard let url = URL(string: target) else { return nil }
            return .remote(url)
        }
        // A relative target, or a scheme this host does not read. The caption is what the reader
        // gets, which is what they got for every picture before this existed.
        return nil
    }

    /// A `file:` URL, when it names this machine.
    ///
    /// `file:///tmp/x.png` and `file:/tmp/x.png` are paths here; `file://host/tmp/x.png` is a path on
    /// `host`, and is refused rather than fetched — a file URL with a host is how a document asks a
    /// reader to read across a mount they did not agree to. (`md/walk.mbt` refuses that form too, so
    /// this is the same answer arriving twice rather than a second list of what is allowed.)
    private static func localFile(_ target: String) -> PictureSource? {
        guard
            let url = URL(string: target),
            url.scheme?.lowercased() == "file",
            url.host?.isEmpty ?? true,
            !url.path.isEmpty
        else { return nil }
        return .file(url.path)
    }

    /// A `data:` URL, when it is the base64 kind.
    ///
    /// Base64 only: it is what every tool that writes one emits, and a percent-encoded payload is
    /// bytes-in-a-string that nothing here can turn back into bytes without guessing their encoding.
    /// A data URL of the other kind is not read — the caption says what it was.
    private static func inlinePicture(_ target: String) -> PictureSource? {
        guard let comma = target.firstIndex(of: ",") else { return nil }
        let header = target[target.index(target.startIndex, offsetBy: 5)..<comma]
        guard header.lowercased().hasSuffix(";base64") else { return nil }
        let payload = target[target.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload)) else { return nil }
        return .inline(data)
    }
}
