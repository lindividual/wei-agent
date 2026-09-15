///|
/// Starting a process: the command line, the credentials, and opening the first session.
///
/// Everything here runs once, before the server exists, and nothing here is reachable from a
/// request. The interface is `parse_args` and `open_session`; the rest is the key resolution order
/// (the decision is `@core.choose_api_key`; this file only reads the three sources it chooses
/// between) and the file layout a new session gets.

///|
/// Where the process should start.
enum Start {
  New
  /// The most recently written session for this directory.
  Continue
  /// A path, or a session id to look up under this directory.
  Session(String)
}

///|
/// A parsed command line.
struct Args {
  port : Int
  model : String
  /// Where the model is served from. A flag rather than a constant because pointing it at a local
  /// gateway is useful, and because it is the only way to test what a *failing* turn leaves behind.
  base_url : String
  start : Start
  store : String
  /// Most one turn may cost, in US dollars, or `None` when the flag was not given.
  ///
  /// `None` rather than a default is what lets the saved setting in the panel win over nothing,
  /// while a value the reader typed on the command line still wins over the saved setting. A flag
  /// is a hard cap for this run; a value saved months ago in a browser must not be able to turn it
  /// into a suggestion.
  ///
  /// It is also the only bound that tracks money rather than effort — a turn can make three calls
  /// and still cost more than a hundred small ones.
  max_cost : Double?
  /// Most model calls one turn may make, or `None` when the flag was not given.
  max_rounds : Int?
  /// Longest one turn may take in seconds, or `None` when the flag was not given.
  ///
  /// The third limit the panel can edit, and a backstop the other two cannot see: a command that
  /// hangs costs nothing per model call and would otherwise run until the socket gives up.
  /// `@core.default_max_seconds()` is what runs when neither the flag nor the saved setting says.
  max_seconds : Int?
  /// `--mode tools|code`, or `None` when the flag was not given.
  ///
  /// A string rather than a `ToolMode` so that the two spellings the flag accepts are parsed in one
  /// place, next to the saved setting that can say the same thing.
  mode : String?
  /// Set when the reader asked for no folder chooser.
  ///
  /// The host is asked whether it can open a dialog either way; this is for the case where it can
  /// but the reader does not want one — a shared screen, a script driving the page, or an
  /// `osascript` dialog that steals focus at the wrong moment.
  no_picker : Bool
}

///|
fn usage() -> String {
  "usage: ui [--port N] [--model M] [--base-url URL] [--continue | --resume <path|id>] [--store DIR] [--max-cost USD] [--max-rounds N] [--max-seconds N] [--mode tools|code] [--no-picker]"
}

///|
fn parse_args(argv : Array[String]) -> Args raise {
  let mut port = 8790
  // The catalog's default, not a literal: the flag default and the fallback a new session uses
  // have to be the same model, or `--model` unset would mean one thing here and another there.
  let mut model = @core.default_model_id()
  let mut base_url = "https://api.deepseek.com"
  let mut start = Start::New
  let mut store = ""
  // `None` until a flag says otherwise: the limits the panel saves are the fallback, and the
  // driver's own defaults are the fallback for those.
  let mut max_cost : Double? = None
  let mut max_rounds : Int? = None
  let mut max_seconds : Int? = None
  let mut mode : String? = None
  let mut no_picker = false
  let mut index = 1
  while index < argv.length() {
    let flag = argv[index]
    let needs_value = flag == "--port" ||
      flag == "--model" ||
      flag == "--base-url" ||
      flag == "--resume" ||
      flag == "--store" ||
      flag == "--max-cost" ||
      flag == "--max-rounds" ||
      flag == "--max-seconds" ||
      flag == "--mode"
    if needs_value && index + 1 >= argv.length() {
      raise Failure::Failure("\{flag} needs a value\n\{usage()}")
    }
    match flag {
      "--port" => {
        port = try @string.parse_int(argv[index + 1]) catch {
          _ => raise Failure::Failure("--port needs a number")
        } noraise {
          value => value
        }
        index += 2
      }
      "--model" => {
        model = argv[index + 1]
        index += 2
      }
      "--base-url" => {
        base_url = argv[index + 1]
        index += 2
      }
      "--resume" => {
        start = Session(argv[index + 1])
        index += 2
      }
      "--store" => {
        store = argv[index + 1]
        index += 2
      }
      "--max-cost" => {
        let value = try @string.parse_double(argv[index + 1]) catch {
          _ => raise Failure::Failure("--max-cost needs a number of dollars")
        } noraise {
          value => value
        }
        if value < 0.0 {
          raise Failure::Failure("--max-cost cannot be negative")
        }
        max_cost = Some(value)
        index += 2
      }
      "--max-rounds" => {
        let value = try @string.parse_int(argv[index + 1]) catch {
          _ =>
            raise Failure::Failure("--max-rounds needs a whole number of calls")
        } noraise {
          value => value
        }
        if value < 0 {
          raise Failure::Failure("--max-rounds cannot be negative")
        }
        max_rounds = Some(value)
        index += 2
      }
      "--max-seconds" => {
        let value = try @string.parse_int(argv[index + 1]) catch {
          _ =>
            raise Failure::Failure(
              "--max-seconds needs a whole number of seconds",
            )
        } noraise {
          value => value
        }
        if value < 0 {
          raise Failure::Failure("--max-seconds cannot be negative")
        }
        max_seconds = Some(value)
        index += 2
      }
      "--mode" => {
        // An unknown word is refused rather than read as the default. The saved setting can afford
        // to be forgiving because it is a file nobody is watching; a flag is typed at a terminal
        // that is about to print something, and silently starting in the other mode is the kind of
        // mistake that is found out a turn later.
        match argv[index + 1] {
          "tools" | "code" => mode = Some(argv[index + 1])
          other =>
            raise Failure::Failure(
              "--mode takes `tools` or `code`, not \{other}",
            )
        }
        index += 2
      }
      "--continue" | "-c" => {
        start = Continue
        index += 1
      }
      "--new" => {
        start = New
        index += 1
      }
      "--no-picker" => {
        no_picker = true
        index += 1
      }
      "--help" | "-h" => raise Failure::Failure(usage())
      _ => raise Failure::Failure("unknown argument: \{flag}\n\{usage()}")
    }
  }
  {
    port,
    model,
    base_url,
    start,
    store,
    max_cost,
    max_rounds,
    max_seconds,
    mode,
    no_picker,
  }
}

