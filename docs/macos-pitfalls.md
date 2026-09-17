# macOS 端踩坑清单

**什么时候读这份**：动 `macos/` 之前扫一眼。它不是教程，是一张 `症状 → 原因 → 修法` 的表 ——
坑的价值在于**开工前**扫一遍，而不是撞上之后再读懂一段散文。

理由很直接：这份清单里已经写进 `macos/README.md` 的那些条目，**我自己照样踩了其中一条的变体**
（只跑了 `swift build` 没重新打包，于是宿主打开了旧二进制，而构建是「成功」的）。散文挡不住手快，
表格可以。

分六组。每条都是这次开发中**实际撞到**的，不是预想的。

**开发循环，从头到尾（这三条必须一起做）**：

```bash
# 1. 改了 macos/appffi/（MoonBit 侧）→ 重建归档
macos/build-moonbit.sh release          # → macos/vendor/libpiweb.a

# 2. 改了任何一侧 → 重新打包（会顺带 rm 掉旧的宿主可执行文件，见第一组）
macos/make-app.sh release               # → macos/dist/wei Agent.app

# 3. 只想跑测试，不需要打包
moon test macos/appffi --target native  # MoonBit 侧
cd macos/PiShell && swift test          # 线格式 + 边界（真 boot runtime）
```

```bash
# 排查线上问题（会记录 prompt，附件字节已 elide）
PI_SHELL_DEBUG=/tmp/pi-wire.log open "macos/dist/wei Agent.app"
```

---

## 一、构建与打包

| 症状 | 原因 | 修法 |
|---|---|---|
| MoonBit 侧改了，线上没变 | SwiftPM **不知道** `vendor/libpiweb.a` 变了（那个归档不在依赖图里），于是「构建成功」+ 旧二进制 | 改完 `macos/appffi/` 一定要 `macos/build-moonbit.sh` |
| 重建了 `libpiweb.a`，症状还是旧的 | SwiftPM 也不会因为归档变了而重链**别的产品**：`touch` Swift 源码多不做用，`pi-shell-cli` 和 `PiShellPackageTests.xctest` 都照样跑旧二进制。最坏的表现不是报错，而是**旧 shell 用旧线格式回答**：新加的字段在日志里根本不存在，于是一个正确的消费侧看起来像写错了 | `rm -f` 掉那个产品再 build（`.xctest` 要 `rm -rf` 整个目录）。`swift test` 里那条真启 runtime 的测试就是抓这一类的 |
| 改了 MoonBit 侧、`swift test` / `pi-shell-cli` 还是旧行为 | 归档重建了，但**那两个产品没有重链**（见上一条）。这次是 `NewSession` 的 gate 明明删了、CLI 仍然回「a turn is running here — stop it first」 | `rm -f .build/arm64-apple-macosx/debug/pi-shell-cli` 再 build。**验证一个 shell 侧的改动，永远要先把跑它的那个产品删掉重建** |
| 同上，而且你已经 build 过了 | 同上，但更隐蔽：跑的是 `swift build`（debug 可执行文件），**根本没重新打包** —— 用户打开的还是几天前那个 `.app` | 给人用的东西一律 `macos/make-app.sh`；`make-app.sh` 会先 `rm` 掉旧的宿主可执行文件再重建，这是它对这条的补偿 |
| 跑完 `make-app.sh`，怀疑把用户正开着的 app 弄没了 | 我当时的推断是「`make-app.sh` 把运行中的 bundle 删了重建」，**这个推断后来被证伪了**：下一次同样在用户实例（pid 51294，已跑 5 分钟）运行时跑 `make-app.sh`，那个实例**活着**（改完 bundle 后仍然在跑，`ps` 可见，未崩溃）。所以运行中的 app 不会因为 bundle 被替换而死 —— 更可能是用户自己退掉了那个窗口 | 结论只能是：**旧的那次消失原因不明**，别再拿它当「make-app 的副作用」传授。但纪律不变：打包前先看有没有别人的实例在跑，并且**别用 `head -1` 拿 pgrep 的结果去截图** —— 用户的实例和你的 demo 同一条命令行（都在 `MacOS/wei`），`head -1` 拿到的可能是**用户那扇窗**（我这一轮就这么拍了用户窗口一张图，已删）。要认自己的：按 `PI_SHELL_STORE` 环境变量区分（`ps eww`），或者让自己的实例用不同的 store 路径 |
| 一屏 `was built for newer 'macOS' version` 警告 | MoonBit 用本机 SDK 编译，Swift package 的 target 是 14 | 忽略。不是错误，也修不掉（除非把 deployment target 提到本机版本） |
| `swift run PiShell` 有窗口、没菜单栏、不聚焦 | 裸可执行文件不是 `.app` | `AppDelegate` 里的 `setActivationPolicy(.regular)`；打包后是 no-op |
| 窗口起来什么都没发生 | 宿主装了 reader 但没在 C 侧注册回调（`pi_shell_set_emit`），`emit_sink` 是 NULL，**每一行都被丢掉且不报错** | `Emit.install` 同时做这两件事；`PiShellTests` 里有一条真启 runtime 的测试守着 |

