# pi-web-shell

[pi](https://github.com/earendil-works/pi-mono) 的独立复刻：一个 MoonBit 实现的
agent 内核，加一个服务器渲染的 Web UI，交付形态是单个 native 二进制。

```
core/      纯逻辑：消息模型、DeepSeek 编解码、agent 状态机、会话树、工具、压缩
platform/  native 实现：HTTP/SSE、文件系统、进程
agent/     驱动：把状态机接到模型与工具
html/      HTML DSL、转义、渲染、Patch
server/    HTTP 路由 + SSE 广播
ui/        可执行：agent + server + Web UI 合一（交付形态）
pi/        可执行：命令行跑一次完整 turn
cli/       可执行：打一次真实 API，最小链路验证
verify/    可执行：拿真实会话全量跑往返验证
harness/   Node 脚本：用 pi 当 oracle 生成 fixture
```

**一条硬约束**：`core/` 不许碰 IO，必须能编译到**每一个**后端。
`.githooks/pre-commit` 会跑 `moon check -p core --target js` 和 `--target wasm-gc`；
这两条失败就说明有平台代码渗进了核心逻辑。约束靠编译器执行，不靠自觉。

## 运行

```bash
moon run ui                          # → http://127.0.0.1:8790
moon run ui -- --continue            # 继续本目录最近写入的会话
moon run ui -- --resume <id|path>    # 打开指定会话
moon run ui -- --port 9000 --model deepseek-v4-flash --store ~/.pi-mb/sessions
moon run pi -- "prompt"              # 命令行跑一次完整 turn
moon run verify                      # 全量会话往返验证
```

API key 取自 `DEEPSEEK_API_KEY`，没有就用 pi 的凭据库（`~/.pi/agent/auth.json`）。

## Web UI：服务器渲染，不是单页应用

服务器是文档唯一的写者。浏览器端只有 **50 行 JS**，它知道三件事：怎么应用一个
patch、怎么发一条 prompt、`data-session` 被点击时打开那个会话。对话长什么样完全
由服务器决定，所以客户端和服务器之间没有「状态不一致」这种失败模式。

```
GET  /         整页（含已有对话与侧边栏）
GET  /events   SSE，推 HTML 片段
POST /prompt   用户输入，立即返回
POST /session  切换会话（空体=新建），立即返回
POST /abort    停掉正在跑的 turn
```

**首帧是「可变区域的快照」。** 每个连接先收到 `transcript` / `sessions` / 状态行三个
区域的 patch，而不是整页。这条曾经写错过 —— 首帧发整页、客户端又用 `outerHTML` 直接
替换 `#transcript`，结果是浏览器把整个文档的片段塞进 body：输入框和状态行都被换成新
节点，而 JS 里捕获的还是旧节点，于是**页面看起来正常、输入框和状态行却永久失效**，
而所有字节层面的断言全部通过。

这个 bug 决定了验证方式：`server/http_test.mbt` 断言首帧里不能出现 `<html`，
`harness/ui-browser-check.mjs` 则用**真实的 headless Chrome**（不是用户的浏览器）
再确认一遍 DOM 真的没被嵌套、输入框的监听真的挂在屏上的那个节点上。后者是唯一能看见
这类问题的地方。

**流式期间不渲染 markdown。** 每个 delta 只更新累积文本（`SetText`），turn 结束时
一次性替换成渲染好的 markdown。半截的 `**bo` 渲染出来是错的，而且每来一个 delta
重渲染一遍累积文本是 O(n²)。

**折叠交给原生 `<details>`。** 客户端版为此维护了一个展开状态数组并写进 Model；
服务器渲染后这一项直接删掉，浏览器自己就记得。

**状态行说清一轮发生了什么**：模型调用数、工具调用数、token 进出、花费。花费保留
6 位小数，因为一轮对话的成本是「零点几毫厘美元」，四舍五入到分就永远是 $0.00。

**转义是唯一真正的风险**，因为输入是模型输出和文件内容：`Text` 节点永远转义，
`Raw` 是唯一逃生口且只用于 markdown 渲染器的输出。`html/escape_test.mbt` 有四个
专门的注入测试（script 标签、事件处理器属性、属性逃逸、提前闭合标签）。

## 一次只跑一个 turn

每个会改变会话的请求（prompt、会话切换）都变成队列上的一个 job，由一个 worker 顺序
执行。这就是全部的并发设计，而且它是承重的。

这不是推演出来的结论，是压测出来的。同时 POST 两个 prompt，日志变成这样：

```
entries 22, orphan parents [('e502f650','9b8d05ce')]     ← 有一条 entry 被写掉了
两条交错分支: 31e253f6→4a1d4897→… 和 571903ea→21616903→…
```

两个原因，都得修：

1. **没有串行化**：两个 turn 同时跑，共用同一个 `session`，各自从自己那份快照往后接。
2. **`append_entry` 是「读-改-写整个文件」**：两个写者必然丢更新 —— 这就是
   `9b8d05ce` 消失的原因。它还是 O(n²)：一条会话有 1000 个 entry 时，每次 append
   都重写整个文件。

现在 append 走真正的 `O_APPEND` 写入（一行一次 `write`，读者要么看到整行要么看不到），
而顺序由队列保证 —— 不是由 HTTP 层保证。所以一个 turn 跑到一半时切会话，切换会排队
等它跑完，而不是把会话从底下抽走。

## 会话与恢复

会话格式与 pi 一致，而且是**可验证的一致**：`moon run verify` 把本机 160 个真实会话、
46,399 条 entry 全部解出来、再编回去，逐字节比对，当前 **0 失败**。

恢复有三条路径，都走同一个打开函数：

```bash
moon run ui -- --continue        # 本目录最近写入的会话
moon run ui -- --resume <id>     # 按 id 前缀或路径
# 或者直接在侧边栏点一个
```

打开时会先跑一次**崩溃修复**：进程在工具结果落盘前死掉会留下无应答的 `toolCall`，
provider 会拒绝这样的记录。修复时合成的错误文本明确告诉模型「不要盲目重试可能有
副作用的操作」，而且它是**追加到日志里**的 —— 只存在于内存里的修复不算修复。

侧边栏列出的是**当前工作目录**的会话，按最后写入时间排序：文件名里的时间戳是会话的
*开始*时间，今天恢复的会话会被后来居上的一次性会话压到后面。标签取第一条用户消息，
只读每个文件开头 64KB —— 为了画一个列表把每个会话整份读一遍，等于让「打开 UI」的
代价和「回放所有会话」一样大。

存储放在 `~/.pi-mb/sessions/`，**不是** pi 的 `~/.pi/agent/sessions/`。格式兼容是
刻意的（能读、能对拍），共用一份日志不是：两个进程同时 append 一份文件，就又回到上面
那个丢更新的问题了。

## 压缩

顺序是固定的：**先瘦身，再压缩**。

| | 瘦身（`core/trim.mbt`） | 压缩（`core/compaction.mbt`） |
|---|---|---|
| 做什么 | 裁掉旧工具输出的中段、清空旧思考 | 把旧历史交给模型总结 |
| 代价 | 免费 | 一次 API 调用 |
| 可逆 | **是**（原始内容还在，重读即可） | 否（信息已被摘要取代） |
| 何时用 | 每次请求前 | 瘦身后仍超过阈值时 |

因为瘦身免费且可逆，它先跑；如果瘦身后已在阈值以下，压缩就不必发生。

阈值由模型窗口推导（`CompactionSettings::for_window`）。`deepseek-v4-flash` 的窗口是
1M token，阈值因此是 98 万 token —— 日常几乎不会触发，但换个窗口小的模型就会。
所以这条链路是用 40k 窗口在测试里验证的，而不是靠等到线上触发。

压缩写成一个 `compaction` entry，带 `first_kept_entry_id`：它之前的历史被摘要取代，
之后原样保留。**被替换的内容仍然在文件里** —— 压缩不是删除，只是让后续请求不再携带。

**摘要回放必须带 `<summary>` 包装。** 这个字符串是 pi 的 `convertToLlm` 产生的，而且
有一个不显眼的前提：**pi-ai 根本不认识 `compactionSummary` 这种消息，喂给它会被静默
丢掉**（实测：喂进去，请求体里那条消息直接消失，不报错）。所以这个转换必须发生在请求
构造之前 —— 我们放在 `ContextMessage::to_message`。包装字符串本身由
`harness/gen-llm-message-fixtures.mjs` 从 `convertToLlm` 捕获，不是手写的：这正是那种
会被人「顺手改整齐」的字符串。

## 验证

```bash
moon test                    # 全包
moon test -p core            # 176 个测试
moon test -p platform        # 21 个测试，工具与存储在真实文件系统上
moon test -p html            # 26 个测试，含 4 个 HTML 注入测试
moon test -p server          # 8 个测试，起真 socket 验传输
moon test -p agent           # 4 个测试，假模型端到端跑 turn
moon run verify              # 全量：160 个文件、46,399 条 entry 往返
moon run cli -- "hello"      # 打一次真实 DeepSeek，端到端
node harness/ui-browser-check.mjs   # 真实浏览器验收（自己起 headless Chrome）
```

浏览器验收要先把 ui 构建出来（`moon build --target native`），它会自己挑空闲端口、
起服务器、跑完再收摊。它检查的东西：区域节点各只有一个、文档没有被嵌套、表单提交真的
到达服务器、流式容器在最终替换后消失、状态行报出花费、侧边栏新建与会话切换、**服务器
重启后页面自愈**（EventSource 重连 + 首帧快照）、以及全程没有任何未捕获异常。

### 对拍是主要手段

pi 是 oracle。所有期望值都是从它那里跑出来的，不是手写的常量：

| fixture | 捕获方式 | 保护什么 |
|---|---|---|
| `core/deepseek_fixtures.mbt` | 把 SSE 喂给 pi-ai 的解析器，取它产出的消息 | 流式解析的每条规则 |
| `core/deepseek_request_fixtures.mbt` | `stream` 支持注入 `fetch`，直接抓 pi 实际发出的请求体 | `buildParams` + `convertMessages` |
| `core/tool_fixtures.mbt` | 从 pi 的工具注册表导出 | 工具描述与 schema 逐字一致 |
| `core/llm_message_fixtures.mbt` | 调 pi 的 `convertToLlm` | 摘要与扩展消息怎么变成模型消息 |

对拍已经抓到七个靠读源码不易发现的规则：`responseModel` 只在模型名与请求不同时记录、
`thinkingSignature` 是实际命中的字段名而非固定值、有工具历史但没传工具时要发
`tools: []`、工具定义必须带 `strict: false`、图片在不支持视觉的模型上要降级为占位
文本、工具声明的描述与参数形状必须与 pi 逐字一致、以及 compression 摘要的 `<summary>`
包装。

还有一个只有全量数据才能看出的坑：`usage.reasoning` 是 pi 版本演进中新增的字段
（6-7 月的会话没有，8 月之后才有）。所以读取旧 session 时必须保留可选性，而解析 SSE
时又必须总是产出它 —— 这是两条不同的代码路径，混用会一边损坏旧数据、一边与当前 pi
不一致。

### 端到端

```bash
moon run pi -- "Run 'ls' and tell me how many files are in this directory."
# prompt   Run 'ls' and tell me how many files are in this directory.
# model calls 2, tool calls 1, 1922ms
```

`moon run pi` 跑的是完整链路：派生上下文 → 调模型 → 执行工具 → 写回 session，循环直到
模型不再请求工具。写出的 session 文件能被 pi 自己读回来，这是最硬的兼容性证据。

### 端口冲突

第二个实例会拿到 `cannot listen on 127.0.0.1:8790 … pass --port` 并以 1 退出，而不是
留下一个不服务任何东西的僵尸进程。这条也值得说一句：原来的实现在这里会把启动日志和
运行时的错误输出写乱（同一时刻两个写者往同一个流里写，连 `cwd` 前缀都被吃掉），
所以现在错误只由运行时输出一行。

## 已知限制

- **工具执行没有审批**：`bash`、`write`、`edit` 直接执行。pi 有审批流程，这里没有。
  自己机器上的本地工具，但值得知道。
- **一个进程一个 cwd**：侧边栏只列当前目录的会话，没有多工作区。
- **没有图片**：`Image` 内容会被降级成占位文本（与 pi 在不支持视觉的模型上一致）。
- **不做流式渲染 thinking**：思考默认折叠，实时推它等于把读者不该读的文本打到屏幕上。
- 单会话广播：所有标签页看同一个会话（这是设计，不是缺陷 —— 切换是全局的）。

## 曾经存在过的路线一

最初有第二条路线：复用 pi 内核，只重写界面（pi 扩展 + rabbita 前端）。它跑得起来，
但和路线二并列意味着两边都停在半成品状态，所以删掉了（见 `baa4416`）。被验证过、
值得留下的两条结论：

1. **rabbita 的 HTML DSL 在包外不可用**：`server_side_render` 在 `internal/` 包里，
   `Html::to_virtual_dom()` 的返回类型也来自那里，编译器强制 internal 可见性。
   唯一出口是整页 `App::render`，那正是「流式输出」不需要的形状。
2. **SSE 逐块到达是可依赖的**：预期间隔 120ms，实测 120/121/121/121/121ms。
