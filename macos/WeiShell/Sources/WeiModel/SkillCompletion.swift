import Foundation

/// Which skills a draft that is part-way through a slash command is offering.
///
/// A rule rather than a `Bool` in a view, for the same reason `Dictation` and `ScrollFollow` are rules:
/// what is easy to get wrong here is not "is the menu open" but *what counts as a command being typed*
/// — and the answer decides whether a reader writing `/usr/local/bin` into the middle of a sentence gets
/// a menu thrown over their text. That is a decision, it is checkable, and it lives here where a test can
/// run it without a window.
///
/// **The trigger is a slash and then no space.** `/` alone, `/s`, `/skill`, `/skill:de` are all somebody
/// naming a command; `/skill:demo do the thing` is a finished command and a sentence after it, and
/// `/usr/local/bin` is a path. Those are the same test — the space, or its absence — which is also the
/// test the web UI makes (`COMMAND_RE`), so the two front ends open the same menu at the same moment.
///
/// **What is offered turns into a `/skill:<name>`, in the skill's own spelling.** That is the spelling the
/// shell expands, so the menu is the reader's way of *finding* the command rather than a second syntax —
/// and a partial command is matched against that whole spelling. `/sk` and `/skill:` list every skill
/// (`/skill:moonbit` begins with both), `/skill:mo` narrows to the ones whose name begins that way, `/x`
/// matches nothing and the menu stays shut.
///
/// **Only the enabled ones, and for the reason the panel gives.** A skill that is switched off is not
/// something the reader can invoke — the shell refuses to expand it and the model is never told it
/// exists — so offering it would be offering a command that does nothing.
///
/// **A lone exact match is not a suggestion, it is what is already there.** With `demo` typed out in
/// full (`/skill:demo`) the menu has nothing to add, and a one-row list offering the reader the text they
/// just typed is noise in the way of pressing Return.
public enum SkillCompletion {
    /// The enabled skills this draft is naming, in the order they were given.
    ///
    /// Empty when the draft is not a command being typed, when nothing matches, or when the one thing
    /// that matches has already been typed out in full.
    public static func matches(draft: String, skills: [SkillEntry]) -> [SkillEntry] {
        guard let typed = command(draft) else { return [] }
        let wanted = typed.lowercased()
        let matches = skills.filter { skill in
            skill.enabled && spelling(skill).lowercased().hasPrefix(wanted)
        }
        if matches.count == 1, spelling(matches[0]).lowercased() == wanted { return [] }
        return matches
    }

    /// What the menu inserts for a skill — the spelling the shell expands, name and all.
    public static func spelling(_ skill: SkillEntry) -> String {
        "/skill:\(skill.name)"
    }

    /// Where an arrow key lands the highlight, given how many rows are on offer.
    ///
    /// **Clamped, not cyclic.** Both ends of the menu are on screen at once (it is capped by the view),
    /// so a wrap turns a held arrow key into a tour of the list instead of a way to reach the last row —
    /// and the reader who presses ↓ five times to be sure they are at the bottom gets the top row.
    ///
    /// `count` is asked for rather than trusted to be non-zero, because the menu is built from the
    /// highlight in the same breath: an empty menu and this arithmetic meet on every keystroke typed
    /// after the last matching skill has been narrowed away.
    public static func move(from picked: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(picked + delta, 0), count - 1)
    }

    /// The command a draft is part-way through, or `nil` when the draft is not one.
    ///
    /// Trimmed first, because leading or trailing space is not a decision the reader made — a draft of
    /// `"  /sk"` is the same act as `"/sk"`. Interior whitespace is the opposite: it ends the command,
    /// and everything after it is an argument or a sentence, which is what keeps a path and a finished
    /// `/skill:…` from opening a menu over text that is not a command at all.
    private static func command(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        return trimmed
    }
}
