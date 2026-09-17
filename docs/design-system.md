# wei Agent 设计规范

**这份文档和代码是同一套数字。** token 在 `macos/PiShell/Sources/PiModel/Design.swift`（值，可测）和
`macos/PiShell/Sources/PiShell/Design.swift`（`Color` / `Font` / 图形 / 材质），`DesignTests` 把其中**能算**的
部分算出来 —— 对比度、比例顺序、栅格、logo 的对称与出檐。

为什么写成一套而不是继续手写：这份文档诞生前，窗口里有 **11 个字号**（5…22）和 **14 个间距值**。那不是尺度，
是一段历史 —— 每次改动都从「上次那个数看着还行」开始。

---

## 一、身份

| | |
|---|---|
| 名字 | **wei Agent** |
| 可执行文件 | `wei`（包内、`ps`、崩溃报告路径里用单字；文件名和 Finder 用全名） |
| bundle | `macos/dist/wei Agent.app` |
| bundle id | `io.github.lindividual.wei-agent` |
| 标志 | `wei-logo.svg` |
| 图标 | `macos/make-icon.swift` 画出来的，不是提交进来的 `.icns` |

**名字在三处必须一致**：Finder 显示的是 bundle 的**文件名**（只有 `CFBundleDisplayName` 会留下一个叫
`pi.app` 的文件配一个写着 "wei Agent" 的窗口）、Dock 和 app 切换器用显示名、`ps` 用可执行文件名。三处同源：
`make-app.sh` 里的 `NAME` 和 `EXECUTABLE`。

**应用内也出现名字**：最左栏左上角是标志 + 「wei Agent」（`Wei.MarkView` + `Font.control(.medium)`）。这不是
装饰 —— 窗口标题改成「项目 + 会话数」之后，app 自己的名字在界面里**没有别的地方**出现了（只剩关于框和 Dock）。

### 标志的形状原样抄，不做「几何化」

`Wei.Mark` 是 logo 的**路径命令**，不是一组参数：

```
      ▟▙   ▟▙        ← 两条笔画：胶囊 + 一条向左下扫出的尾巴（尾巴就是 w 的暗示）
   ▁▁▁▁▁▁▁▁▁▁        ← 容器：顶边是一条中间下凹的曲线，底边平、底角圆
```

上一版把标志压缩成「圆角方里两条胶囊」，丢掉了**下凹的顶边**和**尾巴** —— 而那两样就是标志本身。所以这里是
路径：`move` / `line` / `curve(两个控制点)` / `close`。

三点实现上的事实，都踩过：

- **曲线是三次贝塞尔，不是二次。** SVG 的 `C` 带两个控制点；映射到 `addQuadCurve` 会把尾巴悄悄磨圆。
- **坐标系翻转只做一次。** SVG 是 y 向下、CoreGraphics 是 y 向上。手算翻转试了两次都错（先圆角跑到上面、
  再整个倒过来），最后是 `translate` + `scale(1, -1)` 翻上下文，**下面每个数字都还是 SVG 的**。SwiftUI
  那边**不需要翻** —— `Path` 和 SVG 一样是 y 向下。
- **两处绘制，一份数据。** 图标（CoreGraphics）在 app 编译**之前**就画好了，import 不到 `Wei`，所以常量在
  那里抄了一份；`DesignTests` 断言形状的三条性质（两笔画**互为镜像**、顶边**下凹**、笔画**有尾巴**），抄错
  任何一条都会挂。

**图标**：薄荷色瓦片（容器色即瓦片色，最干净）+ 标志占瓦片宽 78%。**验证到了什么程度**：用 WebKit 把
`wei-logo.svg` 渲染成 800px，和自己的绘制逐像素量边界框 —— pine 色区域的宽高比 **1.97 vs 1.98**，形状一致
（不是看出来的，是量出来的）。

---

## 二、颜色：**一个**色相，两个明度

| token | 值 | 角色 |
|---|---|---|
| `Wei.Brand.mint` | `#78E5A4` | 标志的容器色。浅色外观的**填充**，深色外观的 accent |
| `Wei.Brand.pine` | `#30714A` | 标志两条笔画的颜色。浅色外观的 accent，深色外观的填充 |
| `Wei.Brand.forest` | `#0E2A1B` | 深色外观里画在 mint 填充上的字 |

