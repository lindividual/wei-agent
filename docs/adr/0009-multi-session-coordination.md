# ADR-0009：多会话不引入协调层，只保留事实可见的那一半；跨进程同会话互斥留到做跨进程沟通时

- **状态**：已采纳（并记录一个已知缺口）
- **日期**：2026-09-19
- **相关**：`docs/macos-pitfalls.md`（多实例那条）、`macos/README.md`（「浏览 ≠ 打开」、每会话一份转录）、
  `core/tools.mbt`（`Concurrency`）、`agent/driver.mbt`（`run_tools`）、
  `core/jobs.mbt`（`~/.wei/jobs.json` 是全局的）
  · **`core/tool_plan.mbt` 已删（2026-09-19）**，见下面「顺手记下来的那件事」

## 背景

一个工作区里同时开几个会话是常态（三栏布局至少让这件事读得通：浏览一个项目、切换、每会话一份转录）。
于是有一个问题：**两个会话在同一棵工作树上跑，会不会互相破坏？** 这里的输入是两件事 —— 实测
（本机，2026-09-18）和一份外部调研（Anthropic 的 multi-agent 工程博客、Claude Code 的
`cross-session-messaging` / `agent-teams` / `worktrees` 文档、git 官方手册）。

### 实测的四个事实

| # | 事实 | 怎么测得 |
|---|---|---|
| 1 | 同一工作区的两个会话**不互相损坏，而是排队** | `_build/.moon-lock` 存在；两条 `moon build` 同时跑，B 等到 A 结束才说 `no work to do`。`macos/WeiShell/.build/.lock` 同理 |
| 2 | **一个分支只能被一个 worktree 占用** | `git worktree add ../wt-b feature` → `fatal: 'feature' is already used by worktree at …` |
| 3 | worktree **共享 refs/objects**，index 与工作区独立 | wt-a 里 commit，主工作区 `git log feature` 立刻看到；wt-a 改文件后主工作区 `git status` 干净 |
| 4 | 本仓库一个 worktree 的冷启动：**MoonBit ≈9s + Swift ≈9s**，约 **100MB/个** | 在 `/tmp` 建 worktree 后计时；`_build` 61M + `.mooncakes` 5.8M + `.build` 40M。依赖走**全局 cache**（`Using cached …`），所以不需要 `.worktreeinclude` 之类；但 `macos/vendor/libwei.a` 是 gitignore 的，还要 `build-moonbit.sh` |

### 场景清单（谁和谁抢什么）

| # | 场景 | 今天 |
|---|---|---|
| **A** | 无重叠：同工作区、改不同文件/不同包 | **已经能用**，两个 turn 各跑各的 |
| **B** | 文件重叠：改同一个文件 | `edit` 是「读-改-写」，没有版本检查；后写的可能覆盖前一个 |
| **C** | 资源重叠：构建目录、测试端口/临时 DB、dev server、`make-app.sh` 的产物 | 构建**排队**（事实 1）；`~/.wei/jobs.json` 是**全局**的，另一个会话起的进程在 jobs 面板里看得见 |
| **D** | 顺序依赖：B 要等 A 的迁移/测试跑完 | 读者自己盯 |
| **E** | 外溢：A 改了接口/schema/构建配置，B 不知道 | B 继续基于旧假设写 |
| **F** | 长任务 + 完成通知 | 一半已有（jobs 全局） |
| **G** | 交叉验证/评审 | 读者手工复制粘贴 |
| **H** | 同分支各自提交 → 历史分叉 | 会发生；worktree 是解法，代价见事实 2/4 |

读出的一件事：**A/C/D/F 只要「谁在跑什么」（会话级事实），只有 B/E 需要「碰了哪些路径」（路径级）**。

## 决策

**1. 不引入协调层。** 不做 worktree 工具、不做跨会话消息、不做共享任务列表、不做路径级冲突检测。

理由是三层里**只有 C 是白捡的**：构建系统自带锁，jobs 表本来就全局 —— 「等另一个结束」今天已经成立。
其余每一样都要付真实的代价：worktree 20–40s 冷构建 + ~100MB（事实 4）且一分支一 worktree（事实 2）；
编排层在本仓库的收益远小于复杂度。外部证据同向，三条各自的出处：Anthropic 的多 agent 研究系统
token 用量约 **×15**（相对对话），**同步执行子 agent 是瓶颈**，而且子 agent 的产物是按「传话」回
lead 的 —— 他们的修法是让子 agent **直接写文件系统**，不走 lead 转述。Claude Code 的 agent teams
是**实验性且默认关**，文档自己写「同文件编辑、强依赖的任务，单会话更有效」，并且要求模型**不得请
另一个会话做自己权限被拒的事**（把那种活交回读者）。商业信号也一致：Vibe Kanban 已 sunsetting ——
「给 agent 做看板」在整合，而工作区隔离（分支 + worktree + 终端 + dev server + diff）才是刚需。

**2. 结论的形态是「事实注入 + 策略静态 + 编排最小」，而不是二选一。** 这三层各自成立的理由不同，
将来真要推进时按这个分工做：

- **事实必须注入**，因为重叠是**运行时**才知道的：两个会话都是读者随手开的，谁先写哪个文件取决于模型
  中途决定做什么，所以「开始时定好」不可能知道会撞上。Claude Code 的答案也是这一路线里最锐利的：
  不是开始时选，而是**在它动文件之前**把它移进 worktree。
