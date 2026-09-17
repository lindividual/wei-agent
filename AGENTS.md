# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

- **The native macOS shell is the main front end**; `ui/` (the web UI) is paused
  (see `docs/adr/0007-macos-is-the-main-front-end.md`). Work in `macos/` splits
  into a MoonBit side (`macos/appffi/`, built into `macos/vendor/libwei.a` by
  `macos/build-moonbit.sh`) and a Swift side (`macos/WeiShell/`). Facts about the
  conversation belong in the MoonBit side; facts about the window belong in the
  Swift side.

- **Before touching `macos/`, skim `docs/macos-pitfalls.md`.** It is a
  symptom/cause/fix table covering the build loop, SwiftUI, input methods,
  platform-API discovery, and how to drive and test the app. Its most expensive
  entry is a process one: a MoonBit-side change needs
  `macos/build-moonbit.sh` *and* a fresh `macos/make-app.sh` before the app you
  open contains it.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## Design principles (WWDC26 · Principles of great design)

Think roughly in this order; there is no formula, and principles often trade against each other.

1. **Purpose** — Every feature asks for the user's time, attention, and trust. Choosing what to build is often what *not* to include.
2. **Agency** — Put people in control; offer choices; never stand in the way of what someone is trying to do.
3. **Forgiveness** — Make mistakes easy to undo; confirm destructive actions; interrupt only to prevent a big mistake.
4. **Responsibility** — Act in people's best interest. Ask for data only when necessary, at the right moment, with context. Keep people safe.
5. **Familiarity** — Build on what people already know; be consistent; things that look the same should behave the same.
6. **Flexibility** — Support real contexts and a range of abilities; let people personalize where no single layout fits everyone.
7. **Simplicity** — Strip the unnecessary so the core purpose shines. Simple ≠ minimal. Frictionless: plain language, fewer steps, clear hierarchy, every element earns its place. You've arrived when you have *exactly enough*.
8. **Craft** — Attention to detail; polished and responsive; craft inspires confidence.
9. **Delight** — Choose the emotion you want people to feel and reinforce it — not by adding confetti.


## UX writing

The recurring advice is **simplify**.

- Remove filler (needless adverbs/adjectives, "oops", "sorry") and redundant
  wording. Ask of every word: *does it add value?*
- Avoid repetition — economy of language.
- Lead with the why/benefit, then the action.
- Keep one consistent term per concept across the whole UI.
- Read your writing out loud to find filler.

## Writing for people

- Clarity first: as long as it needs to be, as short as it can be.
- Short, punchy sentences; explain technical things like to a friend.
- Onboarding: brevity; give the "why" and what to expect, don't front-load text.
- Notifications are interruptive — only send when they must go now, save someone
  from opening the app, and say something new.
- Write inclusively.

## 控制论思维

控制论研究的是**系统怎么被导向目标**——靠反馈，而不是靠一次规划到位。

- **反馈回路是基本单位**：输出取回来当输入，系统才能自我调节。没有反馈的系统只是开环，偏差只会越积越大。
- **负反馈求稳，正反馈放大**：负反馈抵消偏差、维持稳定；正反馈放大偏差、带来增长或崩溃。先分清手里这个是哪种，再决定怎么用。
- **先问「我怎么知道它在变好」**：量不出来的东西，无从判断，也无从改进。
- **回路要短、快、便宜**：回路越长，偏差积累越久，越容易过冲震荡——小步走、勤看结果，比一次做到底更稳。
- **必要多样性（Ashby 定律）**：只有多样性才能吸收多样性——控制器能应对的状态数，不得少于被控系统的变化数。**手段太简单，就管不住复杂的对象**。要么提高手段的多样性，要么降低对象的复杂度，没有第三条路。
- **二阶控制论**：观察者本身在系统之内，观察从不中性；你一动手，系统的状态就变了。模型必须跟着现实更新。

## 管线思维

参考游戏行业的「**制作管线**」（production pipeline）：它不是一个流程图，而是**把每一段的产物、标准和验收都定死**，让最终品质不取决于「这次是谁做的」。

- **每一段都要有明确产物和验收标准**——标准先行，才谈得上稳定交付。
- **品质靠标准，不靠手感**：凭感觉做是作坊，能让人换着做还一致才是工业化。
- **上游标准决定下游产出**：贴图像素比、网格精度比这类上游规范，直接约束下游能做成什么样；上游不定，下游必然返工。
- **越往后改越贵**：预制作的全部意义就是把昂贵阶段的猜测降到最低——在便宜的地方多试，在贵的地方少改。
- **要能溯源到段**：按工序检查，哪一段出问题就改哪一段，而不是整批推倒重做。
- **段间解耦才能并行**：把各段的依赖打断（如模型与贴图解耦），工序就能并行推进，也可分工给别人。
- **复用率是要主动管的**：只出现一次的非关键产物，砍掉或合并。