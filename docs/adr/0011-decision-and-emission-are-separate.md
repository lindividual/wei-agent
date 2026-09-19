# ADR-0011：事件的决定与发射分开，壳的出口是一个值；`Shell` 由「已读到的事实」组装

- **状态**：已采纳，**决策 1–7 已实现**；剩下约 48 个 `Shell::` 方法体仍直接做真 IO，那部分未迁移
  （见文末「已知缺口」）
- **日期**：2026-09-19
- **相关**：`macos/appffi/app.mbt`、`macos/appffi/sessions.mbt`、`macos/appffi/settings.mbt`、
  `macos/appffi/ffi.mbt`、`macos/appffi/host_stub.c`、`macos/appffi/app_wbtest.mbt`、
  `macos/WeiShell/Sources/WeiModel/Event.swift`、`docs/adr/0003-requests-module.md`（同一条原则，Web 那一侧）、
  `docs/adr/0007-macos-is-the-main-front-end.md`

## 背景

`macos/appffi` 是**唯一在用的前端**，4,384 行、一个 package。它的 50 个 `Shell::` 方法、整个命令循环、
24 个发射点，**一行都没有被测过**。

三条互相独立的证据，都能量：

| 证据 | 数字 |
|---|---|
| 测试里 `Shell::` 出现次数 | **0**（70 个测试） |
| 测试里 `emit(` 出现次数 | **0** |
| `moon coverage analyze`：appffi 未覆盖行 | **437**（`app.mbt` 221 / `sessions.mbt` 184 / `settings.mbt` 32），每个未覆盖块的顶部都是 `Shell::` 方法或只有它调用的 helper |

原因不是疏忽，是一个**被绕过去的设计决定**，而且它留下了物证：`host_stub.c` 里有一个空的
`wei_emit`，注释原文是「`moon test` links nothing but MoonBit, and a missing symbol is a link error
rather than a test result — so there is a weak default here」。也就是说：**测试里那个喇叭是关着的，
而这个空实现就是为了让这件事不报错。**

### 代价是实测出来的，不是理论上的

把生产代码里一个字段名改掉、一个测试文件都不碰：

```
say_tool 里  ("detail", ...) → ("arg", ...)
    moon test -p macos/appffi   →   Total tests: 77, passed: 77, failed: 0
```

Swift 侧按名字解 `detail`。**线上会坏，CI 会鼓掌。** 而 `app_wbtest.mbt` 里那条名叫
「a tool row carries its whole state」的测试，和 `say_tool` 各写了一遍同样的六个字段名 ——
两个手写的字面量**不可能互相矛盾**，所以它钉的是一个没人核对过的形状。

顺着这条线查出三个**真实的字段错误**，全部只存在于测试里：

| 事件 | 测试钉的 | 生产/宿主真正用的 | 后果 |
|---|---|---|---|
| `session` | `"path"` | `"session"` | 键名根本不存在。宿主靠 `session` 路由，`path` 是个未知字段，静默忽略——**会话归属丢掉** |
| `settings` | 6 个字段 | 9 个字段 | 缺 `skills` / `instructions` / `instructions_source` / `limits`，整个面板缺一半 |
| `user`/`tool`/`blocks`/`note`/`ready`/`reply` | `event(...)` | `session_event(...)` | 缺路由字段 `session`。不崩，**串**：后台 turn 的工具行画进当前会话 |

第三条正是 `session` 这个字段存在的理由，原文：「a delta it cannot place is a delta it would have to
write into whatever happens to be on screen」。测试自己造的形状，恰恰就是没有它。

### 为什么「把决定抽出来」这条路被卡住

ADR-0003 在 Web 那一侧做过同一件事（`main` 433 → 161 行），并且写明回报是「interface 就是测试面」。
那条路在 macOS 这一侧不可用，有两个具体的堵点：

1. **出口是全局函数。** `emit(event)` → `wei_emit`，写死的 C 符号。没有参数能改变它去哪儿，所以
   「这句话说了什么」在测试里**无法观测**——唯一能做的就是在旁边把同样的话再拼一遍。
2. **`Shell` 造不出来。** 它的唯一构造方式 `Shell::open()` 一边读环境（`HOME`、`DEEPSEEK_BASE_URL`）、
   读 store（`~/.wei/sessions`、pins、jobs、settings）、挑启动目录、打开一个会话，一边拼结构。测试里
   没有世界可以给它读，于是 50 个方法全都够不着。