**一个色相的品牌，把「两种外观都读得出来」全部压在明度上。** 紫+黄那一版靠**换色相**；这一版靠**换明度**：
pine 够暗（白底 5.86:1）所以浅色外观用它当 accent，mint 够亮（暗底 10.75:1）所以深色外观用它。规则一样，轴
不一样。

代价明确，也写下来了：**mint 在白底上只有 1.55:1，所以它在浅色外观里只能是填充。** 这不是选色的缺陷，是
选色蕴含的约束 —— 有测试钉着（`testOneHueCoversBothAppearancesByLightness`，四条断言**包括两条「应该失败」
的**）：谁把 mint 拿去当浅色模式的 accent，失败的断言会解释为什么不行。

| 语义 token | 浅色 | 深色 | 用在 |
|---|---|---|---|
| `Palette.accent` | pine | mint | 交互：链接、焦点环、默认按钮、工作区绿点、工具的完成勾 |
| `Palette.onAccent` | 白 | forest | 画在 accent 填充上的字（**发送按钮**） |
| `Palette.highlight` | mint | mint | 品牌色当**背景**时（标志的容器） |
| `Palette.onHighlight` | pine | mint | 画在 highlight 上的字（**Running 胶囊**） |
| `Palette.highlightWash` | mint 15% over 白 | mint 22% over `#1E1E1E` | 胶囊的底、用户气泡的底 |

**应用方式**：`.tint(Wei.Palette.accent)` 加在窗口根上，这是平台自己的机制。

**「用一点 logo 的颜色」落在四处**，都走 token：工作区那个「当前会话在这里」的绿点（原来是硬编码
`.green`）、用户气泡的底、Running 胶囊、工具完成的勾（原来也是硬编码 `.green`）。**错误仍然用系统的红** ——
那是平台传达「出错了」的方式，品牌色不该覆盖它。

### 对比度（`DesignTests` 实测）

| 前景 / 背景 | 比值 | |
|---|---|---|
| pine 字 / 白 | **5.86:1** | AA ✓ |
| 白字 / pine 填充（发送按钮） | **5.86:1** | AA ✓ |
| mint 字 / `#1E1E1E` | **10.75:1** | AA ✓ |
| forest 字 / mint 填充 | **9.92:1** | AA ✓ |
| pine 字 / 胶囊底（浅） | **5.47:1** | AA ✓ |
| mint 字 / 胶囊底（深） | **6.23:1** | AA ✓ |
| mint 字 / 白 | **1.55:1** | ✗ ← 所以它在浅色外观里只做填充 |
| pine 字 / `#1E1E1E` | **2.16:1** | ✗ ← 所以它在深色外观里只做填充 |
| mint / pine（标志的两色） | **3.48:1** | 形状可辨 ✓ |

### 中性色：一律**借**

灰阶全部用 macOS 语义色（`.labelColor` / `.secondaryLabelColor` / `.tertiaryLabelColor` / `.separatorColor` /
`.windowBackgroundColor` / `.controlBackgroundColor`），一个都不硬编码。理由不是省事：只有它们**回答**深色模式、
增强对比度、非活动窗口变暗。硬编码的 `Color.gray.opacity(0.2)` 在四个场景里错四个。

动态色用 `NSColor(name:dynamicProvider:)` —— 平台自己的机制，顺带白拿 increase contrast / reduce transparency 变体。

---

## 三、字体

五级。**比平台大一号，这是故意的。**

| token | 字号 | 职务 |
|---|---|---|
| `Size.title` | **20** | 列表栏标题、对话栏标题 |
| `Size.body` | **15** | 内容：转录、通知、要读的段落 |
| `Size.control` | **13** | 控件和列表行。**= `NSFont.systemFontSize`** |
| `Size.caption` | **12** | 计数、时间、状态行、胶囊（含列表栏那个条数）。可读的下限 |
| `Size.micro` | **11** | 紧贴图标的数字，不用于正文 |

