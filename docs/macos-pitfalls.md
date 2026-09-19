# macOS 端踩坑清单

**什么时候读这份**：动 `macos/` 之前扫一眼。它不是教程，是一张 `症状 → 原因 → 修法` 的表 ——
坑的价值在于**开工前**扫一遍，而不是撞上之后再读懂一段散文。

理由很直接：这份清单里已经写进 `macos/README.md` 的那些条目，**我自己照样踩了其中一条的变体**
（只跑了 `swift build` 没重新打包，于是宿主打开了旧二进制，而构建是「成功」的）。散文挡不住手快，
表格可以。

分七组。每条都是开发中**实际撞到**的，不是预想的。

**开发循环，从头到尾（这三条必须一起做）**：

```bash
# 1. 改了 macos/appffi/（MoonBit 侧）→ 重建归档
macos/build-moonbit.sh release          # → macos/vendor/libwei.a

# 2. 改了任何一侧 → 重新打包（会顺带 rm 掉旧的宿主可执行文件，见第一组）
macos/make-app.sh release               # → macos/dist/wei Agent.app

# 3. 只想跑测试，不需要打包
moon test macos/appffi --target native  # MoonBit 侧
cd macos/WeiShell && swift test          # 线格式 + 边界（真 boot runtime）
```

```bash
# 排查线上问题（会记录 prompt，附件字节已 elide）
WEI_DEBUG=/tmp/wei-wire.log open "macos/dist/wei Agent.app"
```

---

## 一、构建与打包

| 症状 | 原因 | 修法 |
|---|---|---|
| MoonBit 侧改了，线上没变 | SwiftPM **不知道** `vendor/libwei.a` 变了（那个归档不在依赖图里），于是「构建成功」+ 旧二进制 | 改完 `macos/appffi/` 一定要 `macos/build-moonbit.sh` |
| 重建了 `libwei.a`，症状还是旧的 | SwiftPM 也不会因为归档变了而重链**别的产品**：`touch` Swift 源码多不做用，`wei-cli` 和 `WeiShellPackageTests.xctest` 都照样跑旧二进制。最坏的表现不是报错，而是**旧 shell 用旧线格式回答**：新加的字段在日志里根本不存在，于是一个正确的消费侧看起来像写错了 | `rm -f` 掉那个产品再 build（`.xctest` 要 `rm -rf` 整个目录）。`swift test` 里那条真启 runtime 的测试就是抓这一类的 |
| 改了 MoonBit 侧、`swift test` / `wei-cli` 还是旧行为 | 归档重建了，但**那两个产品没有重链**（见上一条）。这次是 `NewSession` 的 gate 明明删了、CLI 仍然回「a turn is running here — stop it first」 | `rm -f .build/arm64-apple-macosx/debug/wei-cli` 再 build。**验证一个 shell 侧的改动，永远要先把跑它的那个产品删掉重建** |
| 同上，而且你已经 build 过了 | 同上，但更隐蔽：跑的是 `swift build`（debug 可执行文件），**根本没重新打包** —— 用户打开的还是几天前那个 `.app` | 给人用的东西一律 `macos/make-app.sh`；`make-app.sh` 会先 `rm` 掉旧的宿主可执行文件再重建，这是它对这条的补偿 |
| 跑完 `make-app.sh`，怀疑把用户正开着的 app 弄没了 | 我当时的推断是「`make-app.sh` 把运行中的 bundle 删了重建」，**这个推断后来被证伪了**：下一次同样在用户实例（pid 51294，已跑 5 分钟）运行时跑 `make-app.sh`，那个实例**活着**（改完 bundle 后仍然在跑，`ps` 可见，未崩溃）。所以运行中的 app 不会因为 bundle 被替换而死 —— 更可能是用户自己退掉了那个窗口 | 结论只能是：**旧的那次消失原因不明**，别再拿它当「make-app 的副作用」传授。但纪律不变：打包前先看有没有别人的实例在跑，并且**别用 `head -1` 拿 pgrep 的结果去截图** —— 用户的实例和你的 demo 同一条命令行（都在 `MacOS/wei`），`head -1` 拿到的可能是**用户那扇窗**（我这一轮就这么拍了用户窗口一张图，已删）。要认自己的：按 `WEI_STORE` 环境变量区分（`ps eww`），或者让自己的实例用不同的 store 路径 |
| 一屏 `was built for newer 'macOS' version` 警告 | MoonBit 用本机 SDK 编译，Swift package 的 target 是 14 | 忽略。不是错误，也修不掉（除非把 deployment target 提到本机版本） |
| `swift run WeiShell` 有窗口、没菜单栏、不聚焦 | 裸可执行文件不是 `.app` | `AppDelegate` 里的 `setActivationPolicy(.regular)`；打包后是 no-op |
| 窗口起来什么都没发生 | 宿主装了 reader 但没在 C 侧注册回调（`wei_set_emit`），`emit_sink` 是 NULL，**每一行都被丢掉且不报错** | `Emit.install` 同时做这两件事；`WeiShellTests` 里有一条真启 runtime 的测试守着 |

## 二、SwiftUI / 编译期摩擦

每一条都让人原地卡过一次，而且**错误信息基本指不到问题**。