## 决策

**1. 每个事件一个纯构造函数；测试打真的那个生产者。**

`name_event(...) -> Json` 是决定字段的唯一地方，`say_name(...)` 只剩一行 `self.emit(name_event(...))`。
这不是新形状：仓库里 `models_event`、`usage_event`、`session_snapshot`、`turn_ended_event` 本来就这样，
注释自己写着「split out so the field names can be asserted without a session on disk」。缺的是把它当成
一条**规则**而不是逐函数的手工选择。

**2. 出口是壳的一个值，不是全局函数。**

```moonbit
priv struct Shell {
  ...
  /// Where this shell's facts go.
  out : (Json) -> Unit
}

fn Shell::emit(self : Shell, event : Json) -> Unit { (self.out)(event) }
```

宿主装 `emit`（就是写 `wei_emit` 的那个），测试装一个数组。**调用方和测试跨同一条 seam**——这是
判据，不是修辞：seam 放在哪儿，取决于测试和调用方是不是从同一个地方进来。

26 个 `say_*` / `live_blocks` 因此从自由函数变成 `Shell::` 方法（`Shell::say_sessions`、
`Shell::say_settings` 本来就是这个形状）。24 个发射点全部经由 `Shell::emit` 这**一个**口子。

**3. `Shell` 由「已读到的事实」组装，读世界是另一个函数的活。**

```moonbit
async fn gather() -> World                      // 唯一碰环境/文件系统/进程表的地方
fn Shell::of(world : World, out? = emit) -> Shell   // 纯
async fn Shell::open() -> Shell { Shell::of(gather()) }
```

**4. `World` 的字段是答案，不是问题。**

`start`（那个目录）而不是「该从哪个目录开始」；`session` 和 `path` 而不是「该打开哪个会话」。
一个字段如果命名的是**问题**，就会把读世界重新拽回 `of` 里面——这是这份 ADR 里最容易在半年后
被违反的一条。

**5. 一条命令进，一个判定出：循环体属于可以测的那一边。**

```moonbit
priv enum Keep { Going; Quit }
async fn[X] Shell::handle(self, group, line : String) -> Keep
```

这原本是 `serve` 循环体里的 `match`：36 个 arm，其中好几个在自己注释里写着一个失败模式，而
**一个都断言不了**——因为唯一走到它们的办法是在跑着的 app 里敲键盘。`serve` 现在只剩「读收件箱、
等待、叫停」，即真正属于**进程**的那三件事；「一条命令意味着什么」全部在 `handle` 里，测试递一行
进去、读它说了什么出来。

**6. 判定是值，不是「问一句、顺手说一句」的谓词。**
```moonbit
priv enum Gate { Allowed; Refused(String) }
fn gate(command : Command, busy : Bool) -> Gate
```

这条来自一个已经发生的失败。被替换掉的是 `Shell::idle() -> Bool`：它既回答问题、又写那句拒绝，
所以**问它有副作用**。它的文档注释说它守着「deleting it, renaming it, opening a fresh one in its
place」——而这三条早就被**故意**取消了设闸，每个 arm 旁边都有一段解释为什么。

**规则怎么会飘成这样：** 它表达在「36 个 match arm 里 34 个没写 `if idle()`」里。靠**缺席**表达的
规则，没有人能读出来，而且它已经错过两次——那些解释性的注释就是证据。现在它是一张**穷尽的表**：
新增一个命令，**不在表里分类就编译不过**（实测：把 `Abort` 从表里删掉 → 编译失败）。

一句话的判据：**谓词可以发射，就不能叫谓词。** 决定和「怎么把它说出来」是两件事。

**7. IO 会失败，就必须能回报；谓词不应有异常。**

```moonbit
pub async fn write_session(path : String, text : String) -> Bool   // 曾经是 Unit
pub async fn path_exists(path : String) -> Bool                   // 曾经会 raise
```

这两条是同一件事的两次，做 `fork` 时撞到的，而且都比字面看起来严重：**两处都写了失败处理，但那处理从来
没有被执行过。**

## 理由

- **回收是量出来的，不是感觉出来的。** 把每个生产者的一个字段名改掉，看测试抓不抓得住：
  动手前是 **1/15**，现在是 **9/9**（每条都干净失败，不是 panic）。
