# 原生 macOS 壳

一个原生窗口，驱动同一套 agent。它存在的原因是路线 B 的那句话要落到地上：**界面重写，内核复用**。

窗口左边是会话列表，右边是对话，`⌘,` 是设置。它可以被打开成三种东西：

```bash
# 1. .app：给人用的那个（打包，见下）
macos/make-app.sh                   # → macos/dist/pi.app
open macos/dist/pi.app

# 2. 开发循环：改一次跑一次，不打包
macos/build-moonbit.sh release      # → macos/vendor/libpiweb.a
cd macos/PiShell && swift run PiShell

# 3. 终端：同一套 agent，打的是线上字节，没有窗口
cd macos/PiShell && swift run pi-shell-cli
cd macos/PiShell && swift test       # 线格式（PiModel）+ 边界本身（PiShellTests，真 boot runtime）
```

```
macos/appffi/       MoonBit：agent + 会话 + 会话列表 + 设置 + 事件出口（这一层是新的）
macos/build-moonbit.sh  把上面那个包编译成 host 能链接的 libpiweb.a
macos/PiShell/      Swift：窗口、对话、侧边栏、设置面板、边界
macos/make-icon.swift   图标（画出来的，不是提交进来的）
macos/make-app.sh       打包成 .app（图标、Info.plist、签名）
```

MoonBit 侧的测试是 `moon test macos/appffi --target native`。

## 复用了什么

| 包 | 复用 | 说明 |
|---|---|---|
| `core/` `platform/` `agent/` | **原样** | 一行没改。它们本来就不认识 UI |
| `html/` `server/` | **不用** | HTML DSL、主题、patch、HTTP/SSE，全是 Web 的 |
| `ui/` | **不用** | 它的渲染函数与 `@html`/`@server` 绑在一起 |

`ui/` 的状态是重写的，不是搬过来的 —— 但也没有重新设计，`appffi/app.mbt` 里的
`Shell` 就是 `ui/session.mbt` 的 `Runner` 减掉「只有贴着文档才有意义」的那些字段
（transcript 深度、live patch id、订阅者）。侧边栏同理是 `ui/sidebar.mbt` 减去属于页面的
那部分：折叠、显示上限、「load earlier」、撤销提示 —— 每一条都是关于一栏网页的决定，而这一栏
现在是宿主的。剩下的部分是会话有哪些、叫什么、描述一个会话要花多少读。

## 切会话：为什么线上跑的是行，不是事件

宿主手上有两样东西是 Web 版没有的：一份「我看到过的全部事件」的记忆，和一个**它没看过**的会话。

- 自己开的会话，逐步重放事件就对了 —— 它本来就是这么画出来的。
- 换过去的会话（以及 `PI_SHELL_SESSION` 恢复的那个），事件早就发生完了，宿主一条都没收到。
  所以 `history` 事件发的是**行**，不是 delta：整段对话一行 JSON，每行都是 `complete`。

行而不是事件，是因为历史没有时间：把一段已经结束的对话重放成一串 delta，是在编造一个所有事情
都同时发生的下午。id 带 `h-` 前缀，因为流里的 id 是 `reply-1`、`tool-2` —— 两者混在一份记录里
会让 delta 追加到错误的块上。

## 分界线的判据

**`ui/` 和 `appffi/` 的差别只有一个：谁拥有视图。**

Web 版里服务器拥有文档，浏览器应用 patch —— 所以线上跑的是 HTML 片段，因为浏览器不知道
一段对话长什么样。这里 host 拥有视图，所以跑的是**事实**：这段文本来了、这个工具开始了、
这一轮结束了。`ffi.mbt` 的文件头写着这条。

副作用是这套事件只有在真的写了第二个前端之后才会证明自己，而它确实证明了 ——
`Conversation`（消费侧）与 `app_wbtest.mbt`（生产侧）断言的 JSON 字面量是**同一批**。
改一个字段名而不改另一边，会挂一个构建，而不是产出一个默默忽略事件的 host。

## 线程，和为什么必须这样

MoonBit 的 async 是单线程协作式的，它需要一个线程来跑事件循环，服务所有 socket 和定时器。
macOS 需要主线程跑自己的事件循环。**两者不能是同一个线程**，所以：