| 症状 | 原因 | 修法 |
|---|---|---|
| 泛型参数推导失败，错误里出现 `TableColumnBuilder` | 在 `Form` 里用 `Group { Section(…) }` 分组：`Group` 的 builder 泛型是给表格列的，推不出来 | 自己写一个 `@ViewBuilder` 容器（我们叫 `rebuild`），别用 `Group` 装 Section |
| 每个 `Section("…")` 突然都不是 view 了 | 文件里嵌套了一个叫 `Section` 的类型，**遮蔽** `SwiftUI.Section`（只在文件内，但整个文件） | 别用会撞的平台类型名。我们把 `SettingsView.Section` 改成了 `Pane` |
| `incorrect argument label` | `.dropDestination(for:action:isTargeted:)` —— 我猜的是 `isTarget:` | 以 SDK 为准；这类标签猜不中 |
| `contextual closure type '() -> KeyPress.Result' expects 0 arguments` | `.onKeyPress(.return) { }` 这个单参重载**不给闭包传参数** | 要拿到 `KeyPress`（进而读**事件自己**的 modifiers）必须写 `phases:`：`.onKeyPress(.return, phases: .down) { press in … }` |
| ⇧Return 的行为和代码不符 | `NSEvent.modifierFlags` 读的是**此刻硬件**的状态，不是被处理那个事件的状态；合成/重放的事件更是完全无关 | 用事件自己的 `press.modifiers` |
| `NSImage` 上没有 `pngData` | 它确实没有 | 过 `NSBitmapImageRep`（扩展在 `macos/WeiShell/Sources/WeiShell/Composer.swift`） |
| 粘贴图片的回调从来不触发 | `onPasteCommand(of:)` 只在剪贴板**能提供**所列类型时才提供该命令（**这条是 API 语义，我没有逐个场景验证**） | 它意味着这条路径无法保证可达 —— 所以另给了一个菜单项（⌘⇧V），不赌谁能拿到 ⌘V |
| 把快捷键写进 `Menu` 项的标题里（想让 `+` 菜单里两项看起来不一样） | **自定义 `label` 会被菜单丢掉**：`Button { … } label: { HStack { Text("Take Screenshot"); Spacer(); Text("⇧⌘S") } }` 渲染出来只有 `"Take Screenshot"`，和另一项一模一样（AX 里两项的 title 就是这么报的） | 用平台的 key-equivalent 列：给这一项挂 `.keyboardShortcut(…)`，AppKit 会在右边画灰字。同一个快捷键写在两处（菜单栏 + 弹出菜单）是安全的：**菜单打开期间，菜单栏先被搜索，所以按键跑的是菜单栏那一条** |
| 一个 sheet 在某种输入下**窄得不能看**：截屏框选出一个词（90 点），`VStack` 跟着缩到 90 点宽，五个工具的标签各挤成几个点，Cancel / Insert 叠在一起 | 宽度是 `paper.size.width + padding`，而截图带来了自己的尺寸 —— 空白草图固定 640 点所以从来没露过这个面 | 给**整张 sheet** 一个下限（`max(纸宽, 420)`），而不是只给控件行 `minWidth` —— 后者会让下面的行比纸宽，按钮跑到纸外面去 |

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
| 想让 `.inset` 列表的行左右/上下多留白，改了 `.listRowInsets` 或 `.contentMargins(.horizontal, for: .scrollContent)`，一点没变 | 在 macOS 上这两个 modifier **对列表的行内边距不起作用**：四种写法（不设 / `listRowInsets` / `contentMargins` / 两者都设）量下来，`AXRow`、`AXCell`、`AXStaticText` 三层的 frame **一模一样**（285×320 的探针壳子：行 x=290…610、单元格 300…600、文字 306…） | padding 加在**行自己的内容**上（row view 里 `.padding(.horizontal, …)`）。量法：读 AX 的 `AXRow`/`AXCell`/`AXStaticText` 三个 x —— 三者一起动才算真的动了 |
| 想让确认对话框里多一个「顺便把文件也删了」的勾选框 | **SwiftUI 没有这个控件**：`confirmationDialog` 的 actions/message 是 `ViewBuilder`，但对话框最终就是一组按钮，塞进去的别的视图不会到（`dialogSuppressionToggle` 是「别再问我」——「别再问」和「顺便也删文件」是两个问题）。查 `swiftinterface` 也没有等价物 | 用 **`NSAlert` + `accessoryView = NSButton(checkboxWithTitle:…)`**：macOS 的 `NSAlert` 是系统里唯一能在按钮旁边再放一个控件的对话框，而 SwiftUI 自己的 alert 底下就是它（这是**平台的对话框**，不是平台视图 —— 和菜单栏、剪贴板同一类，见 ADR-0008）。`beginSheetModal(for: window)` 让它是挂在窗口上的 sheet；`alertFirstButtonReturn` 是「Delete」，勾选框只**修饰**它（勾了再 Cancel 什么都不删）。记住第 0 个按钮是**默认**（Return），第 1 个是 Esc |
| 用 macOS 26 的 API，但 package 的 target 是 14 —— 会不会崩在旧系统上 | —— | 用 `swift build` 后 `nm -m <binary> \| grep glassEffect` 看是不是 **weak external**，再 `otool -l \| grep minos` 看部署目标。weak 链接 + `if #available` 就是安全的 |
| 搞不清一个 `ToolbarItem` 会落在**哪一栏**（三栏 split），截图看不出来 | 同一段声明换 placement 会落到不同栏，而且栏与栏在视觉上只隔一条分隔线 | **从进程内部读 `NSApp.windows.first?.toolbar?.items`**：`item.view` 的 frame 相对整窗，再沿 `superview` 链找到 superview 是 `NSToolbarView` 的那个祖先（item 自己的 frame 是相对 item view 的）。实测：声明在侧栏、`.automatic` → `x=117…161`（侧栏，在平台自己的侧栏开关 `x=161…208` 前面）；`.navigation` → 中间栏；`.primaryAction` → 窗口尾端。顺带同一条链上能读到 item 里的 `NSTextField`：平台画的窗口标题是 `_NSToolbarTitleField`（实测 `x=226 h=16`），可见它仍然在画 |
| 想知道「设置面板是不是系统那样的偏好工具条」 | `TabView` 放在 `Settings` 场景里才会被画成偏好工具条；放在普通窗口里就是普通 tab | 同一套自查：AX 树里 `AXToolbar` 下面一个 `AXButton` 一个标签，窗口标题是当前标签名（实测五个标签 `x=103…417`、窗口标题 `API Key`） |
| 往**侧栏的工具条里**塞两样东西（标志 + 名字，或者任何想叠两行的 item） | 工具条那 **52 点是整窗共用、一行深**的带子：item 自己多高都没用（实测高 31 的 item 和普通 item 占同一带子），倒是会**挤压邻居**——18pt 的标志 + 系统的侧栏折叠按钮两个 item 要 61 点，而侧栏只有 208 点，于是折叠按钮从 47 宽被压到 38 | 想让两样东西上下叠，得有一条比它们高的**槽位**：要么是这一栏的内容行（`VStack` 的第一行），要么自己画一条带子。顺带：`.toolbar(removing: .sidebarToggle)` 加在 `WorkspaceList` 上**看不出效果**（实测带子里的 item 一个不少），而且就算去掉了它，带子也不会变矮 —— 别指望用这个抢地方 |
| 想让内容落在 **`.searchable(.sidebar)` 的搜索框上面**（比如「标志 + 名字」放搜索框上方） | 那个搜索框是侧栏的 **accessory band** —— 平台拥有的槽位，在标题栏和这一栏内容**之间**：这一栏的安全区从带子**下面**才开始（实测搜索框 `y=61…89`，这一栏的内容 `y=98` 起），所以这一栏自己画的任何东西都到不了它上面；真挤上去只会压在标题栏的拖动区上 | 要那个顺序就**自己摆控件**：`NSViewRepresentable` 包一个 `NSSearchField`（`.searchable` 用的本来也是它），尺寸照抄带子（高 28、离边缘 10）。别自己画胶囊——自画的 `.glassEffect` 压在侧栏材质上会**发黑**（实测填充 124–138，侧栏本身 220–247） |
| **语音听写：字一个个正确地上屏了，但永远没有"最终结果"，句子永远不会变成可发送的文本** | `DictationTranscriber` / `SpeechTranscriber` 的 `reportingOptions` 里**只给 `.volatileResults` 不会产生 final**：实测 3 秒的句子→12 个 partial、**0 个 final**；`finalize(through:)`、`finish(after:)`、`finalizeAndFinishThroughEndOfInput()` 都改变不了；把音频流 `finish()` 掉只会让结果序列以 `CancellationError` 结束。两个选项是两件不同的事：一个是"早点告诉我"，一个是"定下来" | 加上 **`.frequentFinalization`**。同一段音频、其它参数不变：`FINAL: 请帮我加一个语音输入的按钮`。而且它会**在说话中间就定稿**（句中的停顿就是边界），所以消费侧必须能处理"句子在还在听的时候结束"：定稿一句→继续听下一句，只有读者按停才结束会话 |
| 看着麦克风按钮按下去，**开头一两秒说的话丢了** | 麦克风和模型是同时启动的：音频已经在流，而模型还在加载（实测：两个 run 各丢一次，一次丢句首的「请帮我」，一次丢整句） | **先 `prepareToAnalyze(in:)` 再开采**（实测：模型热时 ~0.24s）。这个"正在准备"得是读者**看得见**的状态（按钮变成 `Starting to listen…`），否则就是一个没有解释的延迟 |
| 想知道一个语音模型装没装 | **没有报错**：`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` 直接返回 `nil`，而且这个语言在 `supportedLocales` 里是有的。看文件也会一样：`AVAudioFile` 跑同样的音频会报 `SFSpeechErrorDomain Code=5 "No common audio format among modules"`（这个错误名和真实原因没关系） | 用 `AssetInventory.status(forModules:)`（`.installed` / `.supported`…）+ 有没有 `assetInstallationRequest`。**支持 ≠ 装了**：实测本机 `zh_CN` 是 `.installed` 而 `en_US` 在 `DictationTranscriber` 下报 `.supported` + `fmt=16000Hz`（能用，也没报要下载），同一个 `en_US` 在 `SpeechTranscriber` 下 `bestFormat=NIL` —— 两个模型不是一回事，**用 `DictationTranscriber`**（系统听写用的就是它，有 `.shortForm` 提示和 `.punctuation`/`.emoji`） |
| 用 `ad-hoc` 签名重新打包后，麦克风权限又要重问一遍 | TCC 认的是代码签名，而 `codesign --sign -` 每次重建都产生不同的 cdhash —— 实测：重打包后跑，日志里 `authorizationStatus` 是 0、按钮等 5.5 秒才拿到 3（就是那个弹框）；另一轮重打包后又没问（系统似乎也认了 bundle path/identifier） | **给本机一张固定的自签身份**：`macos/make-identity.sh`（已接进 `make-app.sh`）。权限绑的是 App 的 designated requirement，而 `codesign -d -r- <app>` 能把它打出来：ad-hoc 的里面是 **cdhash**（每次构建都变），自签的里面是 **证书**（不变）。实测两个不同的二进制、同一张身份签：cdhash 不同（`cbb5…` vs `de6f…`），requirement **逐字节相同** —— 所以「重打包 = 换了个 App」被消掉了。换身份那一次权限会重问一次，之后不再问。**别指望私有 SPI 绕过这一步**：实测 `SLPreflightPostEventAccess`（私有）和 `CGPreflightPostEventAccess`（公开）同为 `false`，绕开的是“目标应用拒不接受事件”，不是 TCC |

