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
    // How much of reasoning is shown while it is still arriving. In lines rather than in pixels,
    // so it is the same amount of text whatever the type scale becomes: the box is sized from
    // `--leading`, which is what `body`'s own `font` shorthand sets the line height to. Change one
    // without the other and the box stops landing on whole lines.
     "  --peek-lines: 3;", "  --measure: 62ch;",
    // Room for the language badge and the Copy button over a code block's corner. This is the value
    // before anything is measured — the client sets it per block to the controls' actual width, so
    // an unusually long language name cannot end up under the button.
     "  --code-controls: 7.5rem;", "  --bg: #ffffff;", "  --surface: #f6f6f7;", "  --surface-strong: #ececee;",
    // The fill behind the session being read. A tint rather than a second grey, because the one
    // thing that has to be findable in the list is the row the page is already showing.
     "  --accent-soft: rgba(47, 111, 235, .12);", "  --fg: #1b1c1e;", "  --muted: #6b6f76;",
    // Quiet text on a *tinted* surface. One step darker than `--muted`, because that colour already
    // sits close to the 4.5:1 line on the page background (4.9) and the selected row's wash takes
    // the rest of the headroom with it. Only the selected row needs it: every other quiet string on
    // the page is on `--bg`.
     "  --muted-strong: #61656d;", "  --line: rgba(0, 0, 0, .12);", "  --line-strong: rgba(0, 0, 0, .28);",
    "  --accent: #2f6feb;", "  --danger: #c8342f;", "  --ok: #1f8a4c;", "}", "@media (prefers-color-scheme: dark) {",
    "  :root {", "    --bg: #17181a;", "    --surface: #202124;", "    --surface-strong: #2a2c30;",
    "    --accent-soft: rgba(110, 168, 254, .16);", "    --fg: #e7e8ea;", "    --muted: #9aa0a8;",
    "    --muted-strong: #b0b6bd;", "    --line: rgba(255, 255, 255, .14);", "    --line-strong: rgba(255, 255, 255, .32);",
    "    --accent: #6ea8fe;", "    --danger: #f2796f;", "    --ok: #4ec97f;", "  }",
    "}",
    // ── base ────────────────────────────────────────────────────────────────
     "* { box-sizing: border-box; }", "body { margin: 0; background: var(--bg); color: var(--fg); font: var(--text-base)/var(--leading) var(--sans); }",
    "a { color: var(--accent); }", "pre { font-family: var(--mono); font-size: var(--text-sm); white-space: pre-wrap; word-break: break-word; background: var(--surface); border-radius: var(--radius-sm); padding: var(--space-3); margin: var(--space-2) 0; overflow-x: auto; }",
    "code { font-family: var(--mono); font-size: .95em; }", "summary { cursor: pointer; color: var(--muted); font-size: var(--text-sm); padding-block: var(--space-1); }",
    "details[open] > summary { margin-bottom: var(--space-2); }",
    // ── layout ──────────────────────────────────────────────────────────────
     ".layout { display: flex; align-items: flex-start; gap: var(--space-5); max-width: 82rem; margin: 0 auto; }",
    ".column { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; min-height: 100vh; }",
    ".bar { position: sticky; top: 0; z-index: 2; display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-1); padding: var(--space-2) var(--space-4); background: var(--bg); border-bottom: 1px solid var(--line); }",
    ".bar .spacer { flex: 1 1 auto; }", "#transcript { flex: 1 1 auto; padding: var(--space-5) var(--space-4) var(--space-6); }",
    // The chips on the right are wrapped so a turn can replace just them. They used to be direct
    // children of the bar, which meant refreshing a number rebuilt the bar — and once the settings
    // panel lived there, closed whatever the reader had open in it.
     ".bar .usage { display: inline-flex; align-items: center; gap: var(--space-1); flex-wrap: wrap; }",
    // ── sidebar ─────────────────────────────────────────────────────────────
     ".sidebar { flex: 0 0 var(--sidebar-width); position: sticky; top: 0; max-height: 100vh; overflow-y: auto; padding: var(--space-4) var(--space-2) var(--space-6) var(--space-4); font-size: var(--text-sm); }",
    ".sidebar details.workspace { margin-bottom: var(--space-2); padding-left: var(--space-2); border-left: 1px solid var(--line); }",
    ".sidebar details.workspace > summary { display: flex; align-items: center; gap: var(--space-2); font-weight: 600; color: var(--fg); opacity: .85; padding: var(--space-1) var(--space-1); }",
    ".sidebar details.workspace.active > summary { opacity: 1; }",
    // The disclosure mark, drawn rather than left to the browser's triangle: it turns when the group
    // opens, and that turn is the only thing on a header that says the group folds at all. The row's
    // own hover fill is the feedback while the pointer is over it, so the chevron is not recoloured
    // — a second signal a few pixels away from the first is noise.
     ".sidebar .chev { flex: 0 0 auto; width: .42rem; height: .42rem; border-right: 1.5px solid var(--muted); border-bottom: 1.5px solid var(--muted); transform: rotate(-45deg); transition: transform .15s ease; }",
    ".sidebar details[open] > summary .chev { transform: rotate(45deg); }", ".sidebar summary .name { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
    ".sidebar ul { list-style: none; margin: 0; padding: 0; }", ".sidebar li { position: relative; }",
    // One line per session: the marker, the label, the age, and the actions, which take the age's
    // place under the pointer. The age is *inside* the open button because it is part of the click
    // target — the whole line opens the session — and the actions are beside it because they cannot
    // be.
     ".sidebar li.session { display: flex; align-items: center; border-radius: var(--radius-sm); }",
    ".sidebar li.session:hover { background: var(--surface); }",
    // The row the page is already showing: a weight, a pale accent wash, and a bar down its left
    // edge. Three marks rather than one, because each answers a different distance — the bar is what
    // makes the row findable while scanning, the weight is what makes the name readable once it is
    // found, and the wash is what ties the two together. The wash cannot carry it alone: any fill
    // dark enough to be seen at a glance drops the age sitting on it under 4.5:1.
     ".sidebar li.session.current { background: var(--accent-soft); }", ".sidebar li.session.current::before { content: ''; position: absolute; left: 0; top: 5px; bottom: 5px; width: 2px; border-radius: 2px; background: var(--accent); }",
    // The label takes everything the age does not, so the ages form one column at the trailing edge
    // instead of each trailing its own name by the length of that name.
     ".sidebar li.session button.open { flex: 1 1 auto; width: auto; display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1) var(--space-2); }",
    // The row owns the hover fill; the button inside it must not paint a second one on top.
     ".sidebar li.session button.open:hover { background: transparent; }", ".sidebar li.session .label { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
    ".sidebar li.session .age { flex: 0 0 auto; color: var(--muted); font-size: var(--text-xs); font-variant-numeric: tabular-nums; }",
    ".sidebar li.session.current .label { font-weight: 600; }",
    // The two quiet things on the selected row, in the grey that wash requires.
     ".sidebar li.session.current .age { color: var(--muted-strong); }", ".sidebar li.session.current button.rename, .sidebar li.session.current button.remove { color: var(--muted-strong); }",
    // Present but quiet. Revealed under the pointer, and on focus: `:focus-within` matches as soon
    // as the row's own button is focused, so the actions are laid out before the next Tab looks for
    // them — which is what lets them be `display: none` and still be reachable without a mouse.
     ".sidebar .acts { flex: 0 0 auto; display: none; align-items: center; gap: var(--space-1); padding-right: var(--space-1); }",
    ".sidebar li.session:hover .acts, .sidebar li.session:focus-within .acts { display: inline-flex; }",
    ".sidebar li.session:hover .age, .sidebar li.session:focus-within .age { display: none; }",
    // A screen with no hover has no gesture that could reveal them, so there they are simply there.
     "@media (hover: none) { .sidebar .acts { display: inline-flex; } .sidebar li.session .age { display: none; } }",
    ".sidebar button.rename, .sidebar button.remove { flex: 0 0 auto; width: auto; padding: var(--space-1); border-color: transparent; color: var(--muted); }",
    ".sidebar button.rename:hover, .sidebar button.rename:focus-visible { color: var(--fg); }",
    // Both controls are quiet by *colour* rather than by fading out. `--muted` on the page
    // background is 4.9:1, which is legible without competing with the label; an opacity fade on top
    // of that measures about 1.7:1, under the 3:1 that a non-text control needs. Delete turns red
    // only under the pointer, which is what separates it from the rename beside it without making
    // the whole column shout.
     ".sidebar li.session:hover button.remove, .sidebar button.remove:focus-visible { color: var(--danger); }",
    // The keyboard's own way into a row that has none of the pointer's affordances.
     ".sidebar button:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }",
    "@media (prefers-reduced-motion: reduce) { .sidebar .chev { transition: none; } }",
    // The running marker sits inside the row, before the label, because that is where the eye
    // already is when it is scanning the list for something that is happening.
     ".sidebar .dot { flex: 0 0 auto; width: .45rem; height: .45rem; border-radius: 50%; background: var(--ok); animation: pulse 1.2s ease-in-out infinite; }",
    // ── deleted, and the way back ───────────────────────────────────────────
     ".undo { display: flex; align-items: center; gap: var(--space-2); margin-top: var(--space-2); padding: var(--space-2); border: 1px solid var(--line-strong); border-radius: var(--radius-sm); font-size: var(--text-sm); }",
    ".undo .label { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); }",
    // Qualified with the sidebar on purpose. The plain `.undo button` loses to `.sidebar button`,
    // which sets `width: 100%` further down the sheet — equal specificity, later wins — and a button
    // that takes the whole row squeezes the label beside it to nothing. The label is the part that
    // says *what* was deleted, so losing it loses the confirmation.
     ".sidebar .undo button { flex: 0 0 auto; width: auto; border-color: var(--line-strong); padding: var(--space-1) var(--space-2); }",
    ".sidebar .rename-form { flex: 1 1 auto; min-width: 0; }", ".sidebar .rename-form input { width: 100%; font: inherit; color: inherit; background: var(--bg); border: 1px solid var(--accent); border-radius: var(--radius-sm); padding: var(--space-1) var(--space-2); }",
    ".sidebar .empty { color: var(--muted); padding: 0 var(--space-2); }", ".sidebar .meta { color: var(--muted); font-size: var(--text-xs); padding: 0 var(--space-2) var(--space-2); }",
    // Hidden wherever the navigation is beside the conversation, which is everywhere wide enough for
    // both. The narrow rule at the bottom of this stylesheet is what shows it.
     "#nav-toggle { display: none; }", "@keyframes pulse { 50% { opacity: .25; } }",
    // ── controls ────────────────────────────────────────────────────────────
     "button { font: inherit; color: inherit; background: transparent; border: 1px solid var(--line-strong); border-radius: var(--radius); padding: var(--space-2) var(--space-4); cursor: pointer; }",
    "button:hover { background: var(--surface); }", "button:disabled { opacity: .45; cursor: default; }",
    "button.primary { border-color: var(--accent); color: var(--accent); }", "button.ghost { border-color: transparent; color: var(--muted); }",
    ".sidebar button { display: block; width: 100%; text-align: left; padding: var(--space-2) var(--space-2); border-color: transparent; border-radius: var(--radius-sm); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
    ".sidebar button:hover { background: var(--surface); }", ".sidebar button.new { color: var(--muted); font-size: var(--text-sm); padding: var(--space-1) var(--space-2); }",
    // The way past the cap, in the same quiet register as the row it follows: it is a continuation
    // of the list, not a control competing with it.
     ".sidebar button.more { color: var(--muted); font-size: var(--text-xs); padding: var(--space-1) var(--space-2); }",
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
    // The pick row on top, the path row beneath it. The field is the half that shrinks; `Add` keeps
    // its width, or a long path would squash it to an ellipsis.
     ".add-workspace { display: flex; flex-direction: column; gap: var(--space-1); margin-top: var(--space-2); padding: 0 var(--space-2); }",
    ".add-workspace form { display: flex; gap: var(--space-1); }", ".add-workspace input { flex: 1 1 auto; min-width: 0; font: inherit; font-size: var(--text-sm); color: inherit; background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: var(--space-1) var(--space-2); }",
    ".add-workspace button { flex: 0 0 auto; width: auto; border-color: var(--line-strong); padding: var(--space-1) var(--space-2); }",
    ".add-workspace .pick { width: 100%; }",
    // ── conversation ────────────────────────────────────────────────────────
     ".exchange { margin-bottom: var(--space-5); }", ".user { background: var(--surface); border-radius: var(--radius-lg); padding: var(--space-3) var(--space-4); margin-bottom: var(--space-3); white-space: pre-wrap; }",
    ".user > :first-child, .text > :first-child { margin-top: 0; }", ".user > :last-child, .text > :last-child { margin-bottom: 0; }",
    ".blocks > * { margin-bottom: var(--space-3); }", ".text { white-space: normal; }",
    // ── the turns that were not rendered ────────────────────────────────────
    // At the top of the transcript, which is where they would have been, and quiet: it is a way
    // back for the reader who wants it, not a decision to make on the way in.
     ".earlier { margin-bottom: var(--space-4); text-align: center; }", ".earlier button { font-size: var(--text-sm); color: var(--muted); border-color: var(--line); border-radius: var(--radius); padding: var(--space-1) var(--space-4); }",
    ".earlier button:hover { color: var(--fg); border-color: var(--line-strong); }",
    ".blocks details { border-left: 2px solid var(--line); padding-left: var(--space-3); }",
    ".blocks details.tool > summary { font-family: var(--mono); }", ".blocks details.compaction { border-left-style: dashed; }",
    // A running tool is the same block as a finished one — same arguments, same body, same colours —
    // with a clock in its summary. Deliberately not given a look of its own: a block that changes
    // appearance when the tool ends reads as a different element appearing, and the reader has to
    // re-find what they were watching. The clock and the `running…` line are the whole signal.
    //
    // Tabular figures, though, because that number changes every second and a proportional one makes
    // the line twitch as the digits change width — `age_from` says `9s`, then `1m 30s`.
     ".blocks details.tool.running time { font-variant-numeric: tabular-nums; }",
    // ── reasoning while it is arriving ──────────────────────────────────────
    // The same box as a finished one, so a block that becomes a `<details>` when the turn ends does
    // not move. It is a `div` because the live shape needs three states and `<details>` has two.
     ".blocks .thinking.live { border-left: 2px solid var(--line); padding-left: var(--space-3); }",
    ".blocks .thinking.live > .head { display: block; width: 100%; text-align: left; font: inherit; font-size: var(--text-sm); color: var(--muted); background: none; border: 0; padding: var(--space-1) 0; cursor: pointer; }",
    // The affordance a `<summary>` gets for free from its disclosure marker. It points down when
    // there is more to show and up when there is not, which is the direction the content goes.
     ".blocks .thinking.live > .head::after { content: ' ▸'; }", ".blocks .thinking.live[data-expanded] > .head::after { content: ' ▾'; }",
    // Clipped to the newest lines. `overflow: hidden` alone would keep the *oldest* ones, which is
    // the wrong end: the reader is following the newest thought. Anchoring the flex column to its
    // end is what makes the overflow fall off the top, where it is hidden.
    //
    // Measured in Chrome rather than assumed: with `--peek-lines: 3` and 12 lines of text, the box
    // is 70.68px against a 23.56px line height — exactly three lines — and the top of the box is the
    // first character of line 10, so the three on show are the newest three. That combination
    // (`justify-content: flex-end` beside an overflowing box) is the one part of this file a unit
    // test cannot check, so if it is ever "fixed" to clip the bottom instead, check which end of the
    // reasoning is disappearing before trusting the box height.
     ".blocks .thinking.live > .body { display: flex; flex-direction: column; justify-content: flex-end; max-height: calc(var(--peek-lines) * var(--leading) * 1em); overflow: hidden; white-space: pre-wrap; }",
    // Expanded: the box stops being a box. `display` as well as `max-height`, because a flex
    // container would keep the column layout for the markdown that a mid-stream refresh may hold.
     ".blocks .thinking.live[data-expanded] > .body { display: block; max-height: none; }",
    // ── markdown body: most of what is on the page ──────────────────────────
    // The elements cmark emits that the tokens above do not cover. Everything here takes its
    // sizes from the scale rather than the browser's, because a default h3 (17.8px) inside an
    // answer reads as more important than the interface around it, and a default list indent
    // (40px) is a number that exists nowhere else on the page.
    //
    // Headings are told apart by weight and size *within* the scale, not by leaving it: the
    // largest is --text-base, the same size as prose. Hierarchy comes from weight and space.
    //
    // The measure is applied to the *answer* only, not to the reader's own message. An answer is
    // read line by line and a 120-character line loses the reader's place; a prompt was just
    // typed by the person looking at it, and giving it a narrower box than the answer next to it
    // would read as a layout accident.
     ".text > :is(p, h1, h2, h3, h4, h5, h6, ul, ol, blockquote), .body > :is(p, h1, h2, h3, h4, h5, h6, ul, ol, blockquote) { max-width: var(--measure); }",
    ".text :is(h1, h2, h3, h4, h5, h6), .body :is(h1, h2, h3, h4, h5, h6) { margin: var(--space-4) 0 var(--space-2); line-height: 1.3; }",
    ".text :is(h1, h2), .body :is(h1, h2) { font-size: var(--text-base); font-weight: 650; }",
    ".text :is(h3, h4), .body :is(h3, h4) { font-size: var(--text-sm); font-weight: 650; }",
    ".text :is(h5, h6), .body :is(h5, h6) { font-size: var(--text-sm); font-weight: 600; color: var(--muted); }",
    // The first heading in an answer should not float away from the block above it, and the
    // same for the last paragraph, which is why these two rules come after the margins above.
     ".text > :first-child, .body > :first-child { margin-top: 0; }", ".text > :last-child, .body > :last-child { margin-bottom: 0; }",
    ".text p, .body p { margin: var(--space-3) 0; }", ".text :is(ul, ol), .body :is(ul, ol) { margin: var(--space-2) 0; padding-left: var(--space-5); }",
    ".text li, .body li { margin: var(--space-1) 0; }", ".text li > :is(ul, ol), .body li > :is(ul, ol) { margin: 0; }",
    // A quote is marked by a rule and a lower weight of colour, which is what makes it
    // distinguishable from a paragraph that merely happens to be indented.
     ".text blockquote, .body blockquote { margin: var(--space-3) 0; padding: 0 0 0 var(--space-3); border-left: 2px solid var(--line-strong); color: var(--muted); }",
    ".text blockquote > :first-child, .body blockquote > :first-child { margin-top: 0; }",
    ".text blockquote > :last-child, .body blockquote > :last-child { margin-bottom: 0; }",
    // cmark wraps a table in `role=region`, and that wrapper is where the sideways scroll
    // belongs: a wide table must scroll rather than widen the column past the window.
     ".text [role=region], .body [role=region] { margin: var(--space-3) 0; overflow-x: auto; }",
    ".text table, .body table { border-collapse: collapse; font-size: var(--text-sm); }",
    ".text :is(th, td), .body :is(th, td) { border: 1px solid var(--line); padding: var(--space-1) var(--space-2); text-align: left; vertical-align: top; }",
    ".text th, .body th { background: var(--surface); font-weight: 600; }",
    // Code in an answer is copied, not read as prose: it keeps its own line breaks and scrolls
    // sideways rather than being broken in the middle of a token.
     ".text pre, .body pre { white-space: pre; overflow-wrap: normal; tab-size: 4; }",
    ".text pre code, .body pre code { font-size: var(--text-sm); }",
    // A copy button floating over the corner of a code block. Visible rather than shown on hover:
    // a touch screen has no hover, and a control that exists only while a mouse is over it is one
    // a reader has to find by accident. Opaque, so a long line scrolling under it stays hidden.
     ".code-block { position: relative; margin: var(--space-2) 0; }", ".code-block pre { margin: 0; }",
    // The controls float over the corner of the block, so the block reserves room for them. Without
    // the reserve, a line long enough to scroll ends *under* the button: the last characters of the
    // longest line in the answer, permanently covered and impossible to scroll clear of. Reserving
    // the space means the scrollable box stops short of the controls, so nothing can reach them.
     ".code-block pre { padding-right: var(--code-controls); }", ".code-tools { position: absolute; top: var(--space-1); right: var(--space-1); display: flex; align-items: center; gap: var(--space-1); }",
    ".code-tools .code-lang { font-family: var(--mono); font-size: var(--text-xs); color: var(--muted); }",
    ".code-tools .copy { white-space: nowrap; font-size: var(--text-xs); line-height: 1.2; padding: var(--space-1) var(--space-2); border-radius: var(--radius-sm); border: 1px solid var(--line); background: var(--bg); color: var(--muted); }",
    ".code-tools .copy:hover { color: var(--fg); border-color: var(--line-strong); }",
    ".blocks .pending { color: var(--muted); font-size: var(--text-sm); }", ".blocks .result.error pre { border-left: 3px solid var(--danger); }",
    ".blocks .image { color: var(--muted); font-size: var(--text-sm); }",
    // A turn's figures, under its reply. Muted and small: a reader looks for it after the
    // answer, not instead of it. The line is a button, because the breakdown behind it had nowhere
    // to be read; it is styled back to looking like a caption so that nothing about the page moves
    // when the one thing under an answer becomes clickable.
     ".turn-stats { color: var(--muted); font-size: var(--text-sm); font-family: var(--mono); }",
    ".turn-stats .stats-open { display: inline; font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; text-align: left; text-decoration: underline dotted; text-underline-offset: .2em; }",
    ".turn-stats .stats-open:hover { color: var(--fg); }",
    // Hidden by default and shown by the attribute, rather than carrying a `hidden` of its own: the
    // attribute is the state, and `ui/assets.mbt` has one handler that flips it for every
    // disclosure on the page that is not a `<details>`.
     ".turn-stats .stats-detail { display: none; margin-top: var(--space-2); padding: var(--space-2) var(--space-3); border: 1px solid var(--line); border-radius: var(--radius); background: var(--surface); }",
    ".turn-stats .stats-detail[data-expanded] { display: block; }",
    // Two columns, filled by the `dt`/`dd` pairs alternating into them. The values are set in
    // tabular figures so a column of numbers lines up on the point.
     ".turn-stats .stats-rows { display: grid; grid-template-columns: max-content 1fr; gap: 0 var(--space-3); margin: 0; } ",
    ".turn-stats dt { color: var(--muted); }", ".turn-stats dd { margin: 0; font-variant-numeric: tabular-nums; }",
    // ── the fold over a turn's working ──────────────────────────────────────
    // Takes the same left rule as the folds inside it, so the nesting reads as containment rather
    // than as another block at the same level.
     ".blocks details.work > summary { color: var(--muted); font-size: var(--text-sm); } ",
    ".blocks details.work { margin-bottom: var(--space-4); }",
    // An interrupted turn, at the end of the transcript. Bordered rather than filled: it is a note
    // about what did not happen, and it must read as distinct from the conversation itself.
     ".interrupted { border: 1px dashed var(--line-strong); border-radius: var(--radius-lg); padding: var(--space-3) var(--space-4); margin-bottom: var(--space-3); color: var(--muted); font-size: var(--text-sm); }",
    ".interrupted p { margin: 0 0 var(--space-2); }", ".interrupted b { color: inherit; font-weight: 600; }",
    ".interrupted .btn-row { display: flex; gap: var(--space-2); }", ".interrupted button { font: inherit; color: inherit; background: var(--bg); border: 1px solid var(--line-strong); border-radius: var(--radius); padding: var(--space-1) var(--space-3); cursor: pointer; }",
    // ── status + composer ───────────────────────────────────────────────────
     ".status { color: var(--muted); font-size: var(--text-sm); padding: 0 var(--space-4) var(--space-1); text-align: center; }",
    "#composer { position: sticky; bottom: 0; display: flex; gap: var(--space-2); padding: var(--space-3) var(--space-4); background: var(--bg); border-top: 1px solid var(--line); }",
    // ── the empty conversation ──────────────────────────────────────────────
    // Centred and bounded, because this is the one thing on an otherwise blank page and a line of
    // text stranded at the top-left of a large empty area reads as a rendering fault.
     ".welcome { max-width: 34rem; margin: var(--space-6) auto; padding: 0 var(--space-4); text-align: center; color: var(--muted); }",
    ".welcome .lead { margin: 0 0 var(--space-4); font-size: var(--text-base); }",
    ".welcome .examples { display: flex; flex-direction: column; gap: var(--space-2); align-items: stretch; }",
    ".welcome .example { text-align: left; color: var(--fg); border-color: var(--line); border-radius: var(--radius); padding: var(--space-2) var(--space-3); }",
    ".welcome .example:hover { border-color: var(--line-strong); background: var(--surface); }",
    ".welcome .hint { margin: var(--space-4) 0 0; font-size: var(--text-sm); }",
    ".welcome .key { font-family: var(--mono); font-size: var(--text-xs); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: 0 .3rem; background: var(--surface); color: var(--fg); }",
    // ── the command list ────────────────────────────────────────────────────
    // Below the composer and above the box, taking the full width of the form so its rows line up
    // with what the reader is typing.
     "#commands { flex: 1 0 100%; order: -1; display: flex; flex-direction: column; border: 1px solid var(--line); border-radius: var(--radius); overflow: hidden; }",
    // Bounded, and scrolling inside that bound: a workspace can hold a dozen skills, and a menu
    // taller than the window is not a menu. A share of the viewport rather than a fixed height,
    // because the composer it opens above is itself a share of one.
     "#commands { max-height: min(45vh, 22rem); overflow-y: auto; }", "#commands[hidden] { display: none; }",
    // One line per row: the command keeps its width, the description takes what is left and
    // ellipsises. A wrapped description cannot be scanned, which is the only thing a list of
    // commands is for.
     "#commands .command { display: flex; align-items: baseline; gap: var(--space-3); width: 100%; text-align: left; white-space: nowrap; border: 0; border-radius: 0; border-bottom: 1px solid var(--line); padding: var(--space-2) var(--space-3); font-size: var(--text-sm); }",
    "#commands .command:last-child { border-bottom: 0; }", "#commands .command:hover { background: var(--surface); }",
    "#commands .cmd { flex: 0 0 auto; font-family: var(--mono); font-size: var(--text-xs); }",
    "#commands .what { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; color: var(--muted); }",
    "#composer textarea { flex: 1 1 auto; resize: none; font: inherit; color: inherit; background: var(--bg); border: 1px solid var(--line-strong); border-radius: var(--radius); padding: var(--space-2) var(--space-3); }",
    // The model picker sits at the bottom of the composer's trailing edge. It is last in the DOM
    // so that a narrow window wraps it under the buttons rather than squeezing the textarea.
     "#model-picker { flex: 0 0 auto; align-self: flex-end; max-width: 12rem; font: inherit; font-size: var(--text-xs); color: var(--muted); background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: var(--space-1); cursor: pointer; }",
    "#model-picker:hover { color: var(--fg); border-color: var(--line-strong); }",
    "#model-picker:disabled { opacity: .5; cursor: default; }",
    // ── settings ────────────────────────────────────────────────────────────
    // A floating panel rather than a sidebar section: it is a place a reader goes, not a thing
    // they watch, and the sidebar is already the busiest column on the page. Anchored to the
    // right of the bar, so opening it does not move anything the reader was reading.
     "details.settings { position: relative; font-size: var(--text-sm); }", "details.settings > summary { list-style: none; cursor: pointer; color: var(--muted); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: .1rem .5rem; white-space: nowrap; }",
    "details.settings > summary::-webkit-details-marker { display: none; }", "details.settings[open] > summary { color: var(--fg); border-color: var(--line-strong); }",
    // The panel is taken out of flow, so a long skill list cannot push the conversation down.
     ".settings-body { position: absolute; right: 0; top: calc(100% + var(--space-2)); z-index: 3; width: min(34rem, calc(100vw - 2rem)); max-height: 75vh; overflow-y: auto; text-align: left; background: var(--bg); border: 1px solid var(--line-strong); border-radius: var(--radius); box-shadow: 0 12px 32px rgba(0, 0, 0, .18); padding: var(--space-4); }",
    ".settings-block { margin-bottom: var(--space-4); }", ".settings-block > h3 { margin: 0 0 var(--space-2); font-size: var(--text-xs); font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--muted); }",
    ".settings-block > h3 .count { text-transform: none; letter-spacing: 0; }", ".settings .facts { display: grid; grid-template-columns: max-content 1fr; gap: var(--space-1) var(--space-3); margin: 0; }",
    ".settings .facts dt { color: var(--muted); }", ".settings .facts dd { margin: 0; font-family: var(--mono); overflow-wrap: anywhere; }",
    ".settings .hint { color: var(--muted); font-size: var(--text-xs); margin: var(--space-2) 0 0; }",
    ".settings .key-state { display: flex; align-items: baseline; gap: var(--space-2); margin-bottom: var(--space-2); }",
    ".settings .key-state .state { color: var(--muted); }", ".settings .key-form { display: flex; flex-direction: column; gap: var(--space-2); }",
    // The limits: a name, a box and where the value came from, one per row. The source is on the
    // row rather than in a tooltip because "a flag is pinning this" is the answer to "why did
    // saving not change anything".
     ".settings .limit-list { display: flex; flex-direction: column; gap: var(--space-1); }",
    ".settings label.limit { display: flex; align-items: center; gap: var(--space-2); padding: var(--space-1); border: 1px solid var(--line); border-radius: var(--radius-sm); }",
    ".settings label.limit .limit-name { flex: 1 1 auto; min-width: 0; }", ".settings label.limit .limit-value { display: inline-flex; align-items: center; gap: var(--space-2); font-family: var(--mono); font-size: var(--text-xs); }",
    ".settings label.limit input { width: 6rem; font: inherit; font-size: var(--text-sm); color: inherit; background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: var(--space-1) var(--space-2); }",
    ".settings label.limit input::placeholder { color: var(--muted); }",
    // A pinned limit reads as pinned: a dimmed row with a lock-like note, not an input that looks
    // like the others and silently ignores what is typed into it.
     ".settings label.limit.pinned { border-style: dashed; color: var(--muted); }",
    ".settings label.limit.pinned input { background: var(--surface); color: var(--muted); }",
    ".settings label.limit .source { color: var(--muted); white-space: nowrap; }",
    ".settings .key-form input { font: inherit; font-size: var(--text-sm); color: inherit; background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: var(--space-1) var(--space-2); }",
    // The instructions block: what is in force, then what it says, then the textarea holding the
    // fallback. The preview is monospace and scrolls rather than growing, so a long file cannot
    // make the panel taller than the window it is floating over.
     ".settings .instruction-source { margin: 0 0 var(--space-2); }", ".settings .instruction-source b { font-family: var(--mono); font-weight: 600; }",
    ".settings .instruction-preview { max-height: 10rem; overflow: auto; margin: 0 0 var(--space-3); padding: var(--space-2); font-family: var(--mono); font-size: var(--text-xs); white-space: pre-wrap; overflow-wrap: anywhere; background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-sm); }",
    ".settings .agents-form { display: flex; flex-direction: column; gap: var(--space-2); }",
    ".settings .agents-label { color: var(--muted); font-size: var(--text-xs); }",
    ".settings .agents-form textarea { font: inherit; font-size: var(--text-sm); color: inherit; background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: var(--space-2); resize: vertical; }",
    ".settings .btn-row { display: flex; align-items: center; gap: var(--space-2); }",
    ".settings .btn-row .hint { margin: 0; }", ".settings .skill-list { max-height: 16rem; overflow-y: auto; border: 1px solid var(--line); border-radius: var(--radius-sm); }",
    ".settings label.skill { display: flex; gap: var(--space-2); align-items: flex-start; padding: var(--space-2); border-bottom: 1px solid var(--line); cursor: pointer; }",
    ".settings label.skill:last-child { border-bottom: 0; }", ".settings label.skill:hover { background: var(--surface); }",
    // Off is shown by colour as well as by the unchecked box: the box alone is a small mark to
    // scan a column of.
     ".settings label.skill.off { color: var(--muted); }", ".settings label.skill.off b { text-decoration: line-through; }",
    ".settings .skill-text { min-width: 0; }", ".settings .skill-text b { display: block; }",
    ".settings .skill-text i { display: block; font-style: normal; font-size: var(--text-xs); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
    ".settings .skill-text .where, .settings .skill-text .missing { display: block; font-family: var(--mono); font-size: var(--text-xs); color: var(--muted); overflow-wrap: anywhere; }",
    ".settings .skill-text .missing { color: var(--danger); }", ".settings .btn-row { margin-top: var(--space-2); }",
    ".settings button { width: auto; padding: var(--space-1) var(--space-3); }",
    // ── narrow screens ──────────────────────────────────────────────────────
    // The page is a sidebar beside a column, and the sidebar is a fixed 17rem of it. That is a
    // fine arrangement with room and a bad one without: at 960px the column is still comfortable,
    // and below that the conversation — the thing the page is for — is what pays. So under that
    // width the two stack and the navigation folds behind a button.
    //
    // The breakpoint is in `rem` so it follows the reader's text size rather than assuming the
    // default, which is the same reason the type scale is in `rem`.
     "#composer { flex-wrap: wrap; }",
    // Demanding a minimum width is what makes the composer fold rather than squeeze: without a
    // basis the textarea shrinks to nothing and the buttons keep their size, which is the wrong
    // thing to protect — the reader came to type.
     "#composer textarea { flex: 1 1 14rem; }", "@media (max-width: 59.99rem) {",
    "  .layout { flex-direction: column; gap: 0; }",
    // One sticky header on a narrow screen, and it is the navigation. A reader halfway down a long
    // answer is far more likely to want another session than another look at the cost, and the two
    // cannot both stick to the top without covering each other. Opaque, because the bar scrolls
    // underneath it on the way past.
     "  .sidebar { position: sticky; top: 0; z-index: 3; flex: none; width: auto; max-height: none; overflow: visible; padding: var(--space-2) var(--space-4); background: var(--bg); border-bottom: 1px solid var(--line); }",
    // Opened, it covers the page rather than pushing it down — its own scroll, bounded, so a long
    // session list does not become a very long page above the conversation.
     "  .sidebar.open { max-height: 80vh; overflow-y: auto; }", "  .bar { position: static; }",
    "  #nav-toggle { display: block; width: auto; text-align: left; color: var(--muted); border-color: var(--line); padding: var(--space-1) var(--space-3); }",
    "  #nav-toggle[aria-expanded=true] { color: var(--fg); border-color: var(--line-strong); }",
    // Everything except the button is folded away until it is asked for. Written as "> :not(...)"
    // rather than by naming the three panels, so a region added later folds with the rest.
     "  .sidebar > :not(#nav-toggle) { display: none; }", "  .sidebar.open > :not(#nav-toggle) { display: block; }",
    "  #transcript { padding: var(--space-4) var(--space-4) var(--space-5); }", "}",
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
  el(Span, attrs~, children=[txt(label), el(B, children=[txt(value)])])
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
  // Below a couple of percent the bar carries no information and still draws the eye — an empty
  // conversation showed a meter at 0.19% full, which reads as a fault rather than as a number. The
  // figure stays; only the bar goes.
  let children : Array[Node] = [txt(label), el(B, children=[txt(value)])]
  if percent >= 0.02 {
    children.push(
      el(Span, attrs=[cls("meter")], children=[
        el(
          I,
          attrs=[attr("style", "width: \{(percent * 100.0).round().to_int()}%")],
          children=[],
        ),
      ]),
    )
  }
  el(
    Span,
    attrs=[
      cls(if warn { "chip warn" } else { "chip" }),
      attr("title", if detail != "" { detail } else { "\{label} \{value}" }),
    ],
    children~,
  )
}

///|
/// A section of the sidebar.
pub fn panel(title : String, children : Array[Node]) -> Node {
  el(Section, attrs=[cls("panel")], children=[
    el(H2, children=[txt(title)]),
    frag(children),
  ])
}