## 二、SwiftUI / 编译期摩擦

每一条都让人原地卡过一次，而且**错误信息基本指不到问题**。

| 症状 | 原因 | 修法 |
|---|---|---|
| 泛型参数推导失败，错误里出现 `TableColumnBuilder` | 在 `Form` 里用 `Group { Section(…) }` 分组：`Group` 的 builder 泛型是给表格列的，推不出来 | 自己写一个 `@ViewBuilder` 容器（我们叫 `rebuild`），别用 `Group` 装 Section |
| 每个 `Section("…")` 突然都不是 view 了 | 文件里嵌套了一个叫 `Section` 的类型，**遮蔽** `SwiftUI.Section`（只在文件内，但整个文件） | 别用会撞的平台类型名。我们把 `SettingsView.Section` 改成了 `Pane` |
| `incorrect argument label` | `.dropDestination(for:action:isTargeted:)` —— 我猜的是 `isTarget:` | 以 SDK 为准；这类标签猜不中 |
| `contextual closure type '() -> KeyPress.Result' expects 0 arguments` | `.onKeyPress(.return) { }` 这个单参重载**不给闭包传参数** | 要拿到 `KeyPress`（进而读**事件自己**的 modifiers）必须写 `phases:`：`.onKeyPress(.return, phases: .down) { press in … }` |
| ⇧Return 的行为和代码不符 | `NSEvent.modifierFlags` 读的是**此刻硬件**的状态，不是被处理那个事件的状态；合成/重放的事件更是完全无关 | 用事件自己的 `press.modifiers` |
| `NSImage` 上没有 `pngData` | 它确实没有 | 过 `NSBitmapImageRep`（扩展在 `macos/PiShell/Sources/PiShell/Composer.swift`） |
| 粘贴图片的回调从来不触发 | `onPasteCommand(of:)` 只在剪贴板**能提供**所列类型时才提供该命令（**这条是 API 语义，我没有逐个场景验证**） | 它意味着这条路径无法保证可达 —— 所以另给了一个菜单项（⌘⇧V），不赌谁能拿到 ⌘V |

## 三、文本输入 / 输入法（**中文用户必踩**）

这一组是「发送没反应」那个 bug 的现场。它只在输入法下复现，纯英文和自动化测试都测不出来。

