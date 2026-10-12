# Multica for macOS — screen implementation guide

The native app re-implements the upstream desktop client
(`apps/desktop` + `packages/views` + `packages/core` in
[multica-ai/multica](https://github.com/multica-ai/multica)) screen for screen.
This guide is the contract every feature area follows.

## Layout

```
Sources/MulticaCore/            platform-independent, unit-tested on Linux
  Networking/Endpoints+*.swift  every upstream ApiClient method, same names
  Generated/UpstreamTypes.swift every upstream TS API type (snake_case JSON ↔ camelCase)
  Models/                       hand-tuned hot models: Issue, Comment, Agent, …
  Stores/                       WorkspaceSession, IssueStore, CollectionStore, …
  Navigation/                   AppRoute, WorkspacePage, TabStore
  Resources/Locales/<lang>/     the upstream i18next catalogs, verbatim
Sources/MulticaApp/
  App/                          entry point, AppEnvironment, menu bar extra
  Shell/                        sidebar, tab bar, route host, modals, toasts, shortcuts
  DesignSystem/                 tokens and shared components (see below)
  Features/<Area>/              one folder per upstream area
```

## What a page can use

```swift
@Environment(WorkspaceSession.self) private var session // api, stores, directory
@Environment(Navigator.self) private var nav            // tabs/history
@Environment(AppEnvironment.self) private var env       // account, daemon, prefs
@Environment(ModalCenter.self) private var modals       // app-wide dialogs
@Environment(Toaster.self) private var toaster          // toasts
@Environment(ShellState.self) private var shell        // search/chat/right panel
@Environment(ShortcutStore.self) private var shortcuts
```

- **API**: `try await session.api.<upstreamMethodName>(…)`. Every method of
  upstream `packages/core/api/client.ts` exists with the same name; look up
  the exact Swift signature with
  `grep -n "func listProjects" Sources/MulticaCore/Networking/*.swift`.
- **Types**: upstream `Project` is `Project`, fields are camelCase
  (`issue_count` → `issueCount`). Check every field you read:
  `grep -n "public struct Project:" -A30 Sources/MulticaCore/Generated/UpstreamTypes.swift`.
  Generated structs have a memberwise `init` with defaults for every field.
  Hand-written models (Issue, Comment, Agent, Member, User, Workspace,
  TaskMessage, InboxItem, IssueStatusEntry, IssueLabel, IssueView) live in
  `Models/`; the full upstream shapes of those exist as `*Record`
  (`AgentRecord`, `IssueRecord`, `MemberWithUserRecord`, …).
- **Live catalogs** (load on first use, kept current by realtime):
  `session.projects`, `.squads`, `.skills`, `.autopilots`, `.pins`,
  `.labels`, `.properties`, `.quickActions`, `.chatSessions`,
  `.agentRecords`, `.memberRecords`, `.runtimeRecords`,
  `.issueStatusEntries` — all `CollectionStore<T>`:
  `await store.loadIfNeeded()`, `store.items`, `store.item(id)`,
  `store.upsert(x)`, `store.remove(id)`, `await store.load()`.
  Issues: `session.issues` (`IssueStore`, per-row `IssueModel`), issue
  detail: `session.openIssue(id)` / `closeIssue(id)`. Names/avatars:
  `session.directory`, `session.actorInfo(type:id:)`.
- **Realtime for detail-only data**: events without a typed case bump
  `session.revision("<prefix>")` (e.g. `"pull_request"`, `"subscriber"`,
  `"autopilot"`, `"runtime"`, `"skill"`, `"chat"`). Refetch with
  `.task(id: session.revision("autopilot")) { … }`.
- **Strings**: `tr("<namespace>", "<dotted.key>", ["count": n, "name": x])`
  — the same keys as upstream `t(($) => $.dotted.key)`. Namespaces are the
  file names in `Resources/Locales/en`. Never hard-code English when a key
  exists; plurals pick `_one`/`_other` from `count`.
- **Navigation**: `nav.push(.project(id))`, `nav.openInNewTab(…)`,
  `nav.setQuery("view", id)`, `nav.query("session")`, and
  `.tabTitle(entity.name)` on detail pages. ⌘-click opens a new tab.
- **Dialogs**: `modals.present(.createProject)` for registry dialogs,
  `modals.createIssue(draft)`; anything area-local uses `.sheet`/`.alert`.
- **Errors**: `toaster.error(error)`; success: `toaster.success(…)`.

## Design system (DesignSystem/)

`Theme` (colors, radii, fonts), `Formatters` (relative time, dates, bytes,
durations, money), `StatusIcon`, `PriorityIcon`, `AvatarView`,
`ActorAvatar`, `WorkspaceAvatar`, `RemoteImage`, `PageHeader`, `PageTitle`,
`Breadcrumb`, `EmptyStateView`, `LoadingView`, `ErrorStateView`, `KeyCaps`,
`PillButtonStyle`, `HoverRowButtonStyle`, `SegmentedToggle`, `PropRow`,
`SearchField`, `SectionCard`, `StatusDot`, `Badge`, `LabelChip`,
`CopyButton`, `CodeLine`, `RelativeTime`, `ProgressBar`, `ProgressRing`,
`MarkdownView`, `ExpandableMarkdown`, `CodeBlockView`, `MarkdownEditor`
(NSTextView: ⌘↩ submit, paste/drop files, @-mentions via
`session.mentionCandidates`), `OptionList`, `PopoverButton`,
`StatusPicker`, `PriorityPicker`, `AssigneePicker`, `LabelPicker`,
`ProjectPicker`, `ProjectIconView`, `DateOnlyPicker`, `RunningIndicator`,
`TaskStatusPill`.

## Rules

1. Target macOS 14 SwiftUI/AppKit only (no macOS 15 APIs such as the
   `Tab` struct, `onScrollGeometryChange`, `@Entry`). The app target builds
   in Swift 5 language mode.
2. Keep helper types `private` or prefix them with the area name — the app
   is one module and duplicate type names do not compile.
3. Lists that can grow use `List`/`LazyVStack`; no network or heavy work in
   `body`.
4. Match upstream behaviour first (fields, actions, empty states, copy),
   then look native.