```
主线程                        pi-agent 线程
  NSApplication run loop         @async.run_async_main
  SwiftUI 渲染                     turn / HTTP / 工具进程
       │                                 │
       │  pi_shell_post(文本)             │  pi_shell_emit(JSON 行)
       └──────────► inbox.c 队列 ─────────┘
```

- 命令往一个方向走：C 里的队列 + pthread mutex。C 是因为它要跨线程加锁，而且 host 的字节
  不是 MoonBit 引用，不能当引用碰。
- 事件往另一个方向走：`pi_shell_emit` 在 MoonBit 侧是 FFI、在 host 侧由你自己定义。
  这个方向没有锁，因为 `Emit` 在 Swift 里拿一把。
- 命令循环是**轮询**的（50ms），不是被唤醒的。唤醒需要一个 pipe 加一个注册到事件循环上的
  reader，那是第二个线程和第二种失败模式，换来的是一个已经足够快的按键。空队列时轮询是两个
  syscall。

## 这个 MVP 少了什么

不是遗漏，是用来换「先知道这条路通不通」的：

- **会话列表只在侧边栏里。** 切换/新建/删除都有了，但列表按工作目录分组、不可折叠，也没有显示
  上限 —— store 小的时候这是优点，大了就是一条要滚很久的栏。
- **设置面板只有两项**：key 和工具模式（tools / code）。技能开关、fallback 指令、回合上限
  （`max_rounds` / `max_cost` / `max_seconds`）都还在文件里，Web 版能改，这里不能 —— 每一项都得
  配一个像样的控件才值得放上来，面板一次长一个诚实的控件。
- **模型只能从命令行换**（往里发 `/model`），没有下拉框。
- **markdown 是宿主渲染的**，而 Web 版是 cmark 渲染成 HTML 的 —— 两者对同一段 markdown 会有
  细微差别（表格、脚注、raw HTML 的处理）。真要说谁对，得挑一个共享的实现，那是后面的事。
- 附件、图片、用量/上下文面板、后台任务面板、skill、压缩提示、workspace 选择器、
  「load earlier」窗口 —— 都不在。
- 设置面板能改的东西，这里一个都改不了。

## 打包

```bash
macos/make-app.sh release           # → macos/dist/pi.app（约 3.7MB）
```

打包前会 `rm` 掉旧的宿主可执行文件再重建：SwiftPM 不知道 `vendor/libpiweb.a` 变了（那个归档不在
依赖图里），所以 MoonBit 侧改完之后它可能报「构建成功」而留下旧二进制 —— 症状是最坏的一种：App 的
行为和修复前一模一样。

脚本做四件事：跑 `build-moonbit.sh`，`swift build -c release`，组装 bundle（可执行文件改名叫
`pi`，写 `Info.plist`，生成图标），最后 `codesign --sign -`。

几个决定：

- **不用 Xcode 工程。** 没有 nib、没有 asset catalog、没有 SwiftPM 做不了的构建阶段 —— 一个
  `.xcodeproj` 会是同一个程序的第二份描述，和第二件要同步维护的事。
- **图标是程序画出来的**（`make-icon.swift`）。提交一个 `.icns` 等于提交一个谁都不能 review、
  谁都不能改的二进制；写成几行 CoreGraphics，改个颜色就是改一行。
- **版本号读 `moon.mod`。** 打包脚本自带一个版本常量，就是一个没人记得改的数字。
- **签名是 ad-hoc 的**（`codesign --sign -`），够本机跑，也够诚实地说明「别人从网上下载会被
  Gatekeeper 挡住」。真要发布得换成 Developer ID 加公证；`PI_SHELL_BUNDLE_ID` 环境变量可以
  覆盖 bundle id，因为 identifier 一旦变了，macOS 就会忘记哪个 App 对应哪个文档/窗口。

**为什么必须打包，而不只是「方便」**：`.app` 是一个身份 —— 名字、图标、一个稳定不变的
identifier，以及 `LSApplicationCategoryType` 这类让系统知道它是什么的东西。裸可执行文件在
Dock 里是一个通用文档图标，名字取自文件名，`applicationShouldTerminateAfterLastWindowClosed`
之类的行为也没有立场。`PiShellApp.swift` 里那句 `setActivationPolicy(.regular)` 就是给裸二进制
写的补丁，打包之后它是 no-op。

