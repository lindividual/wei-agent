# ADR-0002：进程级输出流必须串行写

- **状态**：已采纳
- **日期**：2026-09-13
- **相关**：`ui/log.mbt`、`ui/requests.mbt`、`ui/main.mbt`

## 背景

把 HTTP 路由从 `main` 抽成 `ui/requests.mbt`（见 ADR-0003）之后，`ui` 的测试开始
**大约三次里崩两次**：

```
Error: Failed to run the test: ui.whitebox_test.exe
The test executable exited with signal: 6 (SIGABRT)
Active tests at executable exit: ... （同时有 8 个测试在执行）
```

崩点不在被测代码里，而在 `ui/log.mbt` 的 `@stdio.stderr.write`：

- `moon test` **并发**跑同一个包里的测试；
- 抽出来的显示 worker 里有 `log`，于是多个测试同时走到 stderr 写上；
- **并发写 `stderr` 不安全**，而且失败方式不是「行被写花」，是运行时写路径抛 `PanicError`、
  进程直接 abort。

同一条 bug 在生产里的形态更糟：**turn 是并行的**（每个打开的会话一个槽位），每个 turn 都会
log，所以两个会话同时工作时写 stderr 就是常态，而不是边角情况 —— 服务器会在第一次两个 turn
同时写日志时挂掉。

## 决策

**对进程级共享输出流的写必须串行。** `ui/log.mbt` 用一个顶层 `let` 的 `@async.Mutex` 包住写：

```moonbit
let log_lock : @async.Mutex = @async.Mutex()

pub async fn log(line : String) -> Unit {
  log_lock.acquire()
  defer log_lock.release()
  @stdio.stderr.write(line + "\n")
}
```

**顶层 `let` 是承重的**：每次调用新建一个 mutex 等于什么都没串行化。

**另一条独立的决定**：`Requests`（被测的模块）不记日志。`apply_display` 不 log；读队列的 worker
在 `main` 里，由它记一行。理由不是「会崩」（那已经修了），而是**日志是进程的事**，不是模块的事：
它写给「启动这个进程的人」，而 `main` 的界线正是「进程的事留下，模块的事拿走」。它同时避免了
被测模块往测试输出里写噪声。

## 理由

- 症状（`SIGABRT` + 多个 active tests）指向的位置极具误导性：崩在**测试基础设施**里，而不是在
  出问题的代码里。没有这条记录，下一个人会先怀疑测试框架，而不是「谁在写共享流」。
- 「并发写共享流不安全」在这套运行时的文档里不显著，而且不像常见的 data race 那样表现为数据损坏，
  而是直接 abort —— 一个好得多的失败，但认不出来。
- 用 mutex 而不是无锁队列：每轮就几行日志，争用可以忽略，而它给的**顺序性**（一行写完整再写下一行）
  本来就是日志可读的前提。

## 后果

- 任何新增的进程级输出（stdout 报告、进度条、别的诊断）都要走同一个锁，或者自己串行化。
- `moon test` 里出现 **`SIGABRT` + 「多个 active tests」** 的组合时，第一个该查的是
  「有没有哪个模块在并发写共享流」。
- 这条约束没有类型层面的强制，只靠约定：`log` 是唯一的出口，新的输出请加在它里面。
