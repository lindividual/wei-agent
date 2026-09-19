///|
/// The home directory, as the four front ends ask for it.
///
/// A helper rather than four copies because the copies had already drifted: two of them treated
/// `HOME=` as a home and two did not. The rule asserted here is the one that is safe for all four —
/// an empty variable is nobody's home, so a caller that aborts says so instead of building a store
/// path next to the filesystem root.
test "home is what the environment says, and empty is not a home" {
  let before = home_dir()
  @env.set_env_var("HOME", "/tmp/wei-home-test")
  assert_eq(home_dir(), Some("/tmp/wei-home-test"))
  @env.set_env_var("HOME", "")
  assert_eq(home_dir(), None)
  @env.unset_env_var("HOME")
  assert_eq(home_dir(), None)
  // Put the machine back the way it was found, since this is the process's own environment.
  match before {
    Some(home) => @env.set_env_var("HOME", home)
    None => @env.unset_env_var("HOME")
  }
}