| 症状 | 原因 | 修法 |
|---|---|---|
| 用输入法打完字，按回车**什么都没发出去**，输入框清空了 | `.onKeyPress(.return)` 把合成中的回车吃掉了：输入法要靠这个键**提交候选词**，而合成中的文字还不在 `@Binding` 里，`draft` 是空的 → `send("")` 什么也不做 | 交给输入法：`hasMarkedText()` 为真时返回 `.ignored` |
| 修完上面之后，第一条消息变成了原始拼音（`nihao`） | 同一个原因的另一面：`draft` 里是拼音串，汉字还没提交 | 同上——**让出这个键**，而不是想办法读汉字 |
| 加了「编辑器比 binding 长就是在合成」的判断后，**第一个字**被吞 | 这个判断是**假阳性**：SwiftUI 的 binding 天然慢一拍，刚敲下的第一个字符正好是「编辑器有字、binding 没有」 | 只用 `hasMarkedText()` 这一个信号；不要自己造第二个 |
| 想知道输入法装没装 / 是哪个 | —— | `TISCreateInputSourceList` / `TISCopyCurrentKeyboardInputSource`；本机是 `com.apple.inputmethod.SCIM.ITABC`（简体拼音）和 `com.apple.keylayout.ABC` |

**一般化的教训**：任何「替用户决定某个键是什么意思」的处理器（`.onKeyPress`、快捷键、全局热键），
都要先问**输入法要不要这个键**。中文、日文、韩文、以及 emoji 选择器都走同一条路。

## 四、平台 API 的发现（尤其 macOS 26 的新东西）

| 症状 | 原因 | 修法 |
|---|---|---|
| 不知道 Liquid Glass 怎么写、能不能用 | 凭记忆猜 API 不可靠 | **读 SDK 的 `.swiftinterface`**：`…/MacOSX.sdk/System/Library/Frameworks/SwiftUI.framework/…/arm64e-apple-macos.swiftinterface`。这次就是这么找到 `glassEffect` 的完整签名与可用性标注的 |
| 同上，而且它不在 `SwiftUI` 里 | `glassEffect`、`Glass` 定义在 **SwiftUICore**（`@_originallyDefinedIn(module: "SwiftUI", macOS: 15.0)` 那套写法） | 按框架名找文件，别只 grep SwiftUI |
| 用了 macOS 26 的 API，但 package 的 target 是 14 —— 会不会崩在旧系统上 | —— | 用 `swift build` 后 `nm -m <binary> \| grep glassEffect` 看是不是 **weak external**，再 `otool -l \| grep minos` 看部署目标。weak 链接 + `if #available` 就是安全的 |

## 五、验证与自动化（这次最费时间的一块）

手动验证 macOS UI 很贵，而**便宜的验证方式是存在的**，只是要走对路。