**三栏的层级**（「三栏字号看起来一样」就是这一条改的）：栏标题 20 / 会话行标题 15 / 行内时间与状态 12 /
控件 13。

**三个标题现在都是我们自己画的，都取 `title`(20)。** 这不总是如此：中间栏那一个原来是平台画的
（`navigationTitle`），而**平台的标题字号没有 API 可设** —— `NSWindow` 只有 `title`/`subtitle` 两个字符串，
AppKit 里没有任何 title font / attributed title，SwiftUI 的 `toolbarTitleDisplayMode` 文档原话是
"This modifier has no effect on macOS"。量过：平台画的是 **13 semibold**（标题）和 **11**（计数），
规范要 20。所以现在的做法是 `toolbar(removing: .title)` 把平台那枚去掉、自己画 —— 顺带把这一栏的
「新建会话」按钮也放进了同一个 item（见 `macos/README.md`）。窗口仍然有名字（`navigationTitle` 还在），
Window 菜单和辅助功能读到的照旧。

| 标题 | 谁画 | 字号 | 符合规范？ |
|---|---|---|---|
| 中间栏（列表栏）标题 | 我们 | `title` **20** semibold（实测宽 118.5pt，与标尺 20pt 的 118.5 完全一致） | ✅ |
| 中间栏副标题（计数） | 我们 | `caption` **12**（它是「计数」，caption 的职务之一） | ✅ |
| 对话栏标题 | 我们 | `title` **20** semibold | ✅ |

会话行的**标题**取 `body`(15) 而不是 `control`(13) —— 行是读者**挑**的内容，不是他们**操作**的控件，
而且一个两行的行如果第一行和第二行一样大，就没有第一行。

**为什么 `body` 不是 13**：`NSFont.systemFontSize`（13）是**控件**的尺寸，而这个窗口是**读物** —— 转录是
读几分钟的散文，13 是控件的字号不是阅读的字号。所以「对齐平台」的锚点是 **`control` = 13**，`body` 比它
大一号。规则不是「抄平台」，是「知道自己画的是两件事里的哪一件」。有测试钉住这个锚点。

SwiftUI：`Wei.Font.title()` / `.body()` / `.control()` / `.caption()` / `.micro()` / `.code(size:)`。
等宽默认取 `control`；转录里的代码取 `body` —— 和周围正文字号一致，所以代码段和散文段在页面上重量相同。

---

## 四、间距：4pt 节奏，2pt 微调

| token | 值 | 用在 |
|---|---|---|
| `Space.tiny` | 2 | 同一行的两行文字之间（**唯一允许的奇数步**） |
| `Space.tight` | 4 | 控件内部：图标到文字、圆点到它的字 |
| `Space.cozy` | 8 | 卡片里堆叠项之间、胶囊内部 |
| `Space.regular` | 12 | 默认间隙、密集面的内缩 |
| `Space.loose` | 16 | 组之间、栏的内缩 |
| `Space.section` | 24 | 区块之间、面板内边距 |
| `Space.page` | 32 | 对话框、空状态四周 |

**「整体偏紧凑」就是这一条改的**：`regular` 从 8 到 12、`loose` 从 12 到 16、`section` 从 16 到 24、行高从
30 到 40、正文字号从 13 到 15。判断标准写在测试里（`testTheLayoutIsLoose`）：行高至少容得下两行正文，
控件高度至少比它的字大 16。

---

## 五、圆角与控件尺寸

| token | 值 | 用在 |
|---|---|---|
| `Radius.chip` | 8 | 胶囊、徽标、小的行内面 |
| `Radius.control` | 10 | 输入框、按钮（≈ 高度的 1/3，Apple 按钮的比例） |
| `Radius.panel` | 12 | 通知、内容里的分组块 |
| `Radius.row` | 14 | 行的选中高亮 |
| `Radius.surface` | 28 | 浮起来的输入卡片 |

| token | 值 | 用在 |
|---|---|---|
| `Control.regular` | 32 | 工具栏高度的控件（搜索框） |
| `Control.small` | 24 | 行内小控件 |
| `Control.row` | 40 | 两行文字的列表行 |
| `Control.hairline` | 0.5 | 分隔线、浮层描边 |