- **证伪测试证明这条 seam 是真的。** 行为改动被新测试抓住，这里有三类：删掉 `idle()` 那句解释、
  去掉 `say_jobs` 的去重、把 `Delete` 错当成需要设闸（就是旧文档注释的错误说法）。这些以前
  **没有任何办法测**。
- **穷尽性由编译器执行。** `gate` 是一张覆盖全部 36 个命令的表：漏掉一个命令的归类比漏掉一句话
  严重得多，所以让编译器来管，而不是靠一段注释（实测：把 `Abort` 从表里删掉 → 编译失败）。
- **写下失败模式的人，应该能让机器替他盯。** 一批纯判定的注释里已经写着「错误的答案长什么样」，
  却因为拿不到一个 `Shell` 而无法断言。把它们变成测试之后，逐条改成错误写法，**逐条被抓住**：
  - `gate` 的分类 3/3（含「删掉一个命令的归类 → 编译失败」）；
  - 纯判定 5/5（`session_model`、`session_level`、`model_name`、`retarget`、`interrupted_turn`）；
  - `handle` 的决定 6/6——包括**把 `abort` 改成只置 flag、不再真停命令**，也就是 `docs/macos-pitfalls.md`
    里那个实测 bug 的复现；
  - 拒绝句 8/8（`refuse_deletion` 4/4、`refuse_project_removal` 4/4），包括**把 `exists` 提到最前**
    和**只看第一个 session**两种错法。
- **两个 adapter = 真的 seam。** 宿主一个、测试一个，这就是 LANGUAGE.md 那条判据。
- **这是同一个原则的第二次应用。** ADR-0003 的「interface 就是测试面」在 Web 那一侧已经付过一次回报
  （第一次就抓到一处已经漂移的重复）；这里是把那条原则用在**唯一在用的前端**上。

## 后果

- **wire 一个字节没变。** 字段名、顺序、拼法全部保持，所以宿主不需要跟着改：
  `macos/build-moonbit.sh release` 重建归档后 **Swift 258 个测试全过**。这是最重要的验收——这次重构
  的承诺是「只搬 seam，不改协议」。
- **`.mbti` 无变化**：`Shell`、`Open`、`World` 都是 `priv`，对包外不可见。纯内部重构。
- **`core` 的两条硬约束仍由编译器守着**（`moon check -p core --target js` / `wasm-gc`），本 ADR 没有
  把任何 IO 往 `core` 里放。
- **一处诚实的例外**：`start()` 里 `Shell::open()` 失败那一句，此时还没有壳可以挂 sink，直接调
  `emit(error_event(...))`。注释写明了理由，这是「进程起不来」这唯一的出口。

### 已发现的：两个失败路径根本走不到

做 `fork` 的时候撞到两件同形的事，都比它们字面上看起来严重：两处代码都**写了失败处理，但那处理从来
没有被执行过**。

**一、`write_session` 返回 `Unit`，于是失败无法被表达。** 它内部是 `write_text` → `@fs.write_file`，
失败就 raise；而 raise 会穿过 `fork`、进入命令循环的 task group。结果是：**读者唯一能主动处理的那个失败
（写不进去）是唯一一句没有的句子**。ADR-0010 的第 11 条验收标准写着「失败路径（写不进去）：`say_error`
+ 不切走 + 不留半截行」——而它下面什么都没有。改成返回 `Bool` 以后，那个分支才存在，也才能测。

**二、`path_exists` 在 ENOTDIR 时 raise。** `@fs.exists` 遇到「路径中间那段是个普通文件」时不是
答 `false`，而是抛 `OSError`——而这里有 61 处把它当谓词用。于是 `fork` 在到达它那个（刚做出来的）写失败
分支之前，先死在 `label_of` 里的 `path_exists`。**这是同一件事的两次。**

两条规则：

- **IO 会失败，就必须能回报。** 在 IO 边界上，`Unit` 等价于「从不失败」。
- **谓词不应有异常。** 一个会 raise 的 `exists` 不是一个判断，是一个陷阱；所有把它当 `if` 用的地方
  都埋了一条未声明的错误路径。

### 已发现的：拒绝句几乎全部没有测试

appffi 里有 **20 多条**句子告诉读者「这个命令为什么没发生」。它们是失败命令给的全部——没有错误码、没有
可查的状态，只有一行话——而**几乎每一条都没有测试**。