| 症状 | 原因 | 修法 |
|---|---|---|
| AppleScript 读 UI 崩掉（`-2741` 语法错 / `-1700` 类型转换失败） | 这个 app 的 AX 树很深，`entire contents` 会把整棵树物化成列表再逐项类型转换，量一大就崩 | 写一个 **Swift AX 工具**：`AXUIElementCreateApplication` + 递归 `kAXChildrenAttribute`，一棵树几十个节点一次读完 |
| 用 AX 设了 text field 的 `value`，界面没反应 | AX 的 `set value` **驱动不了 SwiftUI 的 binding** | 必须发**真事件**（`CGEvent`）或真按键（`osascript keystroke`） |
| 想断言「发送按钮现在可用吗」 | —— | AX 的 `kAXEnabledAttribute` 是读得出来的，这对验证状态机很省事 |
| 用 `strings` 在 release 二进制里找菜单项标题，找不到，以为菜单没编进去 | `-O` 会做字符串池化 / 后缀合并：一条字面量可能只是另一条里的一段偏移，于是那串字节根本不存在。**最小复现：**一个只有 `CommandMenu` 的 30 行 app，`-O` 编完后 `Next Session` / `Stop Turn` / `New Session` 全为 0，而同文件里的 `Previous Session` 还在 —— 连**早就正常工作的** `⌘N` 的 `New Session` 也不见了 | `strings` 不是验证菜单的方法。要么加个 AX 工具读 `AXMenuBar`，要么真启动一个、看一眼 |
| `osascript` 里找不到输入框 | 表单里有两个 `AXTextField`（设置面板的搜索框、输入框），按顺序取会取错 | 按 **position.y** 取最靠下的那个 |
| 启动后拿到的 PID 不对 | `( … & )` 拿到的是**子 shell** 的 PID，不是 app 的 | 子 shell 里用 `exec env … /path/to/pi`，再 `echo $!` |
| `pkill -f "Macos/pi"` 把自己也匹配上了（现在可执行文件叫 `wei`，但坑的形状一样） | `-f` 匹配整条命令行，而你的 `bash -c` 里就写着这个字符串 | 用锚定：`pkill -9 -f "Macos/pi$"`。**这条我照着写了又踩了**：`pkill -9 -f "MacOS/pi"` 没杀掉任何一个 app（用户那个进程活得好好的），因为模式先匹配上了**它自己所在的 `bash -c`**，命令根本没走到那一步。教训是锚定要落在**参数的位置**上，`$` 放在路径后面；光把模式写短不算锚定 |
| 反复启动后测到的行为不对 | **多个实例在跑**，你连的是上一个 | 每次测完按 PID 确认存活；断言时带上 PID / 窗口标题 |
| 按 PID 找窗口号 | 用户的 app 和你的 demo 同时跑时，按 owner 名选窗口会选到**用户那个**（两个进程 owner 都叫 `wei Agent`） | 按 `kCGWindowOwnerPID` 过滤 `CGWindowListCopyWindowInfo`，取 `layer == 0` 且有标题那个；`.optionAll` 是必须的（见第六节） |
| 看不见 `Settings…` 菜单项；或者想切设置窗左边的某一项，AX 里翻不到 | 主菜单在**主线程忙的时候还会重建**（启动早期能看到的菜单项，几秒后又一次 `NSApp.mainMenu` 就变了）；而列表行的 `AXPress` 返回 **-25206**（不支持该动作） | 菜单项拿不准就不要猜选择器（`sendAction(showSettingsWindow:)` 返回 `true` 却什么都不做）：按 desc 找主窗左下角那个 `Settings` 按钮按下去。切换左栏那一项用**设 `kAXSelectedAttribute`**（不是 `AXPress`） |
| 想把窗口改小，好看清滚动边缘效果 | `kAXSizeAttribute` 写入返回 **-25200**（不可设） | 改小不行就换成**内容长的那一项**（Skills 会列一长串技能）再滚；或者去 `/tmp` 写一个只含布局的壳子（第六节） |
| 把 `safeAreaBar` 的 bar 摆在 `ScrollView` 上面，第一行文字**和标题重叠** | `safeAreaBar` insets safe area，但挡住第一行的不是它 —— 是转录自己的 content margin，而那个数是从**窗口顶边**量的（`Wei.Control.toolbar`）。两个机制各懂一半 | bar 的实际高度量出来加进 content margin（`ConversationTitleHeightKey`），别写常数 |
| 想在同一个 `ToolbarItem` 区域里放**第二个** item（比如标题 + 改名的铅笔） | 平台会**重排整行**，而且不是「往右挪一点」：会话栏那个标题从自己的栏（`x=467…921`）跑到**列表栏上面**（`x=230…397`），同时**窗口标题被挤走**（`x=230…864` → `x=397…557`，压到两栏交界）。把两个控件塞进同一个 item 的 `HStack` 也一样 | 这一栏要两样东西就**自己画 bar**（`safeAreaBar` + `HStack`），别指望工具条排两个 item。量法：`axframe`，四个 x 一比就知道 |
| 想改**平台画的窗口标题/副标题的字号** | **没有这个 API**：`NSWindow` 只有 `title`/`subtitle` 两个字符串，AppKit 里没有任何 title font / attributed title；SwiftUI 的 `toolbarTitleDisplayMode` 文档明说 "This modifier has no effect on macOS"（`toolbarBackgroundVisibility` 那种是另一回事）。`font()` 也管不到，因为那些字不是你的视图画的 | 要控字号就**自己画**：`toolbar(removing: .title)` 去掉平台那枚，再把标题放进自己的 `ToolbarItem` / bar；`navigationTitle` 留着让窗口仍然有名字（Window 菜单、辅助功能照旧）。实测平台那枚是 13 semibold / 副标题 11 |
| 工具条 item 里的 `HStack`/`VStack` 不撑满整栏（比如「标题 + 按钮」里的按钮没飘到栏的最右） | item 的宽度由内容定：实测 `x=230…388`（158pt），`frame(maxWidth: .infinity)` 放在里面的 stack 上不解决问题 | 位置就按内容排（这也常是想要的：按钮紧跟标题，像备忘录）；真要靠到栏尾，得让 item 自己弹性（实测：单独的 `Text` + `.frame(maxWidth: .infinity)` 会撑满，stack 里不会） |
| 把一个 item 声明在**中间栏**（content）但想要它压在该栏上 | `.navigation` 会给它这一栏的最前（实测 `x=230…271`），但**窗口标题同时被挤走**（→ `x=397…557`）。`.secondaryAction` / `.confirmationAction` / `ToolbarSpacer(.flexible)` 都是同一个结果 | 要么接受它在窗口尾端（`.primaryAction`，实测 `x=872…917`，那其实是**会话栏**上面），要么**不用工具条**、把控件画进这一栏的内容里（改版，不是改 placement） |
| bar / 自定义视图里的按钮显示成了「图标 + 文字」 | `Label` 在工具条里只画图标，在普通视图里图标文字都画 | 要图标就给 `Image(systemName:)`，文字用 `.accessibilityLabel`；顺带 `.buttonStyle(.borderless)` 去掉边框 |
| 想看「标题和工具条是不是同一行」，靠看截图估 | 截图能量，但估不准 | **读 AX 的 frame**：`axframe`（第六节）把整棵树连 `y=.. x=..` 打出来。工具条是 `AXToolbar y=0..52`，按钮 `x=872..917`，标题 `y=14..38` —— 两行是不是同一行，一眼就有数字 |
| 工具条 item 的高度/内容想靠 `padding` 挪位置，结果转录第一行被压住 | bar 的高度就是转录第一行要避开的量（`contentMargins(.top, 工具条 + bar 高度)`） | 只是**画**的位置要挪，就用 `offset`（不改布局高度）；要连高度一起改才用 padding |
| 想把标题和工具条的按钮放成**同一行**，把标题放进 `ToolbarItem` | 工具条 item 的宽度是固定的：**长度超过可用宽度的 item 会被收进溢出菜单**（右端出现 `»`），并且把同一行其它 item 的位置挤乱 —— 长标题的结果是「标题不见了 + 按钮移位 + 多了个 chevron」，而不是省略号。顺带它还会破坏顶部那层边缘效果。见下一条 | 别往工具条里塞长文本：`safeAreaBar` 画在工具条下方（那样才有模糊和 inset），再把**文字**抬到工具条的中心线上（`ConversationView.titleLift`），抬起的量在下面补回去，bar 高度不变 |
| 想让 `Text` 末尾出现省略号，写了 `lineLimit(1)` + `truncationMode(.tail)`，结果没有省略号 | 省略只发生在**宽度被约束**的时候：一个自然宽度的 `Text` 会要多少给多少，超出部分被邻居裁掉而不是变成 `…` | 加 `.frame(maxWidth: .infinity, alignment: .leading)`（或别的上限），让平台知道可用宽度是多少 —— 再用**尾部内边距**给它让开右边的按钮 |
| 想量「标题在不在工具条那一行」，靠看截图估 | 截图能量，但估不准 | **读 AX 的 frame**：`axframe`（第六节）把整棵树连 `y=.. x=..` 打出来。工具条是 `AXToolbar y=0..52`，按钮 `x=872..917`，标题 `y=14..38` —— 两行是不是同一行，一眼就有数字 |
| 想看「内容从 bar 下面穿过去被模糊」的效果，滚了半天没反应 | 那一栏的内容不够长，压根没有可滚的东西（设置面板的 API Key 那页就装得下） | 换内容长的一页（Skills）或长会话；也可以只写布局的壳子（第六节）。注意合成滚轮事件 `wheel1` 是 `Int32`：传负数给 `Int()` 再装回 `Int32` 会 crash（`Range requires lowerBound <= upperBound`） |
| 改了「换会话」相关的代码，测完用户说他打了一半的字跟着跑 | 我**拿用户正在用的会话做了测试**，进程真的把新 turn 写进了他的日志 | **纪律**：测试先 `cp` 一份会话到临时目录，用 `PI_SHELL_SESSION` 指过去。永远不碰 `~/.pi-mb/sessions/` |
| 手写一条 `.jsonl` 造演示会话，app 只回一句 `could not start: missing field: timestamp` —— 没有别的线索，看起来像 store 没发现、像路径不对、像编码不对 | `Entry::from_json` 要的**每一层都有 `timestamp`**：entry 一层，`message` 一层也是（真实日志里 assistant 的 message 自带 `timestamp`/`usage`/`model`/…）。只写 `role`+`content` 的 message 不是一条能读的记录 | 别手写：`cp` 一条真会话，**只替换 assistant 那条的 `content[].text`**，其余字段照搬（一轮就通）。再配 `PI_SHELL_SESSION=<那条文件的路径>` 直接打开它 —— 会话标题会变成它的 id，不必让 store 发现工作区 |
| 想造一段「要长到能滚」的转录，结果只有几行 | 上面那条修法把小会话变干净了，也把它变短了 —— 而模糊/滚动这类效果需要**有东西滚** | 复制一条**大的**真会话（按文件大小倒序取第一条，几十兆也行）到临时 store、改 header 的 `cwd`，`PI_SHELL_SESSION` 指过去。一次就得到上千条消息，且一个 token 不花 |
| 同一台机器上开着用户的 app，自己又起一个 demo，截图/断言拿到的是**错的实例** | 两个进程 owner 都叫 `wei Agent`（debug 可执行文件的 owner 是 `PiShell`，但 `.app` 那个不是），按名字选窗口会选到用户那个 | 按 **PID** 过滤 `CGWindowListCopyWindowInfo(.optionAll)` 选窗口号（`scripts` 无关，十几行 Swift 就够），再 `screencapture -x -o -l <num>`（`-o` 去掉阴影）。见第六节 |
| AX 树太大，AppleScript 直接放弃 | 1500 行的转录 + 长会话 | 也是上面那条：用 Swift AX 工具，或者拿小的会话测 |

