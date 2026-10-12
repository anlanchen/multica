# Multica 桌面端性能卡点分析与 Swift 原生版设计

> 分析对象：[multica-ai/multica](https://github.com/multica-ai/multica) @ `a820c9a`（2026-10-11）。
> 证据来自上游源码、提交历史（commit / PR 号 / MUL 工单号均可在上游仓库检索）与其自带的性能场景 `e2e/perf/`。
> 本仓库的 Swift 实现与基准测试数据见文末。

## 0. 结论速览

上游桌面端 = Electron 39（Chromium 渲染进程 + Node 主进程）包着与 Web 共享的 React 19 前端（`packages/views` 约 14.8 万行 TSX）。
**所有卡点的共同根因：一切都挤在渲染进程的单一主线程上**：WebSocket 帧解析、TanStack Query 缓存合并、React 协调、样式重算/布局、ProseMirror 编辑器、Markdown/Mermaid/代码高亮，全部在同一个线程里串行执行。上游过去几个月的性能修复（下表"上游证据"列）都是在这个约束下"少做一点"，而原生客户端可以从结构上把这些工作移出主线程，或者根本不做。

| # | 卡点 | 上游证据 | Swift 版对策 | 实测（同机对比） |
|---|---|---|---|---|
| P1 | `task:message` 全工作区广播，每个客户端解析每一帧 | MUL-6396 / #7227；`server/cmd/server/listeners.go` 注释：按任务 scope 路由"因客户端不发 subscribe 而未启用" | 后台 actor 收帧；字节级前缀扫描判定任务归属，不关心的帧**不做 JSON 解析**；对打开的任务发送 `subscribe` 帧（服务端一开关即生效） | 每帧 21.3 µs → 2.8 µs（约 7.5×），且全部离开主线程 |
| P2 | 执行日志每次刷新全量重建 + 全量脱敏 | MUL-7227 / #8242：3000 条消息每次 flush ~25 ms，每个运行中 run 每秒 250 ms；#8172 用 seq 作 key 导致 DOM 节点替换 | `TranscriptBuffer` 增量合并 O(批量)，步骤 id 稳定；脱敏在入站时一次性完成且在后台 | 3000 条时每次 flush 主线程 0.024 ms（与长度无关） |
| P3 | 列表/看板渲染放大 | MUL-4474：每行订阅整份 task snapshot；看板每卡 ~6 个弹层；虚拟化合入→回滚（#5395）→加 seed 补丁重合（#5403）；切 tab 主线程冻结数秒 | 每行一个 `@Observable IssueModel`，事件只使对应行失效；`List`（NSTableView 复用）+ `LazyVStack` 看板；右键菜单按需构建 | 1000 次字段更新 0.9 ms、0 次重分组；1000 次状态迁移合并为 1 次重分组 |
| P4 | 主线程上的重解析 | MUL-5345 卡死报告中出现 `parseMarkdownChunked`；lowlight `highlightAuto` 对无语言代码块跑全部语法；MUL-7760 关弹窗重渲 Mermaid（140–200 ms 长任务） | Markdown 后台解析 + 内容哈希缓存；纯 `Text` 渲染；无语言代码块不做自动识别；主题变化由系统处理，不监听 DOM 属性 | — |
| P5 | 过量请求 / 请求风暴 | MUL-6967：未读角标下载整个收件箱；#8242：`refetchOnWindowFocus:"always"` 每次切回窗口重下全部执行日志；#9088：4 个相同的 `GET /api/issues`；MUL-4159、MUL-7838 | 相同 GET 单飞合并（single-flight）；角标只用 `unread-summary`；无"聚焦即重拉"；重连后只补拉屏幕上的数据 | 单测：8 个并发相同请求 → 1 次网络请求 |
| P6 | 渲染进程卡死 | MUL-5345、MUL-4115：为了定位卡死加了看门狗、CDP 抓栈、磁盘面包屑、重启恢复（`freeze-breadcrumb.ts`、`renderer-recovery.ts`） | 原生单进程；所有 I/O、解码、脱敏在 actor / 后台执行器；主线程只做"把一批结果写入模型" | — |
| P7 | 本地 daemon 管理开销 | `daemon-manager.ts`：固定 5 s 轮询 `/health`、`fs.watchFile` 500 ms 轮询日志、主进程↔渲染进程 IPC | 自适应轮询（过渡态 1 s / 前台 5 s / 后台 60 s / 无观察者停止）；kqueue 事件驱动跟踪日志，只在面板可见时开启；无 IPC | — |
| P8 | 帧时间戳/日期解析 | 前端到处 `new Date(...)` | 字符串原样保存，渲染时用手写 RFC 3339 解析器 | 49 µs → 0.05 µs / 个（Linux Foundation 的 `ISO8601DateFormatter`） |

## 1. 上游架构与数据流

```
Go server (chi + sqlc + gorilla/websocket hub, Redis relay)
   │  REST  /api/*            WebSocket /ws（workspace 级广播）
   ▼
Electron 39
 ├─ main 进程 (Node)：窗口、深链 multica://、自动更新、daemon-manager.ts（1502 行）
 │      └─ execFile("multica daemon start|stop") / fetch 127.0.0.1:<port>/health / watchFile(daemon.log)
 └─ renderer 进程（单线程）：
        WSClient.onmessage → JSON.parse(整帧)
          → use-realtime-sync.ts（1902 行）对 ~90 种事件做 setQueryData / invalidateQueries
          → TanStack Query 结构共享 → React 19 协调 → 样式重算/布局/绘制
        + TipTap/ProseMirror 编辑器、react-markdown、shiki/lowlight、mermaid、katex、dnd-kit、react-virtuoso
```

关键事实：

- **服务端广播粒度是整个工作区**。`listeners.go` 写得很清楚：hub 的 `subscribe/unsubscribe`、`ScopeAuthorizer`、Redis Streams relay 都已就绪，但"客户端还不发 subscribe 帧、重连也不重放订阅"，所以 `task:*`/`chat:*` 仍然 fan-out 给工作区里每一个连接。
- **服务端写缓冲只有 256 帧**（`hub.go` 中 `send: make(chan []byte, 256)`），写不进就丢。渲染线程卡住的客户端会从服务端视角"变慢"，进而丢消息，然后只能靠 refetch 修复。
- WebSocket 信封由 Go `map[string]any` 序列化，**key 按字母排序**：`actor_id, actor_type, payload, type`。`type` 在最后，所以 JS 必须把整帧（含几 KB 的工具输入）`JSON.parse` 完才能知道这是什么事件。

## 2. 卡点逐项分析

### P1 实时消息扇出（最主要的持续负载）

`task:message` 是 agent 执行时的流式输出：每个工具调用、每段文本、每段思考各一帧。`input` 不设上限（一次 `Write` 工具调用就把整个文件内容放进帧里）。服务端把每个 run 的每一帧发给工作区的**所有**客户端。

上游在 MUL-6396（#7227）做了三件事：没有视图在看的任务丢弃；把幸存帧按 100 ms 固定窗口合并为一次缓存写；服务端裁剪广播副本（默认关闭，因为老客户端读不懂 `truncated`）。剩余的问题：

1. "丢弃"发生在 `JSON.parse` **之后**，解析成本照付，而且付在 UI 线程上；
2. 一次合并写仍然要触发 React 协调；
3. 每帧一个 WS 消息的形态没变（提交说明里明确写了留给"客户端 scope 订阅"那项工作）。

### P2 执行日志：每次 flush 全量重建（MUL-7227）

#8131 把执行日志嵌进评论流后，每个运行中的 run 在每个 100 ms 窗口都会重建时间线，而重建意味着对**每一条消息的每一个字节**跑 13 个脱敏正则。上游实测：3000 条消息时每次 flush ~25 ms，相当于每个 live run 每秒吃掉 250 ms 主线程，两三个 agent 同时跑就转彩虹球。#8242 把结构计算和脱敏拆开，脱敏只做在屏上的行。

更隐蔽的一次回归是 #8172：run 摘要用消息 `seq` 作 key，每来一条消息就替换一个 DOM 节点并触发样式重算，"在长 issue 里打字评论从几秒变成几十秒"。上游为此专门写了浏览器性能场景 `e2e/perf/typing-under-live-runs.spec.ts`，因为 jsdom 单测看不到样式重算与主线程争用。

### P3 列表 / 看板的渲染放大（MUL-4474、MUL-4741、MUL-4750）

- 每个 issue 行的 `IssueAgentActivityIndicator` 都 `useQuery` 订阅整个工作区 task snapshot，任何任务变化都让所有行重渲（#5338 用 `select` 收窄）。
- 看板每张卡急切挂载约 6 个弹层根节点（右键菜单、选择器、悬停卡片）以及各自的查询订阅，"切到看板主线程冻结数秒"（#5403）。
- 虚拟化（react-virtuoso）在 DOM + dnd-kit 下非常难做：合入后因为回到页面闪白被回滚（#5395），之后靠 `VirtuosoSeed`、预估行高、≤30 张卡不虚拟化等补丁重新合入，并写了一整套"拉取式滚动恢复"协议。
- 桌面端 tab 原来是"每个 tab 一个 router + `<Activity>` 保活"，后改成单 router + Coordinator 协议（MUL-4741 Phase 2）。

### P4 主线程上的解析与重渲

- 卡死报告的诊断上下文里专门给 `parseMarkdownChunked` 打了标记（#5989），说明长 Markdown 解析确实出现在卡死现场。
- lowlight 的 `highlightAuto` 会对无语言标注的代码块跑所有已注册语法，是评论多的 issue 打开时的主要成本（#5403 改为纯文本）。
- MUL-7760：Base UI 打开/关闭弹窗时写 `<body>` 的 `overflow`，被主题监听当成主题变化，于是每次关弹窗都重渲页面上所有 Mermaid 图（140–200 ms 长任务）。
- 每条评论都是一个 TipTap/ProseMirror 实例，详情页挂载成本高（#5403 改为"有意图才挂载"）。

### P5 过量请求

| 问题 | 上游修复 |
|---|---|
| 侧栏/Dock/移动端未读角标靠 `GET /api/inbox`（无分页、带完整评论正文）在客户端计数 | MUL-6967 改用 `unread-summary` |
| `useTaskMessages` 设了 `refetchOnWindowFocus: "always"`，每次 alt-tab 回来重下所有屏上 run 的完整执行日志（该接口不分页、工具载荷无上限） | #8242 移除 |
| 第一页 issue 列表按 4 个状态分类各请求一次，但参数没传出去，实际是 4 个完全相同的 `GET /api/issues?limit=50`，各自再跑一次 `COUNT(*)` | #9088 |
| 聊天待处理任务聚合的请求风暴 + 索引失配导致全表扫描 | MUL-4159 |
| working-agent 刷新查询过多 | MUL-7838 |

这些都是"缓存库按 key 管理请求"的模式里容易出现的问题：同一份数据挂在不同 key 下，失效就会放大。

### P6 渲染进程卡死

上游为卡死建了一整套设施：主进程监听 `unresponsive` / `render-process-gone`、写磁盘面包屑（`freeze-breadcrumb.ts`）、渲染进程恢复后补报（`freeze-flush.ts`，为避免丢报还专门处理了 ACK 时机）、通过 CDP `Debugger.pause` 抓卡死时的 JS 调用栈（MUL-5345）、`long-animation-frame` 看门狗。这说明卡死在生产环境中真实且反复出现（MUL-4115："三次卡死，零个事件"）。

### P7 本地 daemon 管理

`daemon-manager.ts` 无论窗口是否可见，都每 5 s 探测一次 `/health`；日志面板用 `fs.watchFile` 每 500 ms 轮询文件；每次状态变化都要从主进程 IPC 到渲染进程。单次开销不大，但都是常驻的。

## 3. Swift 版设计

### 3.1 线程模型：主线程只做"应用结果"

```
URLSessionWebSocketTask ──► RealtimeClient (actor，后台)
                              ├─ FastRouting：O(前缀) 字节扫描，判定 task_id/issue_id
                              ├─ FrameRouter：单遍解码（先读 type，再决定解多少 payload）
                              ├─ Redactor：入站时一次性脱敏（只针对保留下来的帧）
                              └─ FixedWindowBatcher：前沿立即 + 100 ms 固定窗口
                                        │ AsyncStream<RealtimeEvent>（已解码、已合并）
                                        ▼
                              WorkspaceSession (@MainActor) ──► @Observable 模型 ──► SwiftUI
APIClient (actor)：请求头/单飞合并在 actor 内，JSON 解码在 nonisolated 上下文（后台执行器）
DaemonController (actor)：/health 探测、CLI 子进程、自适应轮询
```

### 3.2 P1 → 字节级路由 + scope 订阅（`Realtime/FastRouting.swift`、`FrameRouter.swift`）

- 利用服务端信封 key 有序这一事实：帧以 `"type":"task:message"}` 结尾，说明顶层事件类型就是它（JSON 文档最后一个 `}` 之前的键值对必然属于顶层对象）。随后只走 `payload` 开头的标量键拿到 `task_id`/`issue_id`，遇到嵌套值就停。
- 不确定（键序不同、id 含转义、在拿到 id 前遇到嵌套值）就返回 nil，回落到完整解码器。**快路径只会跳过工作，不会改变结果**，单测覆盖了嵌套 `type`、无 `issue_id`、转义 id 等边界。
- 打开执行日志时向服务端发 `{"type":"subscribe","payload":{"scope":"task","id":…}}`，重连时自动重放。服务端今天仍按工作区广播，订阅帧会得到 ack 但无副作用；一旦 `listeners.go` 改为按任务 scope 路由，这个客户端无需改动即可从源头消除扇出。
- issue 级兴趣：打开 issue 详情时，该 issue 下**之后才启动**的 run 的消息也会保留，不会因为"还没来得及注册 task id"丢掉开头。

### 3.3 P2 → 增量执行日志（`Stores/TranscriptBuffer.swift`）

- 消息按 `seq` 有序去重；常见情况（`seq` 递增）只追加并改动 `steps` 尾部，O(批量)；乱序或带变化的重复（REST 回填与实时帧竞争）才做一次 O(n) 重建。
- 工具调用与结果按 `call_id` 配对（无 `call_id` 时按工具名），步骤 id = 首条消息的 `seq`，在后续合并中保持不变，视图行被复用而不是替换（正是 #8172 的教训）。
- 脱敏在入站时对**整条正文**做一次（先脱敏后截断，避免 #8242 评审发现的"截断把密钥切成两半导致正则失配"），渲染时只截断。
- 单测用随机拆批 + 局部乱序 + 重复回放，验证增量结果与"排序后整体构建"完全一致。

### 3.4 P3 → 行级观察（`Stores/IssueStore.swift`）

- 每个 issue 一个 `@Observable IssueModel`；身份表 `models` 标记为 `@ObservationIgnored`，插入不会让所有行失效。
- `issue:updated` 只改字段时只写该行的模型；状态/排序变化才标记重分组，同一主线程回合内的多次变化合并成一次 `resection`。
- agent 活跃状态是每行模型上的一个整数，`task:*` 生命周期事件只触达一行（对应 MUL-4474 的放大问题）。
- `List` 在 macOS 上由 NSTableView 支撑，行懒创建并复用；看板列是 `LazyVStack`，拖拽用系统 `draggable`/`dropDestination`，无需在 DOM 虚拟化与拖拽库之间做妥协。
- 评论输入框与时间线是兄弟视图：打字只重绘输入框，流式输出只重绘对应 run（对应 MUL-7227 的打字场景）。

### 3.5 P4 → 后台 Markdown + 纯文本渲染（`Support/MarkdownCache.swift`）

Markdown 在后台解析为 `AttributedString`，按内容哈希 LRU 缓存；视图只渲染 `Text`。不挂富文本编辑器，不对无语言代码块做自动语言识别。

### 3.6 P5 → 请求纪律（`Networking/APIClient.swift`、`Stores/WorkspaceSession.swift`）

- 相同的并发 GET 共享一个请求（key 含 URL、凭证、工作区，切换身份不会串数据）。
- 角标只用 `/api/inbox/unread-summary`，收件箱列表只在用户打开时拉取。
- 没有"窗口聚焦即重拉"；重连成功后只补拉第一页 issue、task snapshot、未读汇总、打开的 issue 详情和正在看的执行日志。
- 引用数据（成员、agent、状态目录、runtime）变化时去抖 250 ms 后重新拉取，而不是把事件负载合并进缓存（与上游 AGENTS.md 的状态规则一致）。
- 401 只在"仍是当前凭证"时才登出（对应上游 MUL-7028）。

### 3.7 P7 → daemon 管理（`Daemon/`）

- profile 命名与健康端口算法与 Go CLI、Electron 完全一致（单测用 Node 的 WHATWG URL 结果做了对照），两个客户端操作的是同一个 daemon，且永远不会碰用户自己的 `~/.multica` 默认 profile。
- 为 daemon 铸造 PAT 并写入 profile 的 `config.json`（0600），复用 `.desktop-user-id` 旁注文件判断用户是否切换。
- 健康探测自适应：过渡态 1 s、前台 5 s、后台 60 s，没有观察者时不探测；日志跟踪用 kqueue（`DispatchSource` vnode），只在日志面板可见时运行。

## 4. 实测数据

运行方式：`swift run -c release multica-bench`。以下数据来自本次开发环境（Linux x86_64，4 核，Swift 6.1.3 release），同一进程、同一份数据，对比"上游策略"与"本客户端策略"。表中是单次运行的结果，重复运行的波动在 ±20% 以内，量级与结论不变。

macOS CI（Apple Silicon，3 核）上同一基准的关键数字：扇出每帧 24.2 µs → 2.2 µs；3000 条时每次 flush 主线程 0.051 ms（上游策略 103 ms / 仅结构 0.52 ms）；时间戳 44.7 µs → 0.07 µs。与 Linux 结论一致。

**注意：** 这是 Swift 实现之间的对比，不是 Swift 与上游 JS 的绝对值对比。比如"全量脱敏"比上游 V8 报告的 ~25 ms 慢得多，因为 Foundation 的 `NSRegularExpression`（ICU）比 V8 正则慢。应该看的是**扩展性**（随转录长度增长与否）和**发生在哪个线程**。CI 的 macOS 任务每次都会把基准结果写进 job summary。

### 4.1 `task:message` 扇出：10000 帧，20 个并发 run，16.4 MiB，屏上只看 1 个

| 策略 | 总耗时 | 每帧 | 保留消息 |
| --- | --- | --- | --- |
| 解码每一帧（上游 MUL-6396 之前） | 220.0 ms | 22.00 µs | 10000 |
| 只解码路由键、跳过正文（单遍解码器） | 74.6 ms | 7.46 µs | 500 |
| 字节级前缀扫描 + 解码器兜底（本客户端） | 28.3 ms | 2.83 µs | 500 |

### 4.2 执行日志：一次 flush（10 条新消息）的成本 vs 转录长度

| 策略 | @500 条 | @1000 条 | @3000 条 |
| --- | --- | --- | --- |
| 重建步骤 + 脱敏全部正文（上游 MUL-7227 之前） | 16.3 ms | 32.2 ms | 98.1 ms |
| 只重建步骤（上游 #8242 之后） | 0.113 ms | 0.216 ms | 0.768 ms |
| 本客户端主线程：增量合并 + 截断可见行 | 0.025 ms | 0.024 ms | 0.024 ms |
| 本客户端 realtime actor：脱敏 10 条新消息（后台） | 0.232 ms | 0.227 ms | 0.231 ms |

### 4.3 Issue store：5000 个 issue

| 操作 | 耗时 | 列表重分组次数 |
| --- | --- | --- |
| 初次加载 + 分组 | 19.5 ms | 1 |
| 1000 次 `issue:updated` 字段修改（行级失效） | 0.92 ms | 0 |
| 一次突发中的 1000 次状态迁移（合并） | 14.0 ms | 1 |
| 1000 个任务生命周期事件（行级活跃标记） | 0.86 ms | 0 |

### 4.4 RFC 3339 时间戳解析：100000 个

| 解析器 | 总耗时 | 每个 |
| --- | --- | --- |
| `ISO8601DateFormatter` | 4933 ms | 49.33 µs |
| `Timestamp.parse`（本客户端） | 5.4 ms | 0.05 µs |

## 5. 复刻范围

已实现（与上游同一套 REST / WebSocket 协议，直接连 Multica Cloud 或自托管服务器）：

- 登录：邮箱验证码；浏览器登录（Google）经 `multica://auth/callback?token=` 深链回到应用；Token 存钥匙串
- 工作区切换（其他工作区有未读时打点）、实时连接状态
- Issues：列表 / 看板、筛选（全部/我的/agent/运行中/未分配）、搜索、分页加载、右键改状态/优先级/负责人、看板拖拽改状态、新建 issue
- Issue 详情：标题（双击改名）、状态/优先级/负责人、Markdown 描述、评论 + 活动时间线、发表评论（发送中/失败重试）、agent run 列表（实时一行摘要、展开看完整执行日志、取消）
- 收件箱：未读角标、列表、标为已读、归档、全部已读
- Agents、Runtimes 列表；本机 daemon 启停/重启/开机自动启动/日志
- 菜单栏常驻：daemon 状态、未读数、正在工作的 agent
- 设置：自托管服务器地址；诊断面板（请求数、单飞合并数、帧数、丢弃/保留的任务消息、解码耗时、重连次数）

尚未实现：Chat、Projects、Autopilots、Squads、Skills、标签/自定义属性编辑、附件上传、富文本编辑器与 @提及补全、多标签页、自动更新、系统通知、多语言、插件、计费、IM 集成、新手引导。

## 6. 验证情况

- `MulticaCore` + 测试：在 Linux 上用 Swift 6.1.3（Swift 6 语言模式、严格并发检查）构建，**52 个测试全部通过**，全量连续跑 30 次 0 失败。测试覆盖模型容错解码、帧路由（含快路径与完整解码器一致性）、批处理窗口、重连与订阅重放、增量转录（随机化等价性）、脱敏、store 行为、API 单飞与 401 处理，以及用假 HTTP / 假 WebSocket 跑通的端到端会话（启动 → 实时更新 → 打开 issue → 执行日志回填与实时合并 → 发评论）。
- **macOS**：`.github/workflows/ci.yml` 在 GitHub Actions `macos-15`（Apple Silicon）上编译并链接 SwiftUI/AppKit 应用目标、打包出 ad-hoc 签名的 `Multica.app`，并跑通同样的 52 个测试和基准，均已通过。尚未在真机上做交互走查（窗口、菜单栏、深链、钥匙串的实际行为）。
- 没有连真实服务器测试（无账号凭证）。接口与字段取自上游 `a820c9a` 的 Go handler、`packages/core/types` 与 zod schema，解码全部按"缺字段给默认值、未知枚举保留原值"的容错方式实现。

## 7. 后续建议

1. **服务端（收益最大）**：在 `listeners.go` 中把 `task:*`/`chat:*` 改为 `BroadcastToScope`。本客户端已经发送并在重连时重放 scope 订阅，可以先只对声明了 `client_platform=macos-native` 的连接启用；之后再把"每批一帧"的形态做进协议。
2. 在 macOS 上用 Instruments（Time Profiler、SwiftUI、Hangs、Allocations）在上游 `e2e/perf` 的同一场景下测量：长 issue + 3 个 live run + 打字，记录主线程占用与内存，与 Electron 版本对比。
3. 若评论数达到上千，时间线可从 `LazyVStack` 换成 `NSTableView` 包装以获得真正的行复用；目前的数据规模下 `LazyVStack` 已足够。