## 五、验证与自动化（这次最费时间的一块）

手动验证 macOS UI 很贵，而**便宜的验证方式是存在的**，只是要走对路。

| 症状 | 原因 | 修法 |
|---|---|---|
| AppleScript 读 UI 崩掉（`-2741` 语法错 / `-1700` 类型转换失败） | 这个 app 的 AX 树很深，`entire contents` 会把整棵树物化成列表再逐项类型转换，量一大就崩 | 写一个 **Swift AX 工具**：`AXUIElementCreateApplication` + 递归 `kAXChildrenAttribute`，一棵树几十个节点一次读完 |
| 用 AX 设了 text field 的 `value`，界面没反应 | AX 的 `set value` **驱动不了 SwiftUI 的 binding** | 必须发**真事件**（`CGEvent`）或真按键（`osascript keystroke`） |
| 想断言「发送按钮现在可用吗」 | —— | AX 的 `kAXEnabledAttribute` 是读得出来的，这对验证状态机很省事 |
| 用 `strings` 在 release 二进制里找菜单项标题，找不到，以为菜单没编进去 | `-O` 会做字符串池化 / 后缀合并：一条字面量可能只是另一条里的一段偏移，于是那串字节根本不存在。**最小复现：**一个只有 `CommandMenu` 的 30 行 app，`-O` 编完后 `Next Session` / `Stop Turn` / `New Session` 全为 0，而同文件里的 `Previous Session` 还在 —— 连**早就正常工作的** `⌘N` 的 `New Session` 也不见了 | `strings` 不是验证菜单的方法。要么加个 AX 工具读 `AXMenuBar`，要么真启动一个、看一眼 |
| `osascript` 里找不到输入框 | 表单里有两个 `AXTextField`（设置面板的搜索框、输入框），按顺序取会取错 | 按 **position.y** 取最靠下的那个 |
| 启动后拿到的 PID 不对 | `( … & )` 拿到的是**子 shell** 的 PID，不是 app 的 | 子 shell 里用 `exec env … /path/to/wei`，再 `echo $!` |
| `pkill -f "Macos/wei"` 把自己也匹配上了 | `-f` 匹配整条命令行，而你的 `bash -c` 里就写着这个字符串 | 用锚定：`pkill -9 -f "Macos/wei$"`。**这条我照着写了又踩了**：`pkill -9 -f "Macos/wei"` 没杀掉任何一个 app（用户那个进程活得好好的），因为模式先匹配上了**它自己所在的 `bash -c`**，命令根本没走到那一步。教训是锚定要落在**参数的位置**上，`$` 放在路径后面；光把模式写短不算锚定 |
| 反复启动后测到的行为不对 | **多个实例在跑**，你连的是上一个 | 每次测完按 PID 确认存活；断言时带上 PID / 窗口标题。顺带：两个实例**在同一个会话里各发一句**是会交错写进同一个 `.jsonl` 的 —— `Open.turns` 那把 mutex 只管**本进程内**；为什么先不修、以及真要修时最小的形状，见 [ADR-0009](adr/0009-multi-session-coordination.md) |
| 明明改了代码、也重新打包了，**跑着的 app 显示的还是旧行为**（我这一轮：把 Sketch 从 `+` 菜单里拿掉了，菜单里还有它） | 上面那条的镜像：**两个实例同时活着**，而且这次两个都是同一个 bundle 路径、同一个窗口尺寸、同一个位置 —— 你截到的是别人那一扇。`pgrep`/`ps` 看得见两个 pid，但窗口列表里两扇窗的参数一模一样，看截图分不出来 | **AX 是按 pid 读的，所以状态问题一律用 AX 问**：`AXUIElementCreateApplication(pid)` 之后 `kAXMenuBarAttribute` / 遍历 `AXChildren`，那条 `AXMenuItem "Sketch"` 属不属于你那个 pid 一目了然。只有**点**是按坐标的（点会落到最前面那扇窗上），所以点之前先 `NSRunningApplication.activate` 并确认 `frontmostApplication.pid`。实测：我用坐标点 + 截图得出了「菜单里还有 Sketch」的错误结论，用 AX 一问是另一个 pid 的窗口 |
| 按 PID 找窗口号 | 用户的 app 和你的 demo 同时跑时，按 owner 名选窗口会选到**用户那个**（两个进程 owner 都叫 `wei Agent`） | 按 `kCGWindowOwnerPID` 过滤 `CGWindowListCopyWindowInfo`，取 `layer == 0` 且有标题那个；`.optionAll` 是必须的（见第六节） |
| 看不见 `Settings…` 菜单项；或者想切设置窗左边的某一项，AX 里翻不到 | 主菜单在**主线程忙的时候还会重建**（启动早期能看到的菜单项，几秒后又一次 `NSApp.mainMenu` 就变了）；而列表行的 `AXPress` 返回 **-25206**（不支持该动作） | 菜单项拿不准就不要猜选择器（`sendAction(showSettingsWindow:)` 返回 `true` 却什么都不做）：按 desc 找主窗左下角那个 `Settings` 按钮按下去。切换左栏那一项用**设 `kAXSelectedAttribute`**（不是 `AXPress`） |
| 想把窗口改小，好看清滚动边缘效果 | `kAXSizeAttribute` 写入返回 **-25200**（不可设） | 改小不行就换成**内容长的那一项**（Skills 会列一长串技能）再滚；或者去 `/tmp` 写一个只含布局的壳子（第六节） |
| 把 `safeAreaBar` 的 bar 摆在 `ScrollView` 上面，第一行文字**和标题重叠** | `safeAreaBar` insets safe area，但挡住第一行的不是它 —— 是转录自己的 content margin，而那个数是从**窗口顶边**量的（`Wei.Control.toolbar`）。两个机制各懂一半 | bar 的实际高度量出来加进 content margin（`ConversationTitleHeightKey`），别写常数 |
| **列表行变高了，但被裁掉**：某个 `@State` 一变，一行的内容多出一行字，结果最后一行被行的下边缘切掉一半 | **`List` 的行高是「建行时」量的，之后不再量。** 同一个身份（`.tag(path)` / `.id`）的行内容变了，SwiftUI 就地更新视图，不重新测量行高。实测两次，症状一样：行仍是 `300x52`（`123..175`），而内容要 60 点，最后一行落在 `y=168…183` —— 被切掉。两次的触发不同：一次是 `running` 从 false 变 true（同一份 rows 里一行自己长高），一次是搜索（行的身份没变，只是内容里多了一行项目名） | 让**行高与内容无关**：把第二行固定成一行，什么都往里排（项目 · 时间 · 状态胶囊）。另一种做法是给行一个够高的固定高度，代价是每一行都付那次高度。**不要**靠「内容变了会重新布局」——它不会。（`List` 的行和普通 `VStack` 不一样：`VStack` 会重新布局，`List` 的行缓存高度） |
| **`ScrollViewReader.scrollTo(id)` 什么都不做**，而且不报错、不警告、不滚动 —— 看起来像布局问题或时序问题 | `scrollTo` 对一个**没有任何视图注册的 id** 就是空操作。本窗口注册的是**轮**的 id（`ForEach(turns, id: \.element.id)`），而轮的 id 是它那条提问的行 id；顺手写的「最后一行」`rows.last.id` 几乎永远不存在 —— 一条回答之后，最后一行是那段回答的一个**块**（id 是 `"<轮>/<块>"`） | 滚到 `endOf(rows)`（`WeiModel/Turns.swift`，取 `turns(of:).last?.id`），并且**把这条规则放进有测试的地方**：`TranscriptEndTests` 里专门有一条断言 `rows.last.id != endOf(rows)`。另外 `LazyVStack` 会让时序也掺进来（刚到的行还没建），所以滚动还要 `DispatchQueue.main.async` 推迟一拍 |
| **按 Stop 不停正在跑的命令**：状态变成「stopping…」，但 `bash: sleep 60` 一直跑到自己结束 | `aborting` 是个**标志**，由回合在**两步之间**读；而正在进行的那一步**就是**工具 —— 所以标志只在工具跑完那一刻才起作用。`@agent.ToolHandle` 早就带着 `stop` 字段（drviver 用它 `task.cancel()`，再由取消路径按 pid 杀），但宿主只把它用来**画那一行**，没有存下来 | 把 handle 存进 `Open`（`running_tool`），`Abort` 时**取出并调用**（取出而不是读取：第二次 Stop、或工具已报完之后的 Stop，不能去取消别的东西），回合结束时 `defer` 清掉。验法：起一个假模型（几十行 python SSE 返回一个 `bash: sleep 60` 的 tool call，`DEEPSEEK_BASE_URL` 指过去），发一句、等 `sleep 60` 出现、发 `abort`、看 `pgrep -f '^sleep 60$'` —— 实测从「还在跑」变成「已经没了」 |
| 想在同一个 `ToolbarItem` 区域里放**第二个** item（比如标题 + 改名的铅笔） | 平台会**重排整行**，而且不是「往右挪一点」：会话栏那个标题从自己的栏（`x=467…921`）跑到**列表栏上面**（`x=230…397`），同时**窗口标题被挤走**（`x=230…864` → `x=397…557`，压到两栏交界）。把两个控件塞进同一个 item 的 `HStack` 也一样 | 这一栏要两样东西就**自己画 bar**（`safeAreaBar` + `HStack`），别指望工具条排两个 item。量法：`axframe`，四个 x 一比就知道 |
| 把**平台画的窗口标题**换成自己画的（`toolbar(removing: .title)` + 自己的 item），只为了改字号或腾地方给按钮 | 画出来的是「窗口标题的照片」：`navigationTitle` 留着则 Window 菜单/辅助功能仍读平台那份（两处不一致），去掉则窗口真的没有标题 | 先问「值得吗」。这次做了一版又回退：理由（腾地方给按钮）其实靠 `.primaryAction` 就解决了，而字号本来也改不了（下一条）。真要控字号只有自己画这一条路，那就准备好接受上面那两种代价 |
| 想改**平台画的窗口标题/副标题的字号** | **没有这个 API**：`NSWindow` 只有 `title`/`subtitle` 两个字符串，AppKit 里没有任何 title font / attributed title；SwiftUI 的 `toolbarTitleDisplayMode` 文档明说 "This modifier has no effect on macOS"（`toolbarBackgroundVisibility` 那种是另一回事）。`font()` 也管不到，因为那些字不是你的视图画的 | 要控字号就**自己画**：`toolbar(removing: .title)` 去掉平台那枚，再把标题放进自己的 `ToolbarItem` / bar；`navigationTitle` 留着让窗口仍然有名字（Window 菜单、辅助功能照旧）。实测平台那枚是 13 semibold / 副标题 11 |
| 工具条 item 里的 `HStack`/`VStack` 不撑满整栏（比如「标题 + 按钮」里的按钮没飘到栏的最右） | item 的宽度由内容定：实测 `x=230…388`（158pt），`frame(maxWidth: .infinity)` 放在里面的 stack 上不解决问题 | 位置就按内容排（这也常是想要的：按钮紧跟标题，像备忘录）；真要靠到栏尾，得让 item 自己弹性（实测：单独的 `Text` + `.frame(maxWidth: .infinity)` 会撑满，stack 里不会） |
| 把一个 item 声明在**中间栏**（content）但想要它压在该栏上 | `.navigation` 会给它这一栏的最前（实测 `x=230…271`），但**窗口标题同时被挤走**（→ `x=397…557`）。`.secondaryAction` / `.confirmationAction` / `ToolbarSpacer(.flexible)` 都是同一个结果 | 要么接受它在窗口尾端（`.primaryAction`，实测 `x=872…917`，那其实是**会话栏**上面），要么**不用工具条**、把控件画进这一栏的内容里（改版，不是改 placement） |
| bar / 自定义视图里的按钮显示成了「图标 + 文字」 | `Label` 在工具条里只画图标，在普通视图里图标文字都画 | 要图标就给 `Image(systemName:)`，文字用 `.accessibilityLabel`；顺带 `.buttonStyle(.borderless)` 去掉边框 |
| 想看「标题和工具条是不是同一行」，靠看截图估 | 截图能量，但估不准 | **读 AX 的 frame**：`axframe`（第六节）把整棵树连 `y=.. x=..` 打出来。工具条是 `AXToolbar y=0..52`，按钮 `x=872..917`，标题 `y=14..38` —— 两行是不是同一行，一眼就有数字 |
| 工具条 item 的高度/内容想靠 `padding` 挪位置，结果转录第一行被压住 | bar 的高度就是转录第一行要避开的量（`contentMargins(.top, 工具条 + bar 高度)`） | 只是**画**的位置要挪，就用 `offset`（不改布局高度）；要连高度一起改才用 padding |
| 给 `safeAreaBar` 里那块内容加上内边距，字却只挪了**一半**距离 | 块是**按中线**抬到工具条那一行的（`titleLift = 工具条/2 + 块高/2`），所以块内的 padding 被算两次：一半把字推下去，另一半把块顶高、再把它整体拉回来 —— 推送和拉回等量 | 写这个数的时候心里除以二（实测：`padding(.top, 8)` 把标题行盒从 `y=5` 挪到 `y=9`）。见上一条：改成单行影响布局的量就没这回事，但那样又多一个会过期的数 |
| 想把标题和工具条的按钮放成**同一行**，把标题放进 `ToolbarItem` | 工具条 item 的宽度是固定的：**长度超过可用宽度的 item 会被收进溢出菜单**（右端出现 `»`），并且把同一行其它 item 的位置挤乱 —— 长标题的结果是「标题不见了 + 按钮移位 + 多了个 chevron」，而不是省略号。顺带它还会破坏顶部那层边缘效果。见下一条 | 别往工具条里塞长文本：`safeAreaBar` 画在工具条下方（那样才有模糊和 inset），再把**文字**抬到工具条的中心线上（`ConversationView.titleLift`），抬起的量在下面补回去，bar 高度不变 |
| 自己画的 bar 里多了一行内容（标题下面加副标题），结果**副标题掉到工具条线下面**、挂在转录上 | 抬起量原来是个**常数**（`titleLift: CGFloat = 41`，是「块只有一行」时量出来的答案）。块高变了，中线就不在 26 上了 —— 名字还在工具条那行，项目那行掉到它下面 18pt（`y=5..29` vs `y=31..46`） | 把「抬多少」写成**从块高算出来的**（`toolbar/2 + height/2`，`height` 就是 `ConversationTitleHeightKey` 那个数），而不是一个只在旧内容上对的常数。这是「量出来的值要跟着被量的东西走」那条的变体：常数比公式便宜，但只在它量的那个形状上对 |
| 想让 `Text` 末尾出现省略号，写了 `lineLimit(1)` + `truncationMode(.tail)`，结果没有省略号 | 省略只发生在**宽度被约束**的时候：一个自然宽度的 `Text` 会要多少给多少，超出部分被邻居裁掉而不是变成 `…` | 加 `.frame(maxWidth: .infinity, alignment: .leading)`（或别的上限），让平台知道可用宽度是多少 —— 再用**尾部内边距**给它让开右边的按钮 |
| 想量「标题在不在工具条那一行」，靠看截图估 | 截图能量，但估不准 | **读 AX 的 frame**：`axframe`（第六节）把整棵树连 `y=.. x=..` 打出来。工具条是 `AXToolbar y=0..52`，按钮 `x=872..917`，标题 `y=14..38` —— 两行是不是同一行，一眼就有数字 |
| 想看「内容从 bar 下面穿过去被模糊」的效果，滚了半天没反应 | 那一栏的内容不够长，压根没有可滚的东西（设置面板的 API Key 那页就装得下） | 换内容长的一页（Skills）或长会话；也可以只写布局的壳子（第六节）。注意合成滚轮事件 `wheel1` 是 `Int32`：传负数给 `Int()` 再装回 `Int32` 会 crash（`Range requires lowerBound <= upperBound`） |
| 改了「换会话」相关的代码，测完用户说他打了一半的字跟着跑 | 我**拿用户正在用的会话做了测试**，进程真的把新 turn 写进了他的日志 | **纪律**：测试先 `cp` 一份会话到临时目录，用 `WEI_SESSION` 指过去。永远不碰 `~/.wei/sessions/` |
| 手写一条 `.jsonl` 造演示会话，app 只回一句 `could not start: missing field: timestamp` —— 没有别的线索，看起来像 store 没发现、像路径不对、像编码不对 | `Entry::from_json` 要的**每一层都有 `timestamp`**：entry 一层，`message` 一层也是（真实日志里 assistant 的 message 自带 `timestamp`/`usage`/`model`/…）。只写 `role`+`content` 的 message 不是一条能读的记录 | 别手写：`cp` 一条真会话，**只替换 assistant 那条的 `content[].text`**，其余字段照搬（一轮就通）。再配 `WEI_SESSION=<那条文件的路径>` 直接打开它 —— 会话标题会变成它的 id，不必让 store 发现工作区 |
| 想造一段「要长到能滚」的转录，结果只有几行 | 上面那条修法把小会话变干净了，也把它变短了 —— 而模糊/滚动这类效果需要**有东西滚** | 复制一条**大的**真会话（按文件大小倒序取第一条，几十兆也行）到临时 store、改 header 的 `cwd`，`WEI_SESSION` 指过去。一次就得到上千条消息，且一个 token 不花 |
| 同一台机器上开着用户的 app，自己又起一个 demo，截图/断言拿到的是**错的实例** | 两个进程 owner 都叫 `wei Agent`（debug 可执行文件的 owner 是 `WeiShell`，但 `.app` 那个不是），按名字选窗口会选到用户那个 | 按 **PID** 过滤 `CGWindowListCopyWindowInfo(.optionAll)` 选窗口号（`scripts` 无关，十几行 Swift 就够），再 `screencapture -x -o -l <num>`（`-o` 去掉阴影）。见第六节 |
| AX 树太大，AppleScript 直接放弃 | 1500 行的转录 + 长会话 | 也是上面那条：用 Swift AX 工具，或者拿小的会话测 |

