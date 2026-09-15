# 原生 macOS 壳（MVP）

一个原生窗口，驱动同一套 agent。它存在的原因是路线 B 的那句话要落到地上：**界面重写，内核复用**。

```
macos/appffi/       MoonBit：agent + 会话 + 事件出口（这一层是新的）
macos/build-moonbit.sh  把上面那个包编译成 host 能链接的 libpiweb.a
macos/PiShell/      Swift：窗口、对话、边界
```

```bash
macos/build-moonbit.sh              # → macos/vendor/libpiweb.a
cd macos/PiShell
swift run PiShell                   # 窗口
swift run pi-shell-cli              # 同一套东西，终端上，打的是线上字节
swift test                          # 消费侧
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
（transcript 深度、live patch id、订阅者）。

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

- **只有一个会话。** 没有侧边栏，不能新建/切换/删除。会话从 `PI_SHELL_SESSION` 或当前目录最近
  的 store 里来。
- **没有设置面板。** key 只从 `DEEPSEEK_API_KEY` 和环境里读；没有 key 时窗口照常开着，状态行
  写 `no API key`。
- **模型只能从命令行换**（往里发 `/model`），没有下拉框。
- **markdown 是宿主渲染的**，而 Web 版是 cmark 渲染成 HTML 的 —— 两者对同一段 markdown 会有
  细微差别（表格、脚注、raw HTML 的处理）。真要说谁对，得挑一个共享的实现，那是后面的事。
- 附件、图片、用量/上下文面板、后台任务面板、skill、压缩提示、workspace 选择器、
  「load earlier」窗口 —— 都不在。
- 设置面板能改的东西，这里一个都改不了。

## 已知的坑

- `swift build` 会刷一屏 `was built for newer 'macOS' version` 的警告：MoonBit 用本机 SDK
  编译 `libpiweb.a`，而 Swift 包声明的最低版本更低。是警告，不是错误。
- 归档要手动重建：改了 `macos/appffi/` 得再跑一次 `build-moonbit.sh`，SwiftPM 不知道它。
- `swift run PiShell` 是裸可执行文件，不是 .app。`AppDelegate` 里那句
  `setActivationPolicy(.regular)` 就是为它写的 —— 否则有窗口、没菜单栏、不聚焦，看起来像卡死。
  真正打包时它是个 no-op。

## 下一步

按「先便宜后贵」排：

1. **会话列表**：`platform.list_sessions` 已经在了，缺的是一条 `sessions` 事件和一个侧边栏。
2. **设置面板**：key 最先 —— 现在没 key 就是一堵墙；`platform.load_settings` 也在了。
3. **滚动跟随的细节**：现在每次都跳到最新一行。Web 版只在读者已经在底部时才跟，翻上去看旧内容
   不会被拽回来。
4. **模型下拉框**，然后是附件、用量面板。
5. **打包成 .app**：bundle、图标、签名。
