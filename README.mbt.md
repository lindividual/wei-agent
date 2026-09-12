# pi-web-shell

A browser UI for [pi](https://github.com/earendil-works/pi-mono), built as a
pi extension plus a MoonBit frontend. The pi process serves the page itself —
there is no separate backend and no RPC subprocess.

```
pi 进程
 └─ .pi/extensions/pi-web-shell/index.ts
     ├─ HTTP  : 静态资源 (dist/)
     └─ WS /pi: pi 事件 → 浏览器，浏览器输入 → pi.sendUserMessage()
浏览器
 └─ dist/web.js  (MoonBit + rabbita, TEA 架构)
```

## 运行

```bash
./build.sh                 # 构建前端到 dist/
pi --approve               # 在项目目录启动 pi，扩展自动加载
# → http://127.0.0.1:7801
```

TUI 与网页共享同一个会话：两边看到的是同一个 agent 和同一份上下文。

## 结构

| 路径 | 说明 |
|---|---|
| `web/main.mbt` | 前端：`Msg` / `Model` / `update` / `view` |
| `web/index.html` | 页面骨架与样式 |
| `web/moon.pkg` | 前端包声明（目标 `js`） |
| `.pi/extensions/pi-web-shell/index.ts` | pi 扩展：HTTP + WebSocket 桥接 |
| `dist/` | 构建产物（不入库） |
| `build.sh` | 构建脚本，`./build.sh release` 出 release |

## 设计要点

- **桥接层不做强类型反序列化**：只有最外层 `kind` 字段用于路由，其余原样透传给前端。
- **扩展统一转换事件形状**：`turn_end` 自带配对的 `toolResults`，所以前端只需消费
  `message_end`(user) 和 `turn_end`，不用处理 `tool_execution_*`，也不用自己配 ID。
- **思考与工具调用默认折叠**：原生 `<details>`，前端不做展开状态管理。
- **轮次锚点按用户提问分组**：pi 的一次提问会产生多个内部 turn（每次 LLM 调用一个），
  所以锚点按 user message 划分，符合直觉。
- **不做流式**：只消费完整消息，`Model` 保持简单。

## 已知限制

- 单会话：扩展绑定当前 pi 会话，多标签页共享同一路广播。
- 连接断开后不会自动重连（`connect` 只在启动时执行一次）。
- 无审批交互 UI：实测内置工具在 RPC 模式下不触发审批请求。
- WebSocket 端点固定为 `/pi`，与扩展的 `WS_PATH` 和前端 `WS_ID` 两处保持一致。
