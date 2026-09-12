///|
/// The look of the page: design tokens, and the handful of components it is made of.
///
/// Two things live here rather than in the components that use them. First the *tokens* —
/// spacing, colour, radius, type scale — because a page styled by ad-hoc numbers drifts
/// into five slightly different greys and four different gaps between things that should
/// look alike. Second the *class names*, because the styling and the markup have to agree
/// and the browser tests query them.
///
/// Colours are semantic (`--fg`, `--muted`, `--surface`, `--line`, `--accent`, `--danger`)
/// and defined twice, once per colour scheme, rather than reached for directly. Both
/// schemes are spelled out with a media query instead of `light-dark()`: the shorthand is
/// nicer, but a browser that does not know it computes the colour as invalid, and the page
/// then has no colours at all.
///
/// No framework and no build step, on purpose. The stylesheet is inlined into the page by
/// `render_page`, which is the reason this file can be a plain string with no asset
/// directory to get out of sync.

///|
pub fn stylesheet() -> String {
  [
    // ── tokens ──────────────────────────────────────────────────────────────
    ":root {", "  color-scheme: light dark;", "  --space-1: .25rem;", "  --space-2: .5rem;",
    "  --space-3: .75rem;", "  --space-4: 1rem;", "  --space-5: 1.5rem;", "  --space-6: 2rem;",
    "  --radius-sm: .3rem;", "  --radius: .5rem;", "  --radius-lg: .75rem;", "  --text-xs: .78rem;",
    "  --text-sm: .86rem;", "  --text-base: .95rem;", "  --leading: 1.55;", "  --mono: ui-monospace, SFMono-Regular, Menlo, monospace;",
    "  --sans: ui-sans-serif, system-ui, -apple-system, sans-serif;", "  --sidebar-width: 17rem;",
    "  --bg: #ffffff;", "  --surface: #f6f6f7;", "  --surface-strong: #ececee;",
    "  --fg: #1b1c1e;", "  --muted: #6b6f76;", "  --line: rgba(0, 0, 0, .12);", "  --line-strong: rgba(0, 0, 0, .28);",
    "  --accent: #2f6feb;", "  --danger: #c8342f;", "  --ok: #1f8a4c;", "}", "@media (prefers-color-scheme: dark) {",
    "  :root {", "    --bg: #17181a;", "    --surface: #202124;", "    --surface-strong: #2a2c30;",
    "    --fg: #e7e8ea;", "    --muted: #9aa0a8;", "    --line: rgba(255, 255, 255, .14);",
    "    --line-strong: rgba(255, 255, 255, .32);", "    --accent: #6ea8fe;", "    --danger: #f2796f;",
    "    --ok: #4ec97f;", "  }", "}",
    // ── base ────────────────────────────────────────────────────────────────
     "* { box-sizing: border-box; }", "body { margin: 0; background: var(--bg); color: var(--fg); font: var(--text-base)/var(--leading) var(--sans); }",
    "a { color: var(--accent); }", "pre { font-family: var(--mono); font-size: var(--text-sm); white-space: pre-wrap; word-break: break-word; background: var(--surface); border-radius: var(--radius-sm); padding: var(--space-3); margin: var(--space-2) 0; overflow-x: auto; }",
    "code { font-family: var(--mono); font-size: .95em; }", "summary { cursor: pointer; color: var(--muted); font-size: var(--text-sm); }",
    "details[open] > summary { margin-bottom: var(--space-2); }",
    // ── layout ──────────────────────────────────────────────────────────────
     ".layout { display: flex; align-items: flex-start; gap: var(--space-5); max-width: 82rem; margin: 0 auto; }",
    ".column { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; min-height: 100vh; }",
    ".bar { position: sticky; top: 0; z-index: 2; display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-1); padding: var(--space-2) var(--space-4); background: var(--bg); border-bottom: 1px solid var(--line); }",
    ".bar .spacer { flex: 1 1 auto; }", "#transcript { flex: 1 1 auto; padding: var(--space-5) var(--space-4) var(--space-6); }",
    // ── sidebar ─────────────────────────────────────────────────────────────
     ".sidebar { flex: 0 0 var(--sidebar-width); position: sticky; top: 0; max-height: 100vh; overflow-y: auto; padding: var(--space-4) var(--space-2) var(--space-6) var(--space-4); font-size: var(--text-sm); }",
    ".sidebar details.workspace { margin-bottom: var(--space-2); padding-left: var(--space-2); border-left: 1px solid var(--line); }",
    ".sidebar details.workspace > summary { font-weight: 600; color: var(--fg); opacity: .85; padding: var(--space-1) var(--space-1); overflow: hidden; white-space: nowrap; }",
    ".sidebar details.workspace.active > summary { opacity: 1; }", ".sidebar summary .name { display: inline-block; vertical-align: bottom; max-width: 11rem; overflow: hidden; text-overflow: ellipsis; }",
    ".sidebar ul { list-style: none; margin: 0; padding: 0; }", ".sidebar li { position: relative; }",
    ".sidebar .empty { color: var(--muted); padding: 0 var(--space-2); }", ".sidebar .meta { color: var(--muted); font-size: var(--text-xs); padding: 0 var(--space-2) var(--space-2); }",
    ".sidebar li.current button { border-color: var(--line-strong); font-weight: 600; }",
    ".sidebar .dot { position: absolute; right: var(--space-2); top: .55rem; width: .45rem; height: .45rem; border-radius: 50%; background: var(--ok); animation: pulse 1.2s ease-in-out infinite; }",
    "@keyframes pulse { 50% { opacity: .25; } }",
    // ── controls ────────────────────────────────────────────────────────────
     "button { font: inherit; color: inherit; background: transparent; border: 1px solid var(--line-strong); border-radius: var(--radius); padding: var(--space-2) var(--space-4); cursor: pointer; }",
    "button:hover { background: var(--surface); }", "button:disabled { opacity: .45; cursor: default; }",
    "button.primary { border-color: var(--accent); color: var(--accent); }", "button.ghost { border-color: transparent; color: var(--muted); }",
    ".sidebar button { display: block; width: 100%; text-align: left; padding: var(--space-2) var(--space-2); border-color: transparent; border-radius: var(--radius-sm); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
    ".sidebar button:hover { background: var(--surface); }", ".sidebar button.new { color: var(--muted); font-size: var(--text-sm); }",
    ".btn-row { display: flex; gap: var(--space-1); align-items: center; }",
    // ── chips: a label and a number, for facts about the session ────────────
     ".chip { display: inline-flex; align-items: baseline; gap: .3rem; padding: .1rem .4rem; border: 1px solid var(--line); border-radius: var(--radius-sm); font-size: var(--text-xs); color: var(--muted); white-space: nowrap; }",
    ".chip b { color: var(--fg); font-weight: 600; font-variant-numeric: tabular-nums; }",
    ".chip.warn b { color: var(--danger); }", ".chip .meter { display: inline-block; width: 4rem; height: .35rem; border-radius: 999px; background: var(--surface-strong); overflow: hidden; }",
    ".chip .meter > i { display: block; height: 100%; background: var(--accent); }",
    ".chip.warn .meter > i { background: var(--danger); }",
    // ── panels: the sidebar's own sections ──────────────────────────────────
     ".panel { margin-bottom: var(--space-3); }", ".panel > h2 { margin: 0 0 var(--space-2); font-size: var(--text-xs); font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--muted); }",
    ".panel .task { border: 1px solid var(--line); border-radius: var(--radius-sm); padding: var(--space-2); margin-bottom: var(--space-2); }",
    ".panel .task .row { display: flex; align-items: center; gap: var(--space-2); }",
    // `min-width: 0` on the flexible half, or a long session label refuses to shrink and
    // squeezes the button next to it down to an ellipsis.
     ".panel .task .label { min-width: 0; }", ".panel .task .label { flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
    ".panel .task .tool { font-family: var(--mono); font-size: var(--text-xs); color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
    ".panel .task form { display: flex; }", ".panel .task button { flex: 0 0 auto; width: auto; border-color: var(--line-strong); padding: var(--space-1) var(--space-2); }",
    ".panel input[type=text] { width: 100%; font: inherit; font-size: var(--text-sm); color: inherit; background: var(--bg); border: 1px solid var(--line-strong); border-radius: var(--radius-sm); padding: var(--space-2); }",
    ".add-workspace { display: flex; gap: var(--space-1); margin-top: var(--space-2); padding: 0 var(--space-2); }",
    ".add-workspace input { flex: 1 1 auto; min-width: 0; font: inherit; font-size: var(--text-sm); color: inherit; background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: var(--space-1) var(--space-2); }",
    ".add-workspace button { flex: 0 0 auto; width: auto; border-color: var(--line-strong); padding: var(--space-1) var(--space-2); }",
    // ── conversation ────────────────────────────────────────────────────────
     ".exchange { margin-bottom: var(--space-5); }", ".user { background: var(--surface); border-radius: var(--radius-lg); padding: var(--space-3) var(--space-4); margin-bottom: var(--space-3); white-space: pre-wrap; }",
    ".user > :first-child, .text > :first-child { margin-top: 0; }", ".user > :last-child, .text > :last-child { margin-bottom: 0; }",
    ".blocks > * { margin-bottom: var(--space-3); }", ".text { white-space: normal; }",
    ".blocks details { border-left: 2px solid var(--line); padding-left: var(--space-3); }",
    ".blocks details.tool > summary { font-family: var(--mono); }", ".blocks details.compaction { border-left-style: dashed; }",
    ".blocks .pending { color: var(--muted); font-size: var(--text-sm); }", ".blocks .result.error pre { border-left: 3px solid var(--danger); }",
    ".blocks .image { color: var(--muted); font-size: var(--text-sm); }",
    // ── status + composer ───────────────────────────────────────────────────
     ".status { color: var(--muted); font-size: var(--text-sm); padding: 0 var(--space-4) var(--space-1); text-align: center; }",
    "#composer { position: sticky; bottom: 0; display: flex; gap: var(--space-2); padding: var(--space-3) var(--space-4); background: var(--bg); border-top: 1px solid var(--line); }",
    "#composer textarea { flex: 1 1 auto; resize: none; font: inherit; color: inherit; background: var(--bg); border: 1px solid var(--line-strong); border-radius: var(--radius); padding: var(--space-2) var(--space-3); }",
  ].join("\n")
}

