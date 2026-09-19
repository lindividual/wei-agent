import XCTest

@testable import WeiShell

/// What the two delete dialogs **say**.
///
/// The words are the whole of what tells a reader whether their code is at risk, and the mistake they guard
/// against is not a layout one: it is a dialog that removes a project while sounding like it might remove
/// the directory. That is a fact about the sentences, so it is checked without a window — the same split
/// `SketchTests` makes, and for the same reason (there is no way to *read* a dialog from a test, and an
/// eyeball is not a regression test).
///
/// The layout half — a checkbox really arriving in an `NSAlert` — cannot be checked here at all. It was
/// measured once by presenting one and reading the process's own accessibility tree, which is recorded in
/// `docs/macos-pitfalls.md`; `DeleteConfirmation.ask(label:)` is what that measurement was about.
@MainActor
final class DeleteConfirmationTests: XCTestCase {

    // ── one conversation ──────────────────────────────────────────────────

    /// Every conversation delete offers the file, spelled as the irreversible thing it is.
    func testTheSessionDialogNamesTheFileAndSaysItCannotBeUndone() {
        let prompt = DeleteConfirmation.prompt(label: "set up the project")
        XCTAssertEqual(prompt.title, "Delete “set up the project”?")
        XCTAssertEqual(prompt.confirm, "Delete")
        XCTAssertEqual(prompt.checkbox, "Also delete the file on disk (cannot be undone)")
    }

    /// **The count is in the box, and the box is off by default** — the second half of that lives in
    /// `present`, which is not reachable from here; this pins the sentence it is attached to.
    func testTheProjectDialogCountsTheConversationsItWouldDelete() {
        let prompt = DeleteConfirmation.projectPrompt(label: "wei-agent", sessions: 7)
        XCTAssertEqual(prompt.title, "Remove “wei-agent”?")
        XCTAssertEqual(prompt.confirm, "Remove")
        XCTAssertEqual(prompt.checkbox, "Also delete its 7 conversations (cannot be undone)")
    }

    /// One is one, not "1 conversations".
    func testOneConversationIsNotPlural() {
        let prompt = DeleteConfirmation.projectPrompt(label: "p", sessions: 1)
        XCTAssertEqual(prompt.checkbox, "Also delete its 1 conversation (cannot be undone)")
        XCTAssertEqual(
            prompt.body,
            "The project is a folder on disk and is not touched. Its 1 conversation leave the list."
        )
    }

    // ── the sentence the dialog exists for ────────────────────────────────

    /// **The body says the folder is untouched, first.** The row is named after a directory and the button
    /// says "Remove", so without this a reader is entitled to think their source tree is about to go — and
    /// that reading is worse than the feature not existing.
    func testTheProjectDialogSaysTheFolderIsNotTouchedBeforeItSaysAnythingElse() {
        let body = DeleteConfirmation.projectPrompt(label: "p", sessions: 3).body
        XCTAssertTrue(
            body.hasPrefix("The project is a folder on disk and is not touched."),
            "the reassurance has to come first, got: \(body)"
        )
        // And the conversations are the thing that does leave, in both spellings of the count.
        XCTAssertTrue(body.hasSuffix("Its 3 conversations leave the list."), body)
        XCTAssertTrue(
            DeleteConfirmation.projectPrompt(label: "p", sessions: 1).body
                .hasSuffix("Its 1 conversation leave the list.")
        )
    }

    /// **No checkbox when there is nothing for one to decide.** The session dialog's box was added because a
    /// loss the dialog would otherwise announce can be turned into a bigger one; a project with no
    /// conversations has no such loss, and "Also delete its 0 conversations" is a control that cannot do
    /// anything.
    func testAProjectWithNoConversationsHasNoCheckbox() {
        let prompt = DeleteConfirmation.projectPrompt(label: "empty", sessions: 0)
        XCTAssertNil(prompt.checkbox)
        XCTAssertEqual(prompt.body, "The project is a folder on disk and is not touched.")
        // Still a question, and still one with a way out.
        XCTAssertEqual(prompt.confirm, "Remove")
        XCTAssertEqual(prompt.title, "Remove “empty”?")
    }
}
