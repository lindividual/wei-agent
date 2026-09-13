///|
/// The folder chooser, tested where it can be tested.
///
/// Nobody can click a dialog from a test, so what is asserted here is the layer under the click:
/// what one run of the chooser *means*. The distinction that matters is cancellation against
/// failure — closing the dialog is the reader's decision and must be silent, while a chooser that
/// could not open has to say why — and it is the one thing this feature can get wrong quietly.

///|
test "a chosen folder comes back as a path" {
  let choice = classify_folder_choice(0, "/Users/me/src/app\n", "")
  assert_eq(choice, Chosen("/Users/me/src/app"))
}

///|
/// `posix path of` ends with the separator, and the same directory spelled two ways would be two
/// workspaces in the store.
test "the trailing separator comes off, and the root keeps it" {
  assert_eq(
    classify_folder_choice(0, "/Users/me/src/app/\n", ""),
    Chosen("/Users/me/src/app"),
  )
  assert_eq(classify_folder_choice(0, "/\n", ""), Chosen("/"))
  // A name with a space in it is a name, not two paths.
  assert_eq(
    classify_folder_choice(0, "/Users/me/my src/\n", ""),
    Chosen("/Users/me/my src"),
  )
}

///|
/// Closing the dialog is not a failure: `osascript` reports it as an error, and the difference is
/// in the text. Getting this wrong puts "the folder chooser failed" on the status line every time
/// somebody changes their mind.
test "a closed dialog is a cancellation, not a failure" {
  assert_eq(
    classify_folder_choice(1, "", "execution error: User canceled. (-128)"),
    Cancelled,
  )
  // The code alone is not enough: a chooser that could not open also exits non-zero.
  assert_eq(
    classify_folder_choice(
      1, "", "execution error: Not authorized to send Apple events. (-1743)",
    ),
    Unavailable(
      "the folder chooser failed: execution error: Not authorized to send Apple events. (-1743)",
    ),
  )
  assert_eq(
    classify_folder_choice(127, "", ""),
    Unavailable("the folder chooser failed"),
  )
}