// ── components ─────────────────────────────────────────────────────────────

///|
/// A labelled fact about the session: usage, cost, context.
///
/// `detail` goes in the tooltip, for the cases where the readable value is an abbreviation
/// of something the reader may want in full — a session id, a path.
pub fn chip(
  label : String,
  value : String,
  warn? : Bool = false,
  detail? : String = "",
) -> Node {
  let attrs : Array[Attr] = [cls(if warn { "chip warn" } else { "chip" })]
  if detail != "" {
    attrs.push(attr("title", detail))
  }
  el("span", attrs~, children=[txt(label), el("b", children=[txt(value)])])
}

///|
/// A count as a reader reads it: thousands abbreviated, because a bar with `18422` in it is a
/// number nobody parses at a glance.
pub fn compact_number(value : Int) -> String {
  let n = value.to_double()
  if value < 1000 {
    "\{value}"
  } else if value < 1000000 {
    "\{(n / 1000.0 * 10.0).round() / 10.0}k"
  } else {
    "\{(n / 1000000.0 * 10.0).round() / 10.0}M"
  }
}

///|
/// Collapse whitespace and cut to a readable length.
///
/// For text that came from the conversation — a prompt used as a label — where the shape
/// (one line, bounded) matters more than the exact content.
pub fn clip_label(text : String, limit? : Int = 80) -> String {
  let out = StringBuilder()
  let mut count = 0
  let mut started = false
  let mut gap = false
  let mut clipped = false
  for c in text {
    let is_space = c == ' ' || c == '\n' || c == '\t' || c == '\r'
    if is_space {
      if started {
        gap = true
      }
      continue
    }
    if count >= limit {
      clipped = true
      break
    }
    if gap {
      out.write_char(' ')
      count += 1
      gap = false
    }
    out.write_char(c)
    count += 1
    started = true
  }
  if clipped {
    out.write_string("…")
  }
  out.to_string()
}

///|
/// The same, for a value that is a proportion of something — how full the context is.
pub fn chip_meter(
  label : String,
  value : String,
  fraction : Double,
  warn? : Bool = false,
  /// Goes in the tooltip, like `chip`'s: what the number means and where it came from.
  detail? : String = "",
) -> Node {
  let percent = if fraction < 0.0 {
    0.0
  } else if fraction > 1.0 {
    1.0
  } else {
    fraction
  }
  el(
    "span",
    attrs=[
      cls(if warn { "chip warn" } else { "chip" }),
      attr("title", if detail != "" { detail } else { "\{label} \{value}" }),
    ],
    children=[
      txt(label),
      el("b", children=[txt(value)]),
      el("span", attrs=[cls("meter")], children=[
        el(
          "i",
          attrs=[attr("style", "width: \{(percent * 100.0).round().to_int()}%")],
          children=[],
        ),
      ]),
    ],
  )
}

///|
/// A section of the sidebar.
pub fn panel(title : String, children : Array[Node]) -> Node {
  el("section", attrs=[cls("panel")], children=[
    el("h2", children=[txt(title)]),
    frag(children),
  ])
}