## 六、调试手法（正面清单，别丢）

这些是**找到** bug 的东西，比任何一条坑都值钱。

- **`PI_SHELL_DEBUG=/tmp/pi-wire.log` 抓整条线上**：两个方向、一行一条。发送那个 bug 就是这样定性的
  —— 日志里 `PiClient.send text=[]` 直接指出「处理器被调用了，但拿到的是空串」，比在 SwiftUI 里猜快得多。
  注意它**会**包含 prompt（附件字节已做 elide：`WireLog.elided`）。
- **需要知道「视图内部此刻是什么」时，直接 `FileHandle.standardError.write`**：app 的 stderr 重定向到
  文件即可。这次靠它在 `onKeyPress`、`submit()`、`PiClient.send` 三处打点，一次就分清了「没触发」
  和「触发了但值是旧的」。
- **`pi-shell-cli` 是同一套 agent 的终端形态**：怀疑是 shell 侧还是宿主侧时，先在终端复现 —— 这次
  shell 侧一次就通过了，问题定位在宿主，省掉大量窗口里的瞎试。
- **假模型比真 API 好用**：一个几十行的 python SSE server（`/tmp` 里现写）能构造工具调用、思考流、
  用量字段，而且是确定的。真 API 既慢又花钱，还不一定能复现你要的那次形状。注意它有个坑：请求体
  可能是 chunked 编码的（`curl` 那种），只按 `Content-Length` 读会拿到空 body —— 我第一次就是这么
  被骗了一轮，以为模型没被调用。