**间距在栅格上，圆角不在** —— 这个区别是有意的。间距是两个东西之间的距离，必须和别的间距同度量，否则一列
控件会一进一出；圆角是**一个角**的形状，是绝对量：32pt 的控件上给 12 会明显过圆，那里正确的值是 10，而它
不在 4 栅格上。**把圆角也塞进栅格是那种「让角落变错」的整齐规则** —— 这条规则我最初写在测试里，是测试失败
把它纠正过来的，注释留在那里。

---

## 六、浮层材质

**一个实现**：`weiSurface(in:)`。

- **macOS 26+**：`glassEffect(.regular, in: shape)` —— 系统材质，采样背后内容，自带发丝边和平台对「浮起来该
  多高」的意见。
- **macOS 14–15**：`.regularMaterial` + 0.5pt 发丝边 + 极淡阴影。

**26 上所有自己画的都刻意去掉**：玻璃上再叠自己的描边是第二道边，再叠自己的阴影是第二次抬升 —— 那正是
「像在模仿平台」。形状泛型，因为浮起来的不都是圆角矩形：搜索框是胶囊，它和输入卡片**同一种材质**。

---

## 七、组件

### 最左栏

```
🟡🟣  wei Agent        ← 标志 + app 名字（12pt 中灰）
──────────────        ← 发丝线
📁 pi-web-shell  ● 7   ← 文件夹图标 + 名字 + 会话数 + 绿点
📁 Madolumo        1
```

### 中栏

```
pi-web-shell        7 sessions  [＋]   ← 栏标题：项目名 + 计数（caption），按钮在最右
搜索栏：Capsule，Control.regular（32），浮在列表上方
Today                          ← 分组标题（caption 12 + secondary，缩进 loose）
macos 版还缺少…停止会话；切换会话。请实现
20:01  ● Running                ← 第二行：时间 + 胶囊（Control.row = 40 的行高）
```

- **标题栏归中栏**：三栏 `NavigationSplitView` 里 content 栏赢得标题，detail 栏的 `navigationTitle` 被忽略。
- **窗口标题栏回到「会话名」**（当初为了修「标题栏永远显示 pi」而让中栏接管过它，那是个临时判断）。
  工作区的**名字和计数移到栏内** —— 标题给窗口正在展示的东西，列表的标题给列表。
- **新建会话按钮在这一栏标题的最右端**，而且**直接建，不弹选择**：加会话就是加到**这个工作区**。需要选目录的
  那个变体仍在 File 菜单（"New Session in Folder…"）。第一次点击还要回答一个问题，就是一次点击做了两件事。
- **它不再要求先停掉正在跑的会话。** 那条拒绝是注册表之前的遗留（那时新建会**替换**唯一那个会话），现在新会话是
  在运行中的会话旁边加一个，turn 继续写自己的文件。
- **搜索框的形状是明知故犯的偏离**：macOS 的标准搜索控件是 `NSSearchField`（`.searchable`）—— 圆角**矩形**、
  位置由修饰符决定。三栏里「这一栏」不在它支持的 placement 里，落到工具栏又像在搜对话。取标准控件的**行为**
  （前置放大镜、内联清除、Return 提交）+ 工具栏按钮的**形状和高度**。**胶囊在 macOS 上不是搜索框的标准形状**，
  那是 macOS 26 工具栏按钮的形状。
- **会话行两行**（`Control.row`）：一行放不下「多久以前」和「还在跑吗」，而这两件正是让列表可扫的东西。高度固定，
  带胶囊的行和不带的一样高。

### 状态胶囊 `StatusChip`

`Font.caption` + `Space.tight`/`Space.tiny` + `Radius.chip` 的胶囊 + `highlightWash` 底 + `onHighlight` 字 +
一个 `Icon.mark` 的圆点。**它是两色系统在一个控件里的全部**：底取「在这个外观里当背景能读」的那个色相，字取
「在这个外观里能读」的那个。