| 切会话先**白屏**、滚一下才出内容 | 两件事叠在一起，而且**都在「谁先谁后」上**：① shell 先发 `session`（换转录）后发 `history`（rows），宿主换到一份**空**转录上；30MB 会话这段空窗约 150ms（解析 54 + 建行 25 + 编码 16 + 主线程解 JSON 51）。② 落位那句 `guard let end = endOf(rows) else { return }` 在空转录上**直接返回** —— 旧顺序下它只有一次机会，而那次必然落空 | 把顺序反过来（`say_open` 里 `history` 在前），宿主的路由本来就会把「不是当前会话的 rows」归档到那个会话名下，于是 `session` 一到就换成有内容的那份：**一次渲染**。落位的 guard 顺带就成立了（有测试钉住这个配对）。另外「空栏」和「没加载完」要能分开（`Conversation.loaded` + 一行 `Opening…`） |
| 同一条**行身份**在两个会话里都存在，于是折叠状态跨会话乱串 | `history_rows` 的 `h-N` 是**每次调用各自计数**，两个会话都给 `h-1`、`h-2`…；而 SwiftUI 对身份相同的视图**保留 `@State`**（`ForEach(turns, id: \.element.id)`，轮的 id 就是提问行的 id） | 把这一叠行**按会话作用域**：`.id(session)` 加在 `LazyVStack` 上（**不是** `ScrollView`：滚动位置和落位机制挂在那上面，给它换身份会把落位一起换掉）。shell 侧那条事实也有测试（「history ids start over in every session」） |
| 拿 `print` 量出来的一堆数字当性能结论 | 我第一版是在 `swift test` / `moon test` 的 **debug** 构建里量的：`parse_session_file(30MB)` 320ms、`Envelope.decode` 57ms。同一段测试换 `--release` 是 **54ms / 51ms**，差 5 倍 | 报数字前先问「这是哪个 profile」。SwiftPM 是 `swift test -c release`，MoonBit 是 `moon test --target native --release`；两者都跑一遍再下结论（这次两栏都写进 `macos/README.md` 了） |
| 编辑 app 正在写的 `WEI_DEBUG` 日志，看到 0 字节，以为「宿主根本没读流」 | 句柄是**启动时**开好的（`WireLog` 的 `static let handle`），app 起来之后再 `rm` 或 `> file`，写入就落到那个已经不在的 inode 上了 | 要清空就先确认那个 pid 已经不在了；或者干脆换个文件名重新起一个。同理：**先起 app 再 `rm`** 会得到「一切正常但日志是空的」 |

