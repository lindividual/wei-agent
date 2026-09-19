# 设计：`script` 工具 + 预写脚本库

- **状态**：待评审（未实现）
- **日期**：2026-09-14
- **相关**：`core/tools.mbt`、`platform/tools.mbt`、`platform/jobs.mbt`、`README.mbt.md`

## 一句话

**加一个工具 `script`，跑 MoonBit 单文件程序；配一小撮预写脚本（`@builtin/*`），模型多数时候只用传参数。**
少量但强大的工具：模型不必写代码，也不必读几十 KB 的原始输出。

## 1. 工具形状

```json
{
  "name": "script",
  "description": "Run one of the prewritten scripts in @builtin (see the list below), or a MoonBit program of your own. Prefer a @builtin script: it returns a compact digest instead of raw output. Scripts can read the workspace, run commands, and edit files, and their stdout is the result.",
  "parameters": {
    "name":   "string — a @builtin script, e.g. \"@builtin/check\"; gives it args",
    "args":   "array of strings — arguments for that script (optional)",
    "source": "string — a MoonBit program instead; must define `async fn main` (optional)",
    "label":  "string — one-line label for the transcript (optional)"
  },
  "oneOf": [["name"], ["source"]]   // 描述里写清：二选一
}
```

两条用法，互斥（同 openseek 的 `filename`/`source`）：

```
script(name="@builtin/check", args=["core"])
script(source="async fn main { println(search(\"fn trim_\")) }")
```

### 预写脚本清单（v1，四个）

清单写进工具描述，模型不必去读源码。

| 脚本 | 参数 | 返回（实测） |
|---|---|---|
| `@builtin/check` | `[pkg]` | 跑 `moon check --output-json`，**按文件聚合**错误，只留首行消息。**40 个错误：21,336B → 2,028B（10.5×）**；2 个错误：562B → 211B；干净时一行 |
| `@builtin/test` | `[pkg\|file]` | 跑 `moon test`，只报失败，**长值截到 120 字符**（失败输出里同一段 400 字符值会打印三遍：断言、diff 的 `-`、diff 的 `+`） |
| `@builtin/search` | `[pattern] [dir]` | `@regexp` 扫工作区，返回 `path:line: text`，跳过 `_build`/`.git`/`.mooncakes`；封顶条数 |
| `@builtin/read` | `[path[:from:to]…]` | 批量按行区间读，带 `total_lines`/`truncated` 页脚 |

**为什么是这四个**：按实测的工具调用分布（3,810 次），探索类占 **39.3%**、exec 类 **19.6%**、
`read`/`glob`/`grep` 工具 **10.2%**。`check`+`test` 吃 exec 的主体，`search`+`read` 吃探索与读。
剩下的 `edit`（12.7%）留原样，见 §6。

## 2. 预置库（inline 时注入）

staged 文件 = **固定 import 块 + 预置库 + 用户/脚本主体**。预置库只有 6 个函数，无 `main`：

```moonbit
list(dir = ".")                     // -> Array[String]   跳过构建目录
read(path)                          // -> String
read_lines(path, from, to)          // -> Array[String]   1-based，含两端
search(pattern, dir = ".")          // -> Array[String]   "path:line: text"，正则，封顶
read_json(path)                     // -> Json
edit_text(text, old, new)           // -> String          old 必须恰好出现一次，否则抛错
```

预写脚本**也用这份预置库**（同一个 staging 路径），所以没有两份实现。import 块是固定的
（预置库用到了 `@fs`/`@regexp`/`@json`/`@process`/`@env`），因此不会产生未使用 import 的警告。

## 3. 怎么跑

| 项 | 做法 |
|---|---|
| staging | 会话级的临时目录 `<home>/.wei/scratch/<session-id>/`，**在工作区之外**（实测 `/tmp` 也能跑，依赖从全局 cache 解析） |
| 编译产物 | `--target-dir` 指向 staging 下的 `target/` 子目录，所以工作区的 `_build` 不受影响 |
| target 为什么多一层 | `moon run <file> --target-dir X` 实际用的是 `X/<文件名>`，不是 `X`。直接给 staging 目录，等于要求把 `<stage>/script.mbtx` 当目录，而它就是源文件，`moon` 会拒绝（`target directory ... exists and is not a directory`）。多一层把源文件和构建目录分开 |
| 热编译 | **复用同一个目录就是缓存**（实测冷 0.27–0.35s、热 0.03s）。不需要 openseek 的 157 行 build cache |
| cwd | 工作区根目录，相对路径才能落到项目上 |
| 执行 | `@process.collect_output_merged` 起 `moon run --target native <staged>`；错误与输出都在返回值里 |
| 停止 | 与 `bash` 同一条路：`exec_managed` 的进程组 + `kill_pids`/`subtree`（已有），默认超时 60s |
| 截断 | stdout 封顶 **32KB** 加明确标记（openseek 的停止上限是 48KB，取小一档） |
| 失败 | 非零退出按 `bash` 的规矩返回结果 + returncode，不当工具错误 |

## 4. 日志