- **拖动分隔栏卡顿 → 先量格式化，不是先量布局。** 症状是拖左栏时整窗掉帧。原因是 `sessionAgeText` **每行每帧**
  创建一个 `DateFormatter`（实测 0.13 ms/个），而拖分隔栏会 resize 整个 split、于是每行每帧重画：
  30 行 ≈ 4 ms/帧，占掉 60 Hz 预算的四分之一，还没画任何东西。修法是按日历/locale/模板缓存 —— 一帧从
  **4 ms 降到 0.26 ms**。教训：进入渲染路径的**构造**（formatter、number formatter、正则、字体）都要缓存，
  而且这类开销单看一行是量不出来的，要对「一帧有多少行」做乘法。
- **截图能看见测试看不见的东西**：`screencapture -x` 全屏，`screencapture -x -l <windowid>` 一个窗口
  （不给窗口 id 就用 `CGWindowListCopyWindowInfo`：`onScreenOnly` + `layer == 0` + 尺寸够大）。
  一次就定出两个 bug，两个都是**只有眼睛能发现**的：中断回合那条提示被放进 `ScrollView` 里了，
  于是长会话里它滚出屏幕、两个按钮在最需要的时候够不着；侧边栏的 spinner 在 turn 开始时根本没刷新
  （`say_sessions` 只在 turn 结束时调），看起来像功能不存在。两者单测、wire log、终端复现全都看不出来。

  三条边界，都很硬：

  | | 权限 | 说明 |
  |---|---|---|
  | 看（截图） | 屏幕录制 | `CGPreflightScreenCaptureAccess()`；**会掉** —— 我这一轮里它先是 `true`，几分钟后变 `false`，之后的截图全部 `could not create image from display` |
  | 点（合成事件） | 辅助功能 | `CGPreflightPostEventAccess()` / `AXIsProcessTrusted()`；**和屏幕录制是两个权限**，所以「我能看」完全不代表「我能点」 |
  | 读菜单 | 辅助功能 | 同上。菜单项标题也因此验不了 |

  所以截图是**只读**的：能看状态，不能驱动。要驱动得靠键盘/鼠标，而那就需要辅助功能。
  截图前先查一次权限，别把 TCC 拒绝当成 app 的问题。
