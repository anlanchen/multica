# Multica Native（macOS）

[Multica](https://github.com/multica-ai/multica) 的 Swift 原生 macOS 客户端。它和官方 Electron 桌面端（`apps/desktop` + `packages/views`）连接同一套 REST / WebSocket 接口，Multica Cloud 和自托管服务器都能用；页面、字段、操作、空状态和文案（同一套 i18next 词条）按上游逐页复刻，数据通路针对上游已知的性能卡点重新设计。

- 系统要求：macOS 14 Sonoma 及以上
- 工具链：Xcode 27 / Swift 6.4（`MulticaCore` 用 Swift 6 语言模式和严格并发检查，App 目标用 Swift 5 语言模式）
- 复刻基准：上游 `multica-ai/multica` @ `8a2f518`（2026-10-12）
- 性能卡点分析与设计取舍：[`docs/performance-analysis.md`](docs/performance-analysis.md)；各区实现约定：[`docs/native-app-guide.md`](docs/native-app-guide.md)

## 为什么更快

| 上游卡点 | 本客户端 |
|---|---|
| 渲染进程主线程对每一帧 WebSocket 消息做 `JSON.parse` | 后台 actor 收帧；字节级前缀扫描判定归属，不关心的帧不解析；对打开的任务发送 scope 订阅 |
| 每次刷新执行日志都对整个 run 重新排序、构建步骤 | 增量合并，主线程开销与日志长度无关 |
| 列表每行订阅整份任务快照，看板卡片急切挂载弹层 | 每行一个 `@Observable` 模型，事件只让一行失效；`List` / `LazyVStack` 懒加载 |
| Markdown、代码高亮、Mermaid 在主线程渲染 | Markdown 预处理和解析结果缓存；Mermaid / KaTeX 在一个离屏 WebKit 里画一次并缓存为位图 |
| 重复请求、聚焦即重拉、角标拉全量收件箱 | 相同 GET 单飞合并；角标只用 `unread-summary`；重连只补屏上数据 |
| Electron 多进程 + 卡死看门狗 | 单进程原生应用；daemon 健康检查自适应轮询，日志用 kqueue 事件驱动 |

### 初步实测（同一台 M4 Pro，同一账号和工作区）

| 指标 | 官方 Electron 版 0.6.1 | 本客户端 |
|---|---|---|
| 安装包体积 | 735 MB | 37 MB |
| 常驻进程数（不含 daemon） | 4（主进程、GPU、网络、渲染） | 1 |
| 已登录、打开同一工作区后的物理内存 | 470 → 499 MB（空闲一分钟内增长） | 66.6 MB |
| 线程数 | 108 | 17 |
| 空闲 60 秒 CPU（单核占比） | 6.8% | 待测 |

把上游自己的 JS 代码（用 esbuild 从上游源码打包，跑在 V8 上）和本客户端对应的 Swift 实现放在同一份数据上对比：

| 场景 | 上游（V8） | 本客户端 |
|---|---|---|
| 1 万帧 `task:message`（16 MiB，只看 1 个 run）的去留判定 | 每帧 1.70 µs，全在 UI 线程 | 每帧 0.18 µs，在后台 actor（保留下来的帧再完整解码） |
| 3000 条执行日志时一次刷新（10 条新消息）的主线程开销 | 0.251 ms，随长度线性增长 | 0.012 ms，与长度无关 |
| 500 条评论 Markdown 预处理 + 解析到渲染树 | 每条 735 µs（加上 react-markdown 渲染为 1117 µs） | 每条 387 µs |
| 10 万个 RFC 3339 时间戳解析 | 每个 0.10 µs | 每个 0.03 µs |

这些数字是在机器同时跑多个编译任务时测的，量级可信，绝对值偏噪。完整的性能对比报告（冷启动、空闲 CPU、长 issue 场景、重复测量）会在机器空闲时重测后单独发布。V8 的 `JSON.parse` 本身很快，本客户端在帧处理上的优势主要来自工作不在主线程、不关心的帧根本不解析，而不是解析速度本身。

## 功能

与官方桌面端逐页对应，全部 12 个功能区均已实现：

- **任务（Issues）**：列表、看板、泳道、表格、甘特图；保存视图、全部筛选维度、显示设置、批量操作、侧边预览、拖拽改状态和排序；我的任务；项目 / 成员 / agent / 小队页内嵌的任务列表
- **任务详情**：标题与描述编辑、属性侧栏（含自定义属性、唤醒、PR、产物、执行日志）、子任务、评论线程（解决、编辑、删除、表情回应）、评论框（@提及、`/` 快捷操作和 `/note`、上传、"会启动哪些 agent"预览）、agent run 实时摘要与完整执行日志、⌘F 查找、线程导航条、插件面板
- **新建与关系对话框**：手动 / agent 两种新建模式、草稿、设置父任务、标记重复、添加子任务、删除、运行确认、额度升级；⌘K 搜索面板
- **收件箱**：双栏、筛选、批量归档、已归档视图，右侧内嵌任务详情
- **聊天**：聊天页、可缩放的悬浮聊天窗、实时回复、消息队列、停止并恢复输入、`/` 技能选择
- **Agents**：列表、详情各标签页（说明、技能、环境变量、自定义参数、MCP、集成、活动、设置）、手动创建和 AI 创建流程
- **自动化（Autopilots）**、**Skills**、**项目**、**小队**、**成员**、**运行时**（含本机 daemon 启停、日志查看器、用量图表）
- **设置**：个人资料、偏好、通知、快捷键、API Token、工作区常规、成员与邀请、任务状态、唤醒、标签、属性、快捷操作、代码托管、消息渠道、MCP、计费、插件、本机 daemon、更新，以及原生专属的服务器与诊断页
- **其他**：登录（邮箱验证码 / 浏览器登录）、新手引导全部步骤、邀请、反馈、附件预览（图片、PDF、音视频、CSV、JSON/YAML、代码、HTML）、用量看板、多标签页、独立任务窗口、菜单栏常驻、系统通知、多语言（en / zh-Hans / ja / ko / fr）
- **富文本渲染**：任务和项目提及徽标、`MUL-123` 自动链接、文件卡片、图片预览、Mermaid 图、数学公式、HTML 预览块

### 与官方实现的差异

以下是用原生方式替代、或有意没做的部分：

- 没有自动更新器，"检查更新"打开发布页
- 描述编辑是"双击切换到 Markdown 编辑器"，不是常驻富文本编辑器；引用到回复时引用整条评论（SwiftUI 读不到文本选区）；页内查找按整条评论定位
- 插件的 HTML 界面放在 WKWebView 里，插件 API 由原生代码提供
- 另有少量细节差异（部分悬停卡片改为提示、Mermaid 全屏无导出等），见各模块代码注释

## 目录结构

```
Package.swift
Sources/
  MulticaCore/            纯 Foundation，可在 Linux 构建与测试（约 4.5 万行，含 1.8 万行生成的上游类型）
    Generated/            上游全部 TS API 类型（snake_case JSON ↔ camelCase）
    Networking/           APIClient（单飞合并）与上游 ApiClient 同名的全部接口
    Realtime/             WebSocket、字节级路由、批处理、兴趣登记
    Stores/               WorkspaceSession、IssueStore、各功能区的状态与纯逻辑
    Daemon/               daemon profile、DaemonController（CLI 安装、恢复、健康检查）、日志跟踪
    Support/              Markdown 预处理与解析、权限规则、脱敏、时间戳等
    Resources/Locales/    上游 i18next 词条原样拷贝
  MulticaApp/             SwiftUI + AppKit 应用（仅在 macOS 上声明此目标，206 个文件）
    App/ Shell/ DesignSystem/ Features/<区域>/
    Resources/Web/        Mermaid、KaTeX（MIT，见 THIRD_PARTY_LICENSES.txt）
  MulticaBench/           Swift 侧性能基准
Tests/MulticaCoreTests/   XCTest，411 个用例
scripts/
  bundle-app.sh           打包 dist/Multica.app（strip 本地符号、ad-hoc 签名、注册 multica://）
  perf/                   性能对比工具：probe.swift（进程/内存/CPU/启动时间）、js/（上游 JS 在 V8 上的基准）
```

## 构建与运行

```bash
swift build --product MulticaApp        # 调试构建
VERSION=1.0.0 scripts/bundle-app.sh     # 生成 dist/Multica.app
open dist/Multica.app
```

也可以用 Xcode 直接打开本目录（`Package.swift`），运行 `MulticaApp` scheme。

- 浏览器登录依赖 `multica://` 深链，只有打包后的 `.app` 会注册它。如果同时装了官方桌面端，两者都声明 `multica://`，系统会把链接交给其中一个；这时可以改用邮箱验证码登录。
- 本机 daemon 需要 `multica` CLI（`brew install multica-ai/tap/multica`、官方桌面端自带的那份，或用环境变量 `MULTICA_CLI_PATH` 指定；都没有时会自动下载并校验）。daemon profile 与官方桌面端相同（`~/.multica/profiles/desktop-<host>/`），两个客户端管理的是同一个 daemon，不会碰你在终端里配置的默认 profile。
- 自托管：设置 → 服务器，填 API 地址和 Web 地址后重启应用。
- ad-hoc 签名每次重新打包都会变，重新打包后首次读取钥匙串可能会弹出授权提示。

## 测试与基准

```bash
swift test                                              # 411 个用例，macOS 或 Linux
swift run -c release multica-bench --dump .build/perf/fixtures   # Swift 基准，并导出数据集
cd scripts/perf/js && npm install && node build.mjs && node --expose-gc bench.mjs ../../../.build/perf/fixtures
swiftc -O scripts/perf/probe.swift -o .build/probe      # 进程级测量
.build/probe snapshot /Applications/Multica.app         # 进程、内存、线程
.build/probe idle /Applications/Multica.app 60          # 空闲 CPU
.build/probe launch dist/Multica.app                    # 首个窗口出现的时间
```

JS 基准直接打包上游源码里的实现（`build-timeline` / `build-steps` / `redact`、Markdown 预处理、react-markdown 及同一套 remark/rehype 插件），和 Swift 基准读同一份导出数据，保证逐字节相同的输入。

### 本地走查

用环境变量 `MULTICA_DEBUG_SNAPSHOT_DIR` 启动应用后，可以用深链脚本化地导航和截图（不需要屏幕录制权限，未设置该变量时这些链接不起作用）：

```bash
MULTICA_DEBUG_SNAPSHOT_DIR=$PWD/.build/shots dist/Multica.app/Contents/MacOS/Multica &
open -g -a dist/Multica.app "multica://debug/go?route=issues"
open -g -a dist/Multica.app "multica://debug/go?route=first:issue"
open -g -a dist/Multica.app "multica://debug/snapshot?name=issue-detail"
```

## 验证状态

- **构建与测试**：在 Xcode 27.1（Swift 6.4）下，调试和 release 构建都没有错误和警告，411 个测试全部通过。
- **真实服务器只读走查**：用真实账号连 Multica Cloud，逐个打开了全部 22 个主要路由并截图核对，包括列表页和各类详情页。走查中发现并修复了两个问题：服务器返回的状态分类是七值形式，原先导致看板只显示"已完成"一列；描述里的 HTML 注释被原样显示。
- **还没覆盖**：
  - 写操作流程没有在真实服务器上逐一点过（新建、编辑、评论、拖拽等），这些目前靠单测和代码对照上游来保证。
  - 最终的性能报告还在测。
