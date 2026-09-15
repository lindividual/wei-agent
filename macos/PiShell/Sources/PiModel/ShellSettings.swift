import Foundation

/// What the settings panel draws: where the key in use comes from, and which tools a turn gets.
///
/// A snapshot of the shell's answer rather than a form the host owns. The panel does not hold a copy
/// of the settings to edit and save — it asks for a change and waits for the shell to say what is now
/// true — which is what keeps a refused or failed save from leaving the window describing a state
/// that never existed.
///
/// The key's *value* is deliberately not here. The panel shows where the key came from and a
/// fingerprint of it, which answers "did my paste land"; a wire that only ever draws a credential
/// dimmed has no business carrying it.
public struct ShellSettings: Equatable, Decodable {
    /// `environment`, `saved`, `pi` or `none`. The same four words the web panel uses for the same
    /// four facts, because a third vocabulary for "where is the key from" would be a third thing to
    /// keep in step.
    public let key: String
    /// Whether `DEEPSEEK_API_KEY` is set. With `saved`, this is the case the panel has to explain:
    /// the key the reader saved is being overruled, and "I saved it and it still uses the old one"
    /// reads as a bug otherwise.
    public let env: Bool
    /// Whether a key has been saved in the settings file.
    public let saved: Bool
    /// `tools` or `code`.
    public let mode: String
    /// The settings file itself, so that a reader who would rather edit it by hand knows which one
    /// to open — the honest fallback for everything this panel does not offer.
    public let path: String

    /// The key in use, said as a sentence. One place, because the panel says it and a reader may
    /// check it against the status line.
    public var keySummary: String {
        switch key {
        case "environment": return "In use, from DEEPSEEK_API_KEY"
        case "saved": return "In use, saved here"
        case "pi": return "In use, from pi's credential store"
        default: return "No key: the first turn will fail"
        }
    }

    /// Whether the environment is overruling a saved key — the one combination worth a sentence of
    /// its own, because the reader has no way to see it from the fields alone.
    public var savedKeyIsOverruled: Bool {
        env && saved
    }
}