- **策略必须静态**，因为「怎么办」是不变的，而且每次重新推导会给出不同答案（同一局面两次不同处理 =
  读者无法建立预期）。落地地点本仓库已经有两个：工作区的 `AGENTS.md`（`platform/agents.mbt`，已作为
  `sections` 注入）和 skill（`platform/skills.mbt`，`~/.wei/skills`、`~/.agents/skills`、`<项目>/.wei/skills`）。
- **编排最小化**（共享任务列表、领任务）：只有 Anthropic 那种研究场景才值，开发者自己开几个会话不值。

**3. 注入的成本要当成复利来控。** 将来做 P1 时：只有同 cwd 有 peer 才注入；每条一行；只注入最近 N 条；
`touching` 列表有上限；长度有上限。

**4. 只有一条值得做硬边界**：worktree 之外写文件要读者批准（Claude Code 就是这么做的）；权限**每会话独立**，
且不得跨会话转嫁。

### 被删掉的尝试

这一轮真写了一版登记表（`core/instances.mbt` + `platform/instances.mbt`：`ShellInstance`
（pid / startedAt / cwd / session / busy）、`InstanceStore` 的 `live` / `peers` / `busy_elsewhere` /
`put` / `without_pid`、`~/.wei/instances/<pid>.json` 一进程一文件、事件写不心跳、`ps -o etime=` 判
「还是不是同一个进程」），共 23 个测试全绿但**零生产引用**，随后删掉。删的理由：

- 带测试的死代码是最坏的一种：CI 是绿的、看着是活的，然后慢慢和现实漂移。本仓库对此立场明确
  （`core/tools.mbt` 的「Deliberately absent」、`core/tool_plan.mbt` 的「would add machinery for a case
  that barely occurs」）。
- **它很可能被它要支撑的东西取代**：跨进程沟通一旦是 socket，presence 与活性就来自**连接** ——
  连接是权威，文件只是证据（这也是写在那份代码注释里的原话）。真要做的时机是设计那个协议的时候，
  而形状未必相同。

## 已知缺口（**记录下来，不是为了现在修**）

**跨进程的同一会话互斥还没有。** `Open.turns` 是 `@async.Mutex`，它只在**本进程内**给两个 turn
排序；两个窗口打开同一个会话并各自发一句，仍会交错写入同一个 `.jsonl` 并分叉历史 —— 这正是仓库注释里
「a fork this project has already produced once, and it left entries naming a parent that no longer existed」
说的那件事，只是那次发生在本进程（现已被 mutex 修掉），跨进程这一半没有人管。

真要修的话，最小形状**不是**这套登记表，而是**每会话一个锁文件**（`flock` 或 `O_EXCL`，内容写 pid）——
它比「一目录登记表」更小、更对症，因为目标只有「互斥」而没有「发现」。触发条件建议是：真的撞上一次。

### 顺手记下来的那件事：已经删了（2026-09-19）

（原本这里记的是：）`core/tool_plan.mbt` 的注释说并发安全性「Decided from the arguments, not the tool
name：reading two different files is safe, reading and writing the same file is not」，但
`agent/driver.mbt` 的 `run_tools` 实际填的是 `tool.concurrency is Safe`（**工具级静态标志**）。
也就是说「从参数判」这个意图**写了注释、没有实现**。

**处理方式是删，不是接上。** 量出来的事实：生产代码里对这个模块的唯一引用是
`ignore(@core.plan_shape(plans))`——注释自己写着 “The shape is not used to reorder execution today”，
而 `plan_segments` 从来没有被调用过。`run_tools` 的文档注释更直接地说 segmentation “is applied for its
ordering guarantee”——**顺序其实只来自那个 `for` 循环**。于是删掉：`core/tool_plan.mbt`（76 行）、
`core/tool_plan_test.mbt`（88 行）、`run_tools` 里 15 行填充代码、`core/tool_test.mbt` 里两条测试，
并把那段谎话注释改成实情。

为什么是删而不是接上：触发条件（本 ADR 自己写的）是「真的撞上一次」，而不是「将来也许要并发」。
而留着它的代价比 164 行大——它让读者以为调度在运行。这也正是上面那个实例登记表的同一条理由，
**同一份 ADR 里已经写过一次**。

**删除暴露出来的两件事**（都记下来，没有跟着删）：

1. **`ToolDef.concurrency` 现在没有读者了。** 它仍然携带真实信息（`read` / `glob` / `note` 是 `Safe`，
   `bash` / `write` / `edit` / `script` 是 `Exclusive`），所以保留，但把注释改成说实话：**已声明、
   未被查询**。若将来真要并发执行器，这就是它要读的东西；在那之前它是一份诚实的分类，而不是一个
   假装在调度的模块。
2. **`builtin_tool(name)`（单数查找）现在只剩测试在用。** 唯一的生产调用点就在被删的那段里。
   保留（`pub`，且 3 个测试文件用它），但它现在是一条只在测试里有读者的 API。

## 什么时候回头看这份 ADR

- 读者**真的撞上**两个会话写同一个文件、且丢了改动 → 做 P2（路径级事实）。**注意：**
  那时要写的是一个新的判定（从参数算的路径级安全），**不是**复活 `tool_plan`：被删掉的那个是从
  工具名算的，而 P2 要的正是这个仓库还没做过的那一半。
- 要做**跨进程沟通**（已声明的方向）→ 那时设计 socket 协议，presence/活性从连接来，并顺手定
  「同一会话跨进程互斥」怎么做（锁文件 vs 协议内声明）。
- 一个会话开始**经常**要等另一个的测试/迁移 → 先看 F（idle 通知）够不够，不要直接跳到编排。