**Working directory 的坑**：双击启动的 `.app`，cwd 是 `/` —— Finder 不传目录，内核默认是根。
照单全收的话，从 Finder 起的每个会话都在商店里单独一格（`----`），工具会在卷的根目录上跑，
工作区叫「什么都不是」。所以 `working_dir`（`appffi/app.mbt`）把 `/` 读成 home；`/` 以外一律
当真，因为那是有人选的（终端的 `cd`、launcher、"Open With"）。

## 设置面板：为什么只有两项

判据是 Web 版那一句：**这个正在跑的进程能不能兑现？** key 和工具模式都是每一轮开头读一次
（`Shell::api_key` / `Shell::run_turn`），存下来就是「下一轮生效」，所以它们值得一个控件。store、
endpoint、模型都在启动时定了，给它们一个控件就等于说谎 —— 面板里只留一句它们是只读的，以及
设置文件的路径，方便想手改的人去改。

没有 key 的解法值得单独说：从 Finder 启动的 App **没有** login shell 的环境变量，所以在一台
「装了它」的机器上 `DEEPSEEK_API_KEY` 是空的 —— 这时唯一的入口就是这个面板。这也是面板要先做
的原因：没有它，没有 key 的机器根本进不去。

面板不持有「将要保存的设置」副本：每个控件都是**请求一次改动，然后等 shell 说现在是什么**。
所以保存失败或进程拒绝时，窗口不会留在一个从未存在过的状态上。

## 调试：看不见的线上到底有什么

GUI 什么都不打印，所以 app 出问题时（面板一直转、窗口一直 "starting…"）没法判断是「请求没发出」、
「回答没回来」，还是「回答回来了但视图没用它」—— 这三种症状长得一模一样。

```bash
PI_SHELL_DEBUG=/tmp/pi-wire.log open macos/dist/pi.app
tail -f /tmp/pi-wire.log
```

两个方向各一行，`→` 是宿主发的，`←` 是 MoonBit 发的。`/key` 的内容会被替换成
`<42 characters>`，长度留着（「字段本不该是空的」正是看日志要找的那类事）。默认关闭：一个没被要求
就在旁边写日志的文件是意外，而且里面会有 user 的 prompt。

`pi-shell-cli` 打的是同一条线（不脱敏，它本来就是干这个的），所以两者对照着看能分辨「MoonBit 没发」
和「Swift 没收到」。

## 已知的坑

- `swift build` 会刷一屏 `was built for newer 'macOS' version` 的警告：MoonBit 用本机 SDK
  编译 `libpiweb.a`，而 Swift 包声明的最低版本更低。是警告，不是错误。
- 归档要手动重建：改了 `macos/appffi/` 得再跑一次 `build-moonbit.sh`，SwiftPM 不知道它。
  更阴的一点是 SwiftPM 也可能不重链：`touch` 一个 Swift 文件未必让可执行文件重链，于是新的
  `.a` 被写着旧二进制。症状是「MoonBit 侧明明改了，线上没变」。`rm` 掉可执行文件再 build 一定对。
- **`PiClient` 和 `pi_shell_set_emit` 是一件事**，写第二条就等于把 app 弄成聋子：宿主装了 reader
  却没在 C 侧注册回调时，`emit_sink` 是 NULL，每一行都被丢掉，而 `pi_shell_emit` 不报错。症状是
  「窗口起来、什么都不发生」。现在 `Emit.install` 同时做这两件事，`PiShellTests` 里有一条真启
  runtime 的测试守着它（把那段注册删掉，测试会以 `state=starting` 失败）。
- `swift run PiShell` 是裸可执行文件，不是 .app。`AppDelegate` 里那句
  `setActivationPolicy(.regular)` 就是为它写的 —— 否则有窗口、没菜单栏、不聚焦，看起来像卡死。
  真正打包时它是个 no-op。

## 下一步

按「先便宜后贵」排：

1. **滚动跟随的细节**：现在每次都跳到最新一行。Web 版只在读者已经在底部时才跟，翻上去看旧内容
   不会被拽回来。
2. **侧边栏的规模**：分组折叠、每个工作目录显示最近 N 条、重命名（`Label`/`session_info` 两种
   入口 `core` 都有）、已删除会话的撤销 —— 现在删除只做到「文件改名藏起来」。
3. **面板的其余几项**：技能开关、fallback 指令、回合上限 —— 都在 `AppSettings` 里，缺的是控件。
4. **模型下拉框**，然后是附件、用量面板。
5. **发布**：Developer ID 签名 + 公证，以及一个真的 bundle id。