| 想在**没有辅助功能 / 屏幕录制**权限的机器上验一个 SwiftUI 改动（新 sheet、画布） | `AXIsProcessTrusted()` 和 `CGPreflightScreenCaptureAccess()` 都是 `false` —— 而截图只是只读、驱动要 AX，于是「窗口里到底长什么样」这一步**根本到不了**，不是难，是没路 | 把改动切成**不依赖窗口**的两半去验：**算术**进单元测试（`SketchTests`：拖拽矩形的归一化、多小的拖拽不算一笔、零长度箭头的两支）；**产物**走一遍真边界 —— 生成出来的 PNG 直接喂 `wei-cli` 的 `/attach-temp`，看回的 `images` 事件里是不是 `image/png`、文件是不是被删掉了。窗口那一半没验就**明说没验**，别把「模型对、字节对」说成「功能对」 |
| 想知道**一个命令在 TCC 被拒时说什么、退出码是什么**，而自己的进程早就授权了（终端、编辑器、这个 app 全都「能看」） | TCC 认的是调用方的签名身份，所以「我这台机器上它有权限」不等于「别人的机器上它有」—— 同一条命令在两种身份下可以给出**完全不同的两套回答**（实测 `screencapture -i`：有权限按 Escape 是「安静 + 退出 0」，没权限框选完是 `could not create image from rect` + 退出 1） | 给自己造一个**另一个身份**：`/tmp/x/Probe.app`（自己的 `Info.plist` + `CFBundleIdentifier`，`codesign -s -`），里面那个可执行文件跑一遍命令、把 stdout/stderr/退出码写进文件。这个 bundle 没被授权过，于是它替你回答「被拒时是什么样」。`open -a` 启动它（不要从 shell 直接跑，那会把权限算在 shell 头上），然后 `log show --predicate 'process == "probe"'` 能看到 TCC 的调用 |