- **按 PID 找窗口号**（用户的 app 和你的 demo 同时在跑时，这是唯一可靠的选法）：
  `CGWindowListCopyWindowInfo(.optionAll)` 拿全表，按 `kCGWindowOwnerPID` 过滤，取 `layer == 0`
  且带标题的那个；`screencapture -x -o -l <num>`（`-o` 去掉阴影）。十几行 Swift 存成一个小工具，
  比每次手抄窗口号强 —— 而且 **`.optionAll` 是必要的**：`.optionOnScreenOnly` 在这种 app 上会
  返回空表（同一个查询里有 `onscreen=true` 的窗口，只换 flag 却什么都拿不到）。
- **演示一段对话不需要一行模型**：`cp` 一条真会话、换掉 assistant 的正文、`PI_SHELL_SESSION=` 指
  过去，窗口里就是那段对话。验证「答案里的图」这种纯渲染的事，这样一轮几秒钟，且不花 token。
- **量布局用 AX 的 frame，不靠截图估**：`/tmp/pi-shell-probe/axframe <pid>` 把整棵 AX 树连
  `y=.. x=..`（窗口相对坐标）打出来 —— 工具条是 `AXToolbar y=0..52`、按钮 `x=872..917`、
  标题 `y=14..38`，于是「标题和按钮在不在同一行」是一个数字问题。同一套工具里还有：
  `wininfo <pid>`（按 PID 列窗口号）、`axdump`（树，不带坐标）、`scroll <pid> x y ticks [delta]`
  （**先把 app 置前**再发合成滚轮事件，否则事件穿过一个不活跃的窗口）、`axrow <pid> 'Tools'`
  （设 `kAXSelectedAttribute` 切换设置面板左栏，行不支持 `AXPress`）、`axpress`（按主窗左下的
  `Settings` 按钮）、`leftedge <png> y0:y1:label...`（量某条横带里最靠左的深色像素，用来对左边缘）。
  它们都是十几行 Swift、`swiftc` 直接编，不用建工程。
