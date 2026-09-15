# ADR-0008：界面继续用 SwiftUI，不引入 AppKit 视图/子项目；子代理也走 SwiftUI

- **状态**：已采纳
- **日期**：2026-09-15
- **相关**：`docs/design-system.md`、`macos/README.md`、`docs/macos-pitfalls.md`、
  `docs/adr/0001-no-vdom-framework.md`（同一类判断，在 Web 那一侧）

## 背景

`macos/PiShell/` 全部是 SwiftUI（三个 target：`PiModel` 纯模型、`PiKit` 客户端、`PiShell` 视图）。
AppKit 出现的地方都是**平台 API 是 AppKit 的**，不是视图：

| AppKit 用法 | 为什么不是「用 AppKit 做界面」 |
|---|---|
| `NSApplicationDelegateAdaptor`（`PiShellApp`） | 菜单栏、激活策略：SwiftUI 的 App 协议没有这两件 |
| `NSEvent.addLocalMonitorForEvents`（滚动跟随） | SwiftUI 14 没有「读者滚动了」的回调；测量分不出「读者在动」和「内容在长」 |
| `NSPasteboard` / `NSImage`（粘贴图片） | 剪贴板与位图是 AppKit 的 |
| `NSAttributedString` + `NSFont`（表格宽度） | 写代码之前要量文本，量文本是 TextKit 的 |
| `NSTextView.hasMarkedText()`（输入法） | 输入法的合成状态只有 field editor 知道 |
| `NSColor(name:dynamicProvider:)`（设计系统） | 随外观变化的颜色，这是平台自己的机制 |
| `FileHandle.standardError`（调试） | 不是视图 |

也就是说：**没有一处是「用 AppKit 画了一个 SwiftUI 能画的东西」**。

## 决策

**1. 界面继续用 SwiftUI。** 不引入 AppKit 视图、不引入 Xcode 工程、不引入 SwiftUI 子项目/包。

**2. 判断某件事该不该引入 AppKit 的判据**，按顺序问：

1. **平台 API 是不是 AppKit 的？**（剪贴板、位图、输入法状态、事件监视器、菜单栏）→ 是就用，写清理由。
2. **`swiftinterface` 里有没有 SwiftUI 的等价物？** → 去
   `…/SwiftUI.framework/…/arm64e-apple-macos.swiftinterface` 里找（`macos-pitfalls.md` 里有这条）。
3. **都没有**，而且这件事是**这个窗口的**（焦点、拖拽、滚动手势）→ 才考虑 AppKit 视图，并且要在这里记一笔。

**3. 子代理（subagent）也走 SwiftUI，不另开 AppKit 窗口。** 具体：

- 子代理的**转录**是 `PiModel` 的数据（`Turn` 列表），视图是 `TurnView` 的复用 —— 不是第二个渲染器。
- 子代理的**面板**是主窗口里的一个 `NavigationSplitView` 第四栏或一个 sheet/popover，用 `Wei` 的 token。
- **不**用 `NSPanel`、**不**用 AppKit 的 outline view、**不**开第二个 `NSWindow`（除非将来要真多窗口，
  那是另一个决定，因为 MoonBit 侧是单运行时单会话注册表）。

**理由**（三条，按重要性）：

1. **设计系统只有一套消费方。** `Wei` 是 `Color` / `Font` / `Shape` / `ViewModifier`。子代理的界面如果
   用 AppKit 画，就得有第二套 token（`NSColor`/`NSFont`），两套必然漂 —— 而漂的是颜色和层级，也就是
   用户看得见的那部分。
2. **数据在 `PiModel`，不在视图里。** 子代理的转录解析、折叠规则、用量格式化全是纯函数，已经有测试。
   换渲染技术不会让它们变快或变对，只会让**同一份数据有两个渲染器**。
3. **代价已经被量过了。** 这一版最贵的三个坑（表格列宽不齐、卡片渐变丢失、`List` 选中色不受 `.tint`
   控制）**全都出在 SwiftUI 上**，而不是「SwiftUI 做不到」——每一个都修好了，方法记在
   `docs/macos-pitfalls.md`。换 AppKit 是一张没写过的赌注，而收益是「可能少几个坑」。

## 什么情况下这个决定会被推翻

写下来，免得它变成教条：**当某件必须做的事在 SwiftUI 里做不到或慢到不能用**，而且
（a）`swiftinterface` 里没有等价物，（b）不是配置问题。那时的做法是**局部**用 `NSViewRepresentable`
包一个 AppKit 视图，并在这个 ADR 里追加一条 —— 不是整体转向。