这是 ADR-0003 在 Web 那侧记过并修过的同一个失败模式（「读者见到的六条拒绝信息里，五条只出现在 `ui/main.mbt`
这一个文件里，而它是唯一没有测试的文件」），在这一侧又长回来了。原因和当初一模一样：**句子和判定写在同一个
调用里**，而那个调用需要一个 `Shell`。

抽出两个纯函数以后，它们成为可断言的：

```moonbit
val refuse_deletion(d : Deletion) -> String?              // 4 句
val refuse_project_removal(named, loads) -> String?      // 3 句
```

两件事值得单独说：

- **顺序是承重的，而且有一条测试只能靠它区分。** `live_jobs` 必须比 `exists` 先问：一个 `npm run dev &`
  比它的文件活得长，先问 `exists` 会把这种会话拒成「already gone」——一句真话，却让读者去找一个文件，而真正
  该被告诉的那个进程继续跑着、屏幕上没有任何东西指向它。这一条现在有测试。
- **「不静默拒绝」是一个可以随便历检查的属性。** 四/五个事实的全部组合里，要么放行、要么给出一句话：没有
  任何输入会让命令什么都不做也不说什么。这正是读者体验成「按钮坏了」的那个失败。

还有一批同形的纯函数可以抽（`attach`、`rename`、`pin`、`restore`、`show`、`new_in` 各自的拒绝句），没有抽完。

### 已知缺口（记下来，不是为了现在修）

**方法体还没有搬过去。** appffi 的未覆盖行：起点 **437** → 建完 seam 后 **471**（`gather` / `of` 是新代
码）→ 做完这几轮 **456**（app.mbt 210 / sessions.mbt 201 / settings.mbt 41 / ffi.mbt 4）。剩下的是 `Shell::` 方法体里**直接做真 IO** 的那些（读写文件、复制会话、
开进程），它们要变成「纯的决定 → Effect 列表」才测得到。

**`handle` 里也还有够不到的部分。** `Prompt` 那条 arm 会 spawn 一个真 turn，而 `with_task_group`
会等它 spawn 的全部结束——所以它**故意不在测试里**（会发一个真请求出去）。它其中真正是判定的那一半
由 `command_of` 和 `turn_refusal` 盖住。另外，`handle` 靠的是把 `Shell::say_*` 抽成「先做决定」；像
`fork` 那种要读父文件、写子文件、失败还要回滚的方法，不把 IO 变成值就仍然盖不住（这也是 ADR-0010
的 11 条验收标准为什么会写成「`moon test` 纯函数」而又做不到）。

**循环体已经搬进来了，剩下的是 `take_command` 那一行。** 「一条命令进、一个判定出」已经是 `handle`，
所以拒绝之后真的说了那句**现在是测的了**。仍然盖不到的是 `handle` 内部需要真 IO 的那几条
（`fork` / `discard` / `save_key`），以及 `Prompt`——它会 spawn 一个真 turn，而 `with_task_group`
会等它，所以那条路故意不在测试里。要盖住它们，得把 IO 也变成值（Effect 列表）。

**`Command` 在 `core` 里没有 —— 但原来的理由（「Web 版能不能删」）随 Web UI 一起消失了。**
`ui/commands.mbt` 和 `macos/appffi` 曾各有一份、斜杠命令的解析两处各写一遍，而那份重复卡住的是
「删掉 Web 版会不会同时删掉功能」。现在 `ui/` 已删（ADR-0007 追加二），所以这是一条纯内部重构：
把一个 `priv enum Command` 从 `macos/appffi` 挪到 `core`，好处是解析能被 `core` 的测试覆盖，不再是
「删一边就丢一半语义」。仍然值得做，但不再是阻塞别的决定的那件事。

## 什么时候回头看这份 ADR

- **有人想在测试里断言某个 `Shell::` 方法** → 先看它是不是只做决定。是，就直接测；不是，就按 `gather`
  / `of` 的方式把 IO 挪出去，而**不要**把决定和发射重新合成一个函数。
- **有人觉得「测试里反正没人听，直接调 `emit` 更简单」** → 那就是这条 ADR 要拦的那一步。它是
  `host_stub.c` 那个空实现留下的诱惑，已经付过一次代价（上面那三个字段错误）。
- **要动 `World` 的字段** → 问一句它命名的是答案还是问题（决策 4）。
- **要加一条命令** → 它必须先在 `gate` 里归类才编译得过；然后问一句它该不该有测试——今天每一条能跳出
  IO 的都已经有了。
