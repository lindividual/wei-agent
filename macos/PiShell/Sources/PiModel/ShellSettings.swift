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
    /// Every skill this machine can see, switched on or off. Disabled ones are listed too: a list
    /// that only showed what is on would have nothing to click to turn something off, and a skill
    /// switched off before it was uninstalled is a setting a reader could no longer see to undo.
    public let skills: [SkillEntry]
    /// The fallback instructions in force — what a turn appends in a workspace with no `AGENTS.md`.
    public let instructions: String
    /// `file`, `saved` or `none`. Shown beside the text, because the two disagreeing is exactly the
    /// case a reader needs explained: instructions saved here and a repository's file in the box
    /// means the file won, and saving again would change nothing.
    public let instructionsSource: String
    /// The three turn limits, each with where its value came from.
    public let limits: Limits

    private enum CodingKeys: String, CodingKey {
        case key, env, saved, mode, path, skills, instructions, limits
        case instructionsSource = "instructions_source"
    }

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

/// One line of the skills list.
public struct SkillEntry: Equatable, Decodable, Identifiable {
    public let name: String
    /// One line from the skill's frontmatter. Empty for a name with no file behind it.
    public let description: String
    /// Where the file is, or empty for a name that no longer matches anything discovered.
    public let path: String
    public let enabled: Bool

    public var id: String { name }

    public init(name: String, description: String, path: String, enabled: Bool) {
        self.name = name
        self.description = description
        self.path = path
        self.enabled = enabled
    }
}

/// The three limits in force, and who decided each one.
public struct Limits: Equatable, Decodable {
    public let rounds: Limit
    public let cost: Limit
    public let seconds: Limit
}

/// One limit: its value as a string, and where it came from.
///
/// A string because it is what the field shows and what the reader would type back — `0.05` for a
/// cost, `200` for a count — and because the shell already decided how many decimals each one has.
public struct Limit: Equatable, Decodable {
    public let value: String
    /// `flag`, `saved` or `default`. A flag is shown rather than edited: a field that appears to
    /// accept a value the process will ignore is worse than no field.
    public let source: String

    public var isFromFlag: Bool { source == "flag" }

    /// Whether the value in force is a bound at all. `0` means the limit is off, which is a
    /// different thing from the built-in default being in force.
    public var isOff: Bool { value == "0" }

    public init(value: String, source: String) {
        self.value = value
        self.source = source
    }
}
