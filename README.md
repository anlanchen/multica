# Multica Native（macOS）

[Multica](https://github.com/multica-ai/multica) 的 Swift 原生 macOS 客户端：与官方 Electron 桌面端连接同一套 REST / WebSocket 接口（Multica Cloud 或自托管均可），针对上游已知的性能卡点重新设计了数据通路。

- 性能卡点分析、设计取舍与实测数据：[`docs/performance-analysis.md`](docs/performance-analysis.md)
- 最低系统：macOS 14 Sonoma（`@Observable`、`MenuBarExtra`、`SettingsLink`）
- 工具链：Swift 6 / Xcode 16+

## 为什么更快（摘要）

| 上游卡点 | 本客户端 |
|---|---|
| 每个客户端在 UI 线程 `JSON.parse` 工作区里每个 agent run 的每一帧 | 后台 actor 收帧；字节级前缀扫描判定归属，不关心的帧不解析（每帧 21.3 µs → 2.8 µs）；对打开的任务发送 scope 订阅 |
| 执行日志每 100 ms 全量重建 + 全量脱敏（3000 条约 25 ms/次） | 增量合并，O(批量)，主线程每次 0.024 ms，与日志长度无关；脱敏在入站时于后台一次完成 |
| 列表每行订阅整份任务快照、看板卡片急切挂载弹层 | 每行一个 `@Observable` 模型，事件只使一行失效；`List`（NSTableView 复用）/ `LazyVStack` |
| Markdown / 代码高亮 / Mermaid 在主线程 | Markdown 后台解析 + 缓存，纯 `Text` 渲染 |
| 角标拉全量收件箱、聚焦即重拉执行日志、重复请求 | 单飞合并、只用 unread-summary、重连只补屏上数据 |
| Electron 多进程 + 卡死看门狗 | 单进程原生应用；daemon 健康检查自适应轮询，日志 kqueue 事件驱动 |

## 功能

登录（邮箱验证码 / 浏览器登录深链）· 工作区切换 · Issues 列表与看板（筛选、搜索、拖拽改状态、右键改属性、新建）· Issue 详情（属性编辑、Markdown 描述、评论与活动时间线、发评论含失败重试、agent run 实时摘要与完整执行日志、取消 run）· 收件箱 · Agents / Runtimes · 本机 daemon 启停与日志 · 菜单栏常驻 · 自托管服务器设置 · 诊断面板。

尚未覆盖：Chat、Projects、Autopilots、Squads、Skills、附件、富文本编辑器与 @提及补全等，详见分析文档第 5 节。

## 目录结构

```
Package.swift
Sources/
  MulticaCore/          # 纯 Foundation，可在 Linux 构建与测试
    Models/             # 容错解码的数据模型（缺字段给默认值，未知枚举保留原值）
    Networking/         # APIClient（单飞合并）、ServerConfig、TokenStore
    Realtime/           # WebSocket、FastRouting、FrameRouter、批处理、兴趣登记
    Stores/             # AppModel、WorkspaceSession、IssueStore、IssueDetailModel、TranscriptBuffer、Inbox/Directory
    Daemon/             # profile/端口、DaemonController（CLI + /health）、LogTailer
    Support/            # JSONValue、Redactor、MarkdownCache、Timestamp、Locked
  MulticaApp/           # SwiftUI + AppKit 应用（仅 macOS 声明此目标）
  MulticaBench/         # 性能基准
Tests/MulticaCoreTests/ # XCTest
scripts/bundle-app.sh   # 打包 dist/Multica.app（含 multica:// URL scheme）
```

## 构建与运行（macOS）

```bash
swift build --product MulticaApp        # 调试构建
scripts/bundle-app.sh                   # 生成 dist/Multica.app（ad-hoc 签名）
open dist/Multica.app
```

也可以直接用 Xcode 打开本目录（`Package.swift`），选择 `MulticaApp` scheme 运行。

- 浏览器登录依赖 `multica://` 深链，只有打包后的 `.app` 会注册该 scheme。若同时装了官方 Electron 桌面端，两者都会声明 `multica://`，系统会把链接交给其中一个；这时可以改用邮箱验证码登录。
- 本机 daemon 需要 `multica` CLI（`brew install multica-ai/tap/multica`，或官方桌面端自带的那份）。也可以用环境变量 `MULTICA_CLI_PATH` 指定。daemon profile 与官方桌面端相同（`~/.multica/profiles/desktop-<host>/`），不会碰你在终端里配置的默认 profile。
- 自托管：设置 → Server，填 API 地址和 Web 地址后重启应用。

## 测试与基准

```bash
swift test                              # macOS 或 Linux
swift run -c release multica-bench      # 输出 Markdown 表格
```

CI（`.github/workflows/ci.yml`）在 macOS 上构建应用、跑测试、打包并运行基准，在 Linux 上跑核心测试。

## 验证状态

- 核心库与测试：Linux（Swift 6.1.3）与 macOS 15 / Apple Silicon（GitHub Actions）上 52 个测试全部通过；Linux 上连续 30 次全量运行无失败。
- SwiftUI 应用：在 macOS CI 上编译、链接并打包为 `Multica.app` 通过。尚未在真机上做交互走查。
- 尚未连真实服务器联调（接口取自上游源码）。