| 线上有**一条**事件比别的重几个数量级，主线程卡一下 | 两件事都在这条路上，而且都不在「解码」里：① **日志没开时的日志开销** —— `WireLog.line` 自己有 guard，但**参数在调用前就算好了**（`trimmingCharacters` 拷贝整行、`elided` 扫描并在找到附件时重写），于是 `WEI_DEBUG` 未设置时也为一条 4MB 事件付 **101ms 主线程**；② shell 为**没人画的行**发解析（reasoning 占 1.6MB/4.05MB） | ① 参数的计算一起进 guard（`if WireLog.isOn { … }`）；② 让「谁会读这个字段」在**一处**决定（`draws_markdown`），发出方与消费方共用那一个答案 |
| 探针报出来的数字比应用还大 | 量具自己贵，而且贵在看不见的地方：**`String(describing:)` 一个有 1353 行的事件 = 166ms**；**每 tick 把整个窗口渲进位图 = 33ms/帧**（于是「切换后每帧 33ms」看着像应用的病） | 探针要跟被测物同量级：标签用 `String(line.prefix(48))` 而不是 `"\(event)"`；昂贵的渲染只在一头一尾做，不要放进每帧的循环。**先把量具本身量一遍**再相信它 |
| 一个「让首帧落在末尾」的 SwiftUI 旋钮看起来像是解药 | `.defaultScrollAnchor(.bottom, for: .initialOffset)` 在实测里 **168.6 vs 174.7ms**，落在噪声里 —— 因为那 240ms 不在锚点上，而在「懒布局文档有三万点高」这件事本身 | 量了没效果就**回退**，别留下一个量不出效果的改动；换杠杆（降低文档高度 = 窗口化） |