///|
/// Whether the page should offer the folder chooser.
///
/// Two questions, and both have to be yes: this host can open a dialog at all, and the reader did
/// not ask for it not to. Answered before the page is drawn rather than when the button is
/// pressed, because a button that cannot work is worse than no button.
///
/// The answer decides more than whether a button is drawn: where there is no chooser, the sidebar's
/// add row is a path field instead, because that is the only way in. One control either way — a
/// field beside a dialog is a second answer to a question already answered.
async fn offers_picker(args : Args) -> Bool {
  !args.no_picker && @platform.can_pick_directory()
}

///|
fn field(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
async fn pi_api_key(home : String) -> String? {
  let path = "\{home}/.pi/agent/auth.json"
  if !@platform.path_exists(path) {
    return None
  }
  let store = @json.parse(@platform.read_text(path))
  let provider = match field(store, "deepseek") {
    Some(value) => value
    None => return None
  }
  match field(provider, "key") {
    Some(String(key)) => Some(key)
    _ => None
  }
}

///|
/// `DEEPSEEK_API_KEY`, or empty when it is not set.
///
/// Read once, at startup, and kept: whether a saved key is the one in use depends on this, and a
/// panel that re-read the environment on every render would give a different answer in the middle
/// of one process — while the turns it is describing are using the value from when the process
/// started.
fn environment_key() -> String {
  match @env.get_env_var("DEEPSEEK_API_KEY") {
    Some(key) => key
    None => ""
  }
}

///|
fn home_dir() -> String raise {
  match @env.get_env_var("HOME") {
    Some(home) if home != "" => home
    _ => raise Failure::Failure("HOME is not set")
  }
}

///|
/// A session header for a brand new conversation.
fn new_header(
  id : String,
  cwd : String,
  timestamp : Int64,
) -> @core.SessionHeader {
  {
    id,
    timestamp: @core.format_iso_utc(timestamp),
    cwd,
    parent_session: None,
    version: Some(3),
  }
}

///|
/// A fresh session in this workspace, in memory and not yet on disk.
///
/// The file appears when the first entry is written, which is what keeps a store from
/// filling up with header-only sessions that a picker then has to show.
fn create_session(root : String, cwd : String) -> (@core.Session, String) {
  let now = @env.now().reinterpret_as_int64()
  let id = @core.new_entry_id()
  let path = @core.session_file_path(root, cwd, now, id)
  let header = new_header(id, cwd, now)
  (@core.Session::new(header, []), path)
}

///|
/// Open a path, closing an interrupted turn if there is one.
async fn open_path(path : String) -> @core.Session {
  let session = @platform.load_session(path)
  let entries = session.repair_entries(@env.now().reinterpret_as_int64())
  if entries.is_empty() {
    return session
  }
  // The closers go into the log, not only into memory: a repair that exists only
  // until the process exits is not a repair.
  @platform.append_entries(path, entries)
  session.add_entries(entries)
}

///|
/// Open the session the command line asked for, creating one when needed.
///
/// Resuming is where the format work pays off: the file was written by whatever ran last
/// — this process, an older build, or pi itself — and it is read back through the same
/// parser the round-trip verifier exercises.
async fn open_session(
  args : Args,
  root : String,
  cwd : String,
) -> (@core.Session, String) {
  match args.start {
    New => create_session(root, cwd)
    Continue =>
      match @platform.newest_session(root, cwd) {
        None => create_session(root, cwd)
        Some(path) => (open_path(path), path)
      }
    Session(value) => {
      let path = if value.contains("/") {
        value
      } else {
        match @platform.find_session(root, value) {
          Some(found) => found
          None => raise Failure::Failure("no session \{value} in \{root}")
        }
      }
      if !@platform.path_exists(path) {
        raise Failure::Failure("no session file at \{path}")
      }
      (open_path(path), path)
    }
  }
}