**只画线上真有的状态**：每行传来的字段只有 `running`。

### 对话栏

```
会话名的标题（Font.title 20）+ 模型 · 目录（Font.caption 12，secondary）+ 发丝线
转录
```

- **对话栏有它自己的标题**，因为三栏 split 里窗口标题归中栏。这里画的是 web UI 钉在转录上方的东西：会话名，
  以及下面两件读者会在中途核对的事实 —— 哪个模型、工具在哪跑。这两件原来在窗口副标题里，三栏之后没有副标题了。
- **打开会话落在末尾。** 会话是从结尾读的；不加这条，切换过来的第一帧是九十轮日志的**顶部**，那是没人想从那里
  开始的地方。和「跟随」是**两条规则**：跟随是「跟上还在变长的转录」，必须尊重一个滚上去读东西的读者；这条是
  「我刚被交到另一段对话手里」，无条件落底。web UI 是同样的判断。
- **折叠长内容**：工具输出默认只显示两行（`lineLimit(2)`），点「Show all」展开；思考块在**停止流式之后**折成一行
  「Reasoning」，到达期间保持展开（要展开才能看它在想的折叠，会每轮被开合一次）。一个打印 400 行的工具是常态
  不是例外，永远摊开的日志会把读者要看的下一件东西顶出屏幕。

### 空状态

列表为空时说**为什么**（「这个项目里没有会话」/「没有匹配的结果」/「没有选中项目」），居中、`Font.control` +
`secondary`。没有消息的空列表和「还没加载完」在屏幕上一模一样。

---

## 八、没抄备忘录的什么

| 备忘录有 | 我们没有 | 为什么 |
|---|---|---|
| 格式工具栏 | — | 我们发纯文本 + 附件，markdown 由模型生成，没有「格式」这个动作 |
| 附件浏览器 | — | 附件属于消息，不是独立对象 |
| 「无更多文本」摘要行 | — | 会话的第一句提问就是它自己的摘要 |
| 时间为纲组织笔记 | 项目**再**时间 | 笔记没有「工作目录」这个轴；会话有，而且工具在哪跑是一等事实 |
| 正文列搜索 | 搜**会话名和目录** | 搜正文要读每个文件 —— 那是这个 shell 处处在避免的成本 |

---

## 九、怎么用，怎么验

```swift
// 颜色
.foregroundStyle(Wei.Palette.secondary)
.background(Wei.Palette.highlightWash, in: Capsule())
.tint(Wei.Palette.accent)                    // 一次，加在窗口根上

// 字体
.font(Wei.Font.control(.medium))
.font(Wei.Font.code(Wei.Size.body))

// 间距与圆角
.padding(.horizontal, Wei.Space.loose)
RoundedRectangle(cornerRadius: Wei.Radius.control, style: .continuous)

// 浮层与标志
.weiSurface(in: Capsule())
Wei.MarkView(height: 18)
```

**规则**：这个文件里**不出现裸数字**。字号、间距、半径、颜色都走 token；真要新的一档，那是**改规范** ——
改在 `Design.swift` 并让 `DesignTests` 重新算对比度，不是在调用点写一个 7。

```bash
cd macos/PiShell && swift test --filter DesignTests   # 对比度、比例顺序、栅格、标志几何
```

**这套规范没做到的**（老实说）：

1. **深色模式没有真机对照**。两个色相的对比度是**算**出来的，深色下的实际观感没有验证过。
2. **`List` 的选中高亮颜色未验证**：`.tint` 会作用于控件、焦点环、默认按钮，但 `List(selection:)` 的选中底色
   在离屏渲染里仍然是系统蓝。是「平台不理会 tint」还是「渲染器不呈现 tint」，**没分清** —— 需要真机截图。
3. **动效没有规范**（时长、曲线）：现在只有一处 `.animation(.default, value:)`。
4. **栏宽断点没有规范**：三栏的 min/ideal/max 各自为政，没有一条「窗口窄于 X 收起第一栏」的规则。
5. **没有「密度」这一维**：行高、内缩、字号绑在一起的整体档位（紧凑/宽松）还不存在，现在只有一套。