| A/B 两组的数字**一模一样**，于是结论是「这个改动没用」 | 只改了 MoonBit 侧、只跑了 `build-moonbit.sh` + `swift build` —— **SwiftPM 不知道 `vendor/libwei.a` 变了**，跑的还是旧二进制。症状不是报错，而是「两次测量完全相同」（实测：`doc=15480/15492` 一模一样地出现在「关掉分页」那一组里，而那本该是 32562） | 只要改了 `macos/appffi/`，**`rm -f` 掉那个产品再 build**（`.build/release/<产品>`）。判据很硬：A/B 若在**不涉及噪声的量**上完全相等，先怀疑自己没换成二进制。这条是 `macos/README.md` 那节的复现，我照着懂还是踩了 |
| 一个「接近顶部就加载更多」的自动加载，在**切换会话**时连发了好几页 | 触发条件只看了「偏移接近顶部」，而**切换的那一瞬间偏移还是上一个会话的**（新会话的 rows 到达时它接近 0），于是触发；每加载一页又把偏移留在顶部，再触发。它同时和「跟随」规则抢同一个 revision：一个要把读者放到底部，另一个在他上方加行 | 触发条件里加「读者**自己**滚上去了」（这个仓库已经有的 `ScrollFollow`：`!following` 就是「他正在读上面的东西」）。用真探针看 `rows` 从 212 涨到 628 才发现，只看「白屏消失了没有」是看不出来的 |

## 六、调试手法（正面清单，别丢）

这些是**找到** bug 的东西，比任何一条坑都值钱。

- **`WEI_DEBUG=/tmp/wei-wire.log` 抓整条线上**：两个方向、一行一条。发送那个 bug 就是这样定性的
  —— 日志里 `ShellClient.send text=[]` 直接指出「处理器被调用了，但拿到的是空串」，比在 SwiftUI 里猜快得多。
  注意它**会**包含 prompt（附件字节已做 elide：`WireLog.elided`）。**别在 app 起来之后再动这个文件**
  （`rm` 或 `> file`）：句柄是启动时开好的，删掉之后写入就没了，看到的是一个 0 字节的日志 —— 这一轮
  我把它当成「host 根本没有读流」，其实是自己删的。`>` 之前先确认那个 pid 已经不在了。
- **需要知道「视图内部此刻是什么」时，直接 `FileHandle.standardError.write`**：app 的 stderr 重定向到
  文件即可。这次靠它在 `onKeyPress`、`submit()`、`ShellClient.send` 三处打点，一次就分清了「没触发」
  和「触发了但值是旧的」。
- **自己进程的 AX 树不需要任何权限。** 第六组里那三条「看/点/读菜单」的权限约束只针对**别的**进程：
  `AXUIElementCreateApplication(getpid())` 递归读 `kAXChildrenAttribute`，一行命令就能拿到整棵树的
  `role/title/value/x/y`（这次临时加了个 `WEI_AXDUMP=1` 就走的探针，十分钟里靠它定了五件事：行内边距、
  工具条 item 落在哪一栏、平台还在不在画标题、设置面板是不是真偏好工具条、副标题掉到哪去了）。
  只有想要**事件**（鼠标/键盘）时才必须去要辅助功能权限。
  量到的是 AX 的 frame，不是像素，所以它只说「在哪里、多大」，不说「好不好看」—— 好看仍然只能靠眼睛
  （而截图要屏幕录制权限，会掉）。两者互补：AX 回答「是不是同一行」，截图回答「这一行难不难看」。
- **想要像素、又没屏幕录制权限时：让窗口把自己画进一张位图。**
  `view.layer?.render(in: ctx)`（要 scale 2 的 `CGContext`，先填白），视图用类名 substring 找；
  `bitmapImageRepForCachingDisplay` + `cacheDisplay` 看着更正规，**但 SwiftUI 的侧栏栏是空的**
  （它的背景/内容在 layer 里，不在 draw(_:) 里）—— 两张都存，对照着看哪张真画了。工具条在
  `contentView.superview` 里，不在 `contentView` 里。这是**同一进程**的读，不碰 TCC，
  而且比真截图快：不用管窗口会不会被遮、会不会掉焦点。
- **想验证一个「输入 → 绑定 → 列表」的回环，就要走真的输入通路。** 回环里最容易静默断掉的一环是
  委托：直接设 `field.stringValue` 不会调委托，于是界面看起来填上了、后面的列表一动不动。
  走 `makeFirstResponder(field)` + `field.currentEditor()!.insertText(...)`（或按那个清除按钮）
  才能把 `controlTextDidChange` 踩一遍。这次靠它验证了搜索框真的在筛列表（窗口标题从
  `– 1 session` 变成 `Search – 1 result`，再变回 `– 1 session`）。
- **语音不用嘴也能测：`say` 生成音频，同一个管线吃文件。** `say -v Tingting -o x.aiff "…"`，
  再按 100ms 一块、按实时速度喂给同一条 `AsyncStream<AnalyzerInput>` —— 就得到一个**零 token、
  零权限、可重复**的测试样本。这次靠它在没有人的情况下跑了几十轮：「partial 会不会 revise」
  「停顿能不能切句」「60 秒会不会被截断」全是这么测出来的。要造停顿就把两段 clip 中间拼接静音。
  代价是它绕过了麦克风，所以 TCC、设备格式转换、真实环境噪声还得另测。
- **实时通路的验证要断言「东西到了哪里」，不是只看事件。** 这次抓到的两个真问题都是这么暴露的：
  一个是**事件全对但字段里没有东西**（没有 final，句子永远停留在合成状态），一个是**开头的字
  被吃**（音频先于模型）。两次都是把真实 `NSTextView` 的 `string` 和 `hasMarkedText()` 打出来才看见的
  —— 只打事件日志，两次都会看起来正常。
- **`wei-cli` 是同一套 agent 的终端形态**：怀疑是 shell 侧还是宿主侧时，先在终端复现 —— 这次
  shell 侧一次就通过了，问题定位在宿主，省掉大量窗口里的瞎试。