记 `{label, name|source, args, returncode, output(截断后), elapsed_ms}`，`source` 原样保留——
「当时到底跑了什么」必须能从日志重建。脚本内部读了哪些文件不进日志（没经过我们）；变更的权威
记录是 git 的 diff。代价：转写里批量操作会从多张卡变成一张 `script` 卡。

## 5. 安全边界：说清楚，不粉饰

**native 的 `script` 与 `bash` 同级信任**——脚本能读、能起进程、能改工作区内的文件。它不是安全
改进，**是效率改进**（结构化返回 + 预写库 + 可编排）。真正的沙箱有两条路，都不在 v1：

- **wasm + moonrun policy**（openseek 的做法）：真沙箱，但要 `@fs` 在 wasm 上不可用
  （实测 `@fs.walk` 不存在），读文件必须靠 policy 逐项授权——**652 行的代价**。
- **JS + `node --permission`**：沙箱白送（实测默认拒 fs/child_process、按目录放行），但要多一个
  node 运行时依赖。

v1 选 native 的理由：**收益的大头（`check`/`test`/`search`）不需要沙箱**，而沙箱是这两条路里
最贵的一块。等 §8 的数验完再决定要不要付。

**工作区边界**：脚本自查 `@fs.realpath`（实测存在），拒绝越界路径。node 那边是 `--allow-fs-read`
的前缀判断会被软链穿过；我们有 realpath，所以这一条**比 JS 路线强**。

## 6. 与现有工具的关系：都保留

`bash` / `read` / `write` / `edit` / `glob` / `grep` / `note` **一个都不删**。

- 简单任务用它们更便宜：一次 `read` 是一个往返，写一段脚本至少是「生成代码 + 跑」；
- 它们是模型最熟的形状，删了要重学；
- `script` 的定位是**当一步需要多于两三次读取、或输出可能很大时**。

这句话必须进系统提示的「How to work」，否则工具加了没人用——这是最常见的失败。验收里专门有一条
量 `script` 的使用率。

## 7. 明确不做（v1）

- **不删现有工具**（见 §6）。
- **不做 wasm policy 沙箱**（652 行，见 §5）。
- **不做 build cache 逻辑**：复用 scratch 目录即可。
- **不做 save workflow / `@builtin/*` 之外的命名空间**：脚本不能存下来复用。
- **不做后台任务收养**：`jobs`/`exec_managed` 已有，需要时单独接。
- **不做 workflow / subrun / scout**（openseek 另三个包）。

## 8. 验收与证伪

| 指标 | 取法 | 目标 |
|---|---|---|
| 每轮模型调用数 | `TurnResult.model_calls`（已有） | 降 ≥20% |
| 每轮 fresh input | `request_drift` + `usage`（已有） | 降 ≥20% |
| 进 context 的工具结果字节 | 结果分布（已有） | p90 从 3.1KB 降到 1KB 量级 |
| `script` 使用率 | 新增计数 | 探索/exec 类任务里应占多数 |
| 未经校验的 `sed -i` 批量改 | 日志分类脚本 | 应下降（`edit_text` 是它的严格升级） |

**A/B**：本仓库历史里 5 个「长探索」任务（中位 32 次调用那一档），各跑 3 次，注册/不注册两臂。
预算 ≈ **$0.75/臂，两臂 <$2**。

**证伪**：模型不用 `script`；往返没降；字节没降；→ 停下来看数据，别继续加功能。

## 9. 实施计划

| 文件 | 改动 |
|---|---|
| `core/script.mbt`（新） | 工具声明 + **预置库源码**（常量）+ 四个预写脚本的**元数据**（名字、参数说明、一行描述）+ 结果截断。`core` 不碰 IO |
| `core/tools.mbt` | `builtin_tools()` 加 `script_tool()` |
| `core/system_prompt.mbt` | 「How to work」加：什么时候用 `script` |
| `platform/scripts/*.mbtx`（新） | 四个预写脚本本体（可单测：能编译、返回形状稳定） |
| `platform/script_run.mbt`（新） | staging 目录、拼 import+预置库+主体、起 `moon run`、收输出、realpath 越界检查、清理 |
| `platform/tools.mbt` | `"script" => run_script(...)` |
| `macos/appffi/` | 转写里显示 `label` 与 `name`/`source`（`ui/` 已删） |
| `README.mbt.md` | 「已知限制」补：与 `bash` 同级信任、工作区边界、没有 moon 时的行为 |

单测：工具 schema（`name`/`source` 二选一）；预置库字符串含全部 6 个函数名（防漂移）；
预写脚本能编译且干净仓库下 `check` 返回一行；截断发生在 32KB 且带标记；realpath 拒绝一个指向
工作区外的软链；`moon run` 不可用时返回错误结果而非异常。

## 10. 依据

工具调用分布（3,810 次分类）、单次往返 3.6s、每轮中位 32 次调用、结果体量 p90 3.1KB/最大 51KB，
以及 `moon run` 冷热编译与 `@regexp`/`@fs.realpath`/`@process` 的可用性，均为本机实测，记录见
本次调研的对话与 `README.mbt.md` 的「实测过的性能账」。