- **`ps eww` 看不到运行期的 `setenv`。** 它打的是内核在 `exec` 时记下的那份环境副本，之后进程里
  改过的变量**看不见**。这一轮我差点据此把一次**已经成功**的修复判成失败：启动后 `ps eww <pid>`
  里 PATH 还是原来那四项，而进程内 `getenv` 已经不是了。要读活的 `environ` 就得**在那个进程里**读，
  或者让一个同父进程的子进程把它继承下去再看。这次的验法是一个二十行的探针：`wei_boot` +
  后台线程 `wei_run`，睡 3 秒后打印 `getenv("PATH")` —— 走的是和 app **完全同一条** `start()` 路径，
  所以它验的是真边界，不是一份复制的逻辑。
- **假模型比真 API 好用**：一个几十行的 python SSE server（`/tmp` 里现写）能构造工具调用、思考流、
  用量字段，而且是确定的。真 API 既慢又花钱，还不一定能复现你要的那次形状。注意它有个坑：请求体
  可能是 chunked 编码的（`curl` 那种），只按 `Content-Length` 读会拿到空 body —— 我第一次就是这么
  被骗了一轮，以为模型没被调用。**而且别用 `http.server` 当那个假模型**：它既不应 `Expect: 100-continue`
  （客户端在那里等 interim 响应，等到的是一次 `Connection reset by peer`，shell 报成「模型流断了」），
  也不方便自己分块（回了 `HTTP/1.1` 又没有 `Content-Length`/`Transfer-Encoding`，客户端有权当成响应结束）。
  两种症状**都长得像模型的错**。直接写一个 raw socket server、手写 `Transfer-Encoding: chunked`，
  大约多花二十行，省掉一下午：它连着把「请求体是什么 framing」也打出来了。验证实时渲染时再给它一个
  `--repeat N`，就能把答案放大到几十万千字节，把 O(n²) 和 O(n) 的差别变成几十倍的字节数。
- **屏幕录制 TCC 被拒时，老老实实说「没看到」，把那一项交回人。** 这一轮里 `CGWindowListCreateImage`
  在新 SDK 里已经标成 unavailable（要走 ScreenCaptureKit），而 ScreenCaptureKit 拿到的是
  `-3801 ... TCC`。能自动化的仍然要自动化（线上的字节数、`swift test`、`moon test`、假模型构造的那次
  形状），但「思考块是不是真的三行」「表格的竖线对不齐」这类**只能看**的结论，没看到就是没验证 ——
  而把「页面看起来对」写成已验证，是这份清单里最贵的一种谎。
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
- **演示一段对话不需要一行模型**：`cp` 一条真会话、换掉 assistant 的正文、`WEI_SESSION=` 指
  过去，窗口里就是那段对话。验证「答案里的图」这种纯渲染的事，这样一轮几秒钟，且不花 token。
- **量布局用 AX 的 frame，不靠截图估**：`/tmp/wei-shell-probe/axframe <pid>` 把整棵 AX 树连
  `y=.. x=..`（窗口相对坐标）打出来 —— 工具条是 `AXToolbar y=0..52`、按钮 `x=872..917`、
  标题 `y=14..38`，于是「标题和按钮在不在同一行」是一个数字问题。同一套工具里还有：
  `wininfo <pid>`（按 PID 列窗口号）、`axdump`（树，不带坐标）、`scroll <pid> x y ticks [delta]`
  （**先把 app 置前**再发合成滚轮事件，否则事件穿过一个不活跃的窗口）、`axrow <pid> 'Tools'`
  （设 `kAXSelectedAttribute` 切换设置面板左栏，行不支持 `AXPress`）、`axpress`（按主窗左下的
  `Settings` 按钮）、`leftedge <png> y0:y1:label...`（量某条横带里最靠左的深色像素，用来对左边缘）。
  它们都是十几行 Swift、`swiftc` 直接编，不用建工程。

## 七、运行环境（从 Finder 启动 ≠ 从终端启动）

app 被 Finder 启动时父进程是 `launchd`，而 `launchd` **不继承读者终端的环境**。这不是理论：
`macos/README.md` 早就为 `DEEPSEEK_API_KEY` 记过同一件事（所以 key 有设置面板兜着）。`PATH` 是
同一个根因的另一半，而且一直没兜 —— 于是它是一个「终端里好使、agent 里找不到」的 bug。

| 症状 | 原因 | 修法 |
|---|---|---|
| 终端里 `moon`（或 homebrew 装的任何东西）好使，agent 的 `bash` / `script` 说找不到 —— 同一台机器、同一个读者 | 从 Finder 启动的 app 继承的是 `launchd` 的环境，而 **`launchd` 根本不设 `PATH`**（实测 `launchctl getenv PATH` 为空）；`/bin/bash` 于是回退到编译期默认值（`getconf PATH` → `/usr/bin:/bin:/usr/sbin:/sbin`）。实测那个正在跑的 app：`PATH=/usr/bin:/bin:/usr/sbin:/sbin`、`SHELL=/bin/zsh`、`HOME=/Users/lucas`。`~/.moon/bin` 不在里面 —— 而工具描述向模型承诺的正是「和读者的终端一样」 | 启动时**问一次登录 shell**：`"$SHELL" -l -i -c` 打印一个 marker 加 `$PATH`，把结果并进本进程环境，之后 spawn 的一切都继承。代码在 `platform/environment.mbt`，调用于 `macos/appffi/app.mbt` 的 `start()`。**为什么要 marker**：rc 文件会在 stdout 上说话 —— 本机 `~/.zshrc` 第 2 行那个 source 写坏了（`source ~/.gitrcPATH="…"`，本该是两行），报错里就带着一段 `PATH=` 字样（它在 stderr 上，但换个 rc 文件就可能在 stdout）；「取最后一个 `PATH=`」会取到它，只认「最后一个带 marker 的行」就没有这个歧义。实测 28ms |

两个决定看起来可以更省事，但都别省：

- **是 merge，不是替换。** 登录 shell 知道读者的工具在哪，`launchd` 知道系统把什么放上了 PATH，
  两者**互不包含** —— 少了后面那份连 `/usr/bin` 都没了，agent 什么命令都跑不起来。
  顺序是登录 shell 在前：读者的 PATH 顺序是读者排的，任何后置条目盖掉前置条目都等于把那个安排作废。
- **特意没有顺手把 rc 文件里的其它变量也搬过来**（比如 `DEEPSEEK_API_KEY`）。那会把「跑一次读者的
  启动脚本」扩大成「到处翻环境里的秘密」，而 key 已经有一个正当入口（设置面板）。`PATH` 不一样：
  它本来就不是秘密，而缺了它模型拿到的是一句与自己承诺相反的报错。

探针有失败的可能（rc 文件把 shell 结束掉、超时、`SHELL` 指向一个已经卸掉的东西），所以有一条兜底
列表（`~/.moon/bin`、`~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin`）。兜底只**加**不删：
进程原有的条目一条都不能丢，那是有测试钉住的。另外 `fish` 不参与探测 —— 它的 `$PATH` 是列表、
用空格分隔，问它得到的是一个**错的**答案，比没有答案更糟。
