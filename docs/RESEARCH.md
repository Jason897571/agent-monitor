# 调研纪要

> 2026-09-23 · 8 路并行调研 + 5 项对抗式验证 + 完整性批判，约 190 万 token
> 本文是 [DESIGN.md](../DESIGN.md) 结论的证据。标注 **[实测]** 的是在本机跑出来的，不是查来的。
>
> 原稿另有一节是对某个闭源竞品的应用包拆解，刻意不放进本仓库——它对本项目的实现没有
> 指导价值（我们走的是零 hook 被动路线，与其架构相反），而放进一个公开的同品类仓库
> 并不合适。下面保留的是平台接口实测和竞品格局，那才是真正决定怎么写代码的部分。

环境：macOS 26.2 (25C56) · Apple Silicon · Claude Code 2.1.220 · codex-cli 0.154.0-alpha.6.2 · `CLAUDE_CONFIG_DIR=~/.claude-official`

---

## 1. Claude Code 接口实测

### 1.1 会话注册表（最重要的发现，完全无文档）

```
$CLAUDE_CONFIG_DIR/sessions/<pid>.json
```

**[实测]** 全部 15 个文件的键并集：`bridgeSessionId` `cwd` `entrypoint` `kind` `name` `nameSource` `peerProtocol` `pid` `procStart` `sessionId` `startedAt` `status` `statusUpdatedAt` `updatedAt` `version` `waitingFor`

**[实测]** 从二进制里挖出的状态枚举和写入逻辑：

```js
IO_ = ["busy","shell","idle","waiting"]
function DO_(e){ return IO_.includes(e) ? e : void 0 }
async function LYn(e){
  let t = Date.now();
  await rxt({ ...e, updatedAt: t, ...(e.status !== void 0 && { statusUpdatedAt: t }) })
}
```

→ `statusUpdatedAt` 只在状态真正变化时推进，正是升级计时器需要的。

**[实测] 陷阱**：文件没有心跳。一个活跃工作中的会话，16 秒内采样 5 次，`updatedAt` 和 `statusUpdatedAt` **冻结在 42 分钟前**。所以「陈旧 = 死亡」的推断是错的。15 个文件全部对应活进程（幽灵率 0/15），但 mtime 最老的有 13 天，状态全是 `idle`——**是健康的空闲会话**。一个会话已经连续跑了 42 天 17 小时。

唯一可靠的存活判定 = `kill(pid,0)` **且** `ps -o args=` 含 `claude`（要容忍 `--dangerously-skip-permissions --resume <id>` 这类参数）**且** 正确的 `procStart` 比对。

**[实测] 时区炸弹**：`53867.json` 里 `procStart: "Tue Aug 11 16:49:52 2026"`，而 `ps -o lstart= -p 53867` 打印 `Tue Aug 11 12:49:52 2026`。机器在 EDT (UTC-4)。**JSON 里是 UTC，ps 是本地时间。** 直接比字符串会在 UTC 以外的所有时区把每个活会话判成幽灵，而在 UTC 开发的作者永远测不出来。

### 1.2 Hook：33 个事件，不是 9 个

**[实测]** 二进制里的主数组（31 个，`PreModelSwitch`/`PostModelSwitch` 比这个 build 新）：

```js
cB = ["PreToolUse","PostToolUse","PostToolUseFailure","PostToolBatch","Notification",
      "UserPromptSubmit","UserPromptExpansion","SessionStart","SessionEnd","Stop","StopFailure",
      "SubagentStart","SubagentStop","PreCompact","PostCompact","PermissionRequest",
      "PermissionDenied","Setup","TeammateIdle","TaskCreated","TaskCompleted","Elicitation",
      "ElicitationResult","ConfigChange","WorktreeCreate","WorktreeRemove","InstructionsLoaded",
      "CwdChanged","FileChanged","DirectoryAdded","MessageDisplay"]
```

**没人用的四组**：`TeammateIdle` / `TaskCreated` + `TaskCompleted` / `WorktreeCreate` + `WorktreeRemove` / `FileChanged` + `CwdChanged`。最完整的开源集成 clawd-conduit 只接了 15 个，这些一个没碰。

**[实测]** `PreToolUse` 真实 stdin（注意 `prompt_id` 和 `effort`，绝大多数第三方文章里没有）：

```json
{
  "session_id": "93f13aeb-392c-4154-a954-fff26a191e2c",
  "transcript_path": "/Users/jason/.claude-official/projects/…/93f13aeb-….jsonl",
  "cwd": "/private/tmp/…/hooktest",
  "prompt_id": "69c846f2-dae8-413c-82a4-40e29e0b610d",
  "permission_mode": "default",
  "effort": { "level": "xhigh" },
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "echo HELLO_FROM_BASH", "description": "Echo a test string" },
  "tool_use_id": "toolu_01J3LPEk697991gCStCqP2Tc"
}
```

**[实测]** hook 子进程环境：`tty = not a tty`（无控制终端），ppid = claude 的 pid，环境里有 `CLAUDE_PROJECT_DIR`、`CLAUDE_PID`、`CLAUDE_CODE_SESSION_ID`、`CLAUDECODE=1`、`CLAUDE_CONFIG_DIR`，以及从终端继承来的 `__CFBundleIdentifier=com.mitchellh.ghostty`。

**[实测]** 从 hook 里（没有 tty）跑 `osascript -e 'display dialog … giving up after 8'` **成功弹出了真实原生对话框**，阻塞 8 秒后返回，映射成 `deny` 并被 Claude Code 采纳。**→ GUI 审批从 hook 直达 WindowServer，无需任何 TCC 授权。**

### 1.3 阻塞式 GUI 审批 — 实测结论

| 实验 | 结果 |
|---|---|
| 25 秒阻塞 + `deny`（headless） | 墙钟 39 秒，`permission_denials` 有记录，工具未执行 ✅ |
| 45 秒阻塞 + `allow`，需授权的 `curl` | 返回 `200`，`DENIALS: []`，`duration_ms` 50664 ✅ |
| 40 秒阻塞 + `allow`，**真实交互式 pty** | 56.1 秒时出现 `⏺200`，原始 pty 流里 **"Do you want" 从未出现**，原生提示被完全抑制 ✅ |

**[实测] 默认超时是 600 秒，不是 60。** 二进制常量 `xm=600000`，逐 hook 计算 `e.timeout ? e.timeout*1000 : i`。不写 `timeout` 字段时，一个 sleep 95 秒的 hook 仍然正常返回且 `deny` 被采纳（墙钟 109 秒）。

**`permissionDecision` 有四个值不是三个**：`"Unknown hook permissionDecision type: . Valid types are: allow, deny, ask, defer"`。`defer` 仅 print 模式有效，交互模式下会打日志忽略。

**fail-open 清单（实测）**：

| 场景 | 实测结果 |
|---|---|
| hook 超时 | **不阻塞**。走正常权限流程；在 `--dangerously-skip-permissions` 下**工具直接执行**，零拒绝记录 |
| hook 脚本 `chmod -x` | **工具照跑**，`permission_denials: []`，守卫静默失效（bug #94362 开放） |
| `hookEventName` 写错 | `Hook returned incorrect event name: expected 'X' but got 'Y'` → 解析失败 → 非阻塞错误 → 放行 |
| `ask` 在 headless | 静默转成拒绝（bug #95726 开放） |
| `auto` 模式下 hook `allow` | 可能被 Bash 分类器推翻（bug #94740 开放） |

**fail-closed 的只有两个**：`deny` 能盖过 `bypassPermissions`（实测：`--dangerously-skip-permissions` + hook deny → curl 被拦）；`exit 2` 无条件阻塞，连之后的 `allow` 都盖不过去。

这条代码路径**至少回归过四次**（#28812 / #52822 / #18312 / #37210）。要锁版本 + CI 冒烟测试。

### 1.4 Hook 成本量化

**[实测]** 40 次迭代，热态：

```
/bin/sh 空 hook (cat >/dev/null; exit 0):  min 3.6ms  p50 4.3ms  p95 8.6ms
node 空 hook (读 stdin, 退出):             min 21.7ms p50 24.3ms         → 5.6×
```

**[实测]** 真实负载（672 次工具调用的会话分析）：活跃时 **3.03 次工具调用/分钟，60 秒窗口峰值 14 次**。

`PreToolUse` + `PostToolUse` = 每次工具调用 2 次进程创建：

| 场景 | 开销 |
|---|---|
| 单会话峰值，node hook | 28 次/分 × 24.3ms = **1.13% 单核**，什么都没干 |
| 8 个并发 agent，node hook | **9.1% 单核** |
| 同样负载，`/bin/sh` hook | 1.6% 单核 |

**→ 这是选 `type: "http"` hook 或编译型中继、而不是 Node 垫片的硬论据。**

### 1.5 Hook 热加载（推翻了「首次体验悬崖」）

**[实测]** 对一个已运行 1 小时的会话，向其 live `settings.json` 注入 `PostToolUse` hook：

```
1790158675.510  settings.json 写入
1790158680.458  下一次 Bash 工具调用开始
1790158681.500  HOOK 触发        ← 写入后 5.99 秒，未重启
1790158689.329  第二次触发，每次工具调用恰好一次，无重复
```

（settings 已还原并与备份逐字节比对通过。）

→ 现有工具普遍在装完 hook 后提示"请重启正在运行的会话"，实测表明这一步是多余的——可以拿来做更好的首次体验。**Codex 可能仍需重启，因为它的信任哈希覆盖命令字符串。**

### 1.6 transcript 与其它磁盘信号

**[实测]** 本机约 400 个 transcript 的行类型统计：
`assistant` 19713 · `user` 11903 · `attachment` 7711 · `last-prompt` 2290 · `mode` 1861 · `ai-title` 1751 · `permission-mode` 1501 · `system` 1062 · `bridge-session` 897 · `file-history-snapshot` 702 · `queue-operation` 474

**`type:"summary"` 行：0 条。** `~/.claude/todos/`：不存在（官方文档列为 legacy，已不再写入）。这两个东西出现在几乎所有第三方文章里。

`system` 的子类型：`turn_duration` 573 · `away_summary` 284 · `local_command` 24 · `compact_boundary` 1

**[实测]** slug 的有损规则：在名为 `slug.test_dir 中文 v1.2` 的目录里跑 `claude -p`，生成的项目目录是 `…-scratchpad-slug-test-dir----v1-2`。每个非 `[A-Za-z0-9-]` 字符各变一个 `-`，每个 CJK 码点也是一个 `-`。**不可逆。**

**[实测]** IDE lock 文件——文件名就是 localhost WebSocket 端口，`lsof` 交叉验证 6 个全部在 LISTEN：

```json
{"pid":53990,"workspaceFolders":["/Users/you/Projects/example-app"],
 "ideName":"Cursor","transport":"ws","runningInWindows":false,
 "authToken":"<redacted — a real one was observed here>"}
```

`authToken` 是凭据（能访问编辑器的 MCP），不要记日志。

**[实测]** 文件监听成本：`~/.claude-official/projects/` 是 **482MB / 1005 个文件**。5 分钟内有 6 个文件被改，60 分钟内 121 个。热点不在你以为的地方：

```
29  projects/<proj>/<session>/subagents/workflows/…
16  projects/-private-tmp-claude-501-…/     ← 临时目录也有自己的 project slug
 7  projects/<proj>/<session>/tool-results/
```

→ 递归监听必须按路径过滤，否则会被溢出文件不停唤醒。而且 UI 里会冒出临时目录的垃圾条目。

**[实测]** 活跃工作中 transcript **6 秒内增长 0 字节**（237,414 → 237,414）——批量写入，实时信号价值为零。

### 1.7 额度数据的合规边界

Anthropic 法律条款（`code.claude.com/docs/en/legal-and-compliance`，"Authentication and credential use"）：

> "developers may not **collect, store, or intermediate** Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."
> "Anthropic reserves the right to take measures to enforce these restrictions and may do so without prior notice."

**[实测]** Keychain 里其实有**两个**条目，后缀是配置目录的哈希：

```
"Claude Code-credentials"
"Claude Code-credentials-6c1ccaca"

sha256("/Users/jason/.claude-official").hexdigest()[:8] == "6c1ccaca"   ✅ 已验证
```

| 条目 | expiresAt | 状态 |
|---|---|---|
| `Claude Code-credentials` | 2026-06-13 | **已过期 102 天** |
| `Claude Code-credentials-6c1ccaca` | 2026-09-23 09:52 | 有效（且多一个 `refreshTokenExpiresAt` 字段） |

任何按固定名字 `Claude Code-credentials` 去读的工具，在本机都会拿到一个三个月前就过期的 token，解析失败后回落显示别的厂商的陈旧额度。**这正是 Vibe Island 那一串额度归属错误 issue（#222 / #224 / #226 / #233）的真实成因**——公开讨论里把它归因于 `claude setup-token`，但范围广得多：**任何设置了非默认 `CLAUDE_CONFIG_DIR` 的用户**都会中招，恰恰就是会用多 agent 监视器的那批重度用户。

（多出来的 `refreshTokenExpiresAt` 字段还说明凭据的 schema 在不同写入之间会漂移，固定解析器早晚会坏。）

**[实测]** `grep -l 'five_hour'` 扫遍 `~/.claude-official/projects/` 全部 1005 个文件 → **0 个结果**。限额数据只经由 statusLine 下发。

**[实测]** `statusLine` / `subagentStatusLine` / `fileSuggestion` / `outputStyle` 在二进制里都是标量键，不像 `hooks` 那样跨层级 merge。本机的 `statusLine.command` 是一段 700 字符的 bash，解析最新版 claude-hud 插件后 `exec bun`。覆盖 = 砸掉用户的 HUD。

**合规的替代品**：`~/.claude/stats-cache.json`（`version: 4`）是 `/usage` 的后备存储，含 `dailyActivity[{date,messageCount,sessionCount,toolCallCount}]`、`dailyModelTokens`、按模型的 `modelUsage`、`totalSessions`、`longestSession`、`hourCounts`，**不碰任何凭据**，而且不在清理范围内。

---

## 2. Codex 接口实测

**推翻了「Codex 只能只读」的判断。** 三个外部接口，后两个都能审批：

### 2.1 `notify` —— 确实是单向的，但也别碰它

`codex-rs/hooks/src/legacy_notify.rs` 里三个 stdio 全是 `Stdio::null()` 然后 `spawn()`，exit code 和 stdout 从不读取。`type` 只有一个值 `"agent-turn-complete"`。

**[实测]** 本机 `~/.codex/config.toml` 第 1 行：

```toml
notify = ["/Users/jason/.codex/computer-use/…/SkyComputerUseClient", "turn-ended"]
```

→ **槽位已被 ChatGPT.app 自己的 Computer Use 占用**，且是标量键。写它 = 静默搞坏用户功能。用 `Stop` hook（数组可追加）。

### 2.2 生命周期 Hook —— 12 个事件，能 deny

`SessionStart` `SessionEnd` `SubagentStart` `SubagentStop` `PreToolUse` `PostToolUse` `PermissionRequest` `PreCompact` `PostCompact` `UserPromptSubmit` `Stop` `Interrupt`

配置位置：`~/.codex/hooks.json`、`~/.codex/config.toml` 的 `[[hooks.PreToolUse]]`、仓库级同名文件、插件层、managed 层（`requirements.toml`）。

**[实测]** 通过 app-server 查询一个真实运行中的 Codex 进程的 hook 注册表：

```json
{"key":"…:pre_tool_use:0:0","eventName":"preToolUse","handlerType":"command",
 "command":"/bin/true","matcher":"^Bash$","timeoutSec":600,
 "currentHash":"sha256:4521df1f…","trustStatus":"untrusted"}
```

→ 默认超时 600 秒；新 hook 落地是 `untrusted`，要用户跑 `/hooks` 确认一次；**信任哈希覆盖命令字符串**，升级时必须字节级不变。

### 2.3 app-server JSON-RPC —— GUI 监视器的正确答案

```
codex app-server --listen stdio:// | unix:// | unix://PATH | ws://IP:PORT
```

**[实测]** `codex app-server generate-json-schema --out ./schema` 生成 40 个文件，包括 `CommandExecutionRequestApprovalParams/Response.json`、`FileChangeRequestApprovalParams/Response.json`、`PermissionsRequestApprovalParams/Response.json`。**存在带 `decision` 必填字段的 *Response* schema，本身就证明审批是往返的。**

**[实测]** 真实跑通 `initialize`：

```json
{"id":1,"result":{"userAgent":"…/0.154.0-alpha.6.2 (Mac OS 26.2.0; arm64)",
 "codexHome":"/Users/jason/.codex","platformOs":"macos"}}
```
后面还跟了一条未请求的推送 `remoteControl/status/changed`——双向通道确认。

99 个客户端请求方法 + 81 个服务端通知 + 10 个需要回复的服务端请求。协议标 `[experimental]`，要用 `generate-json-schema` / `generate-ts` 在 CI 里锁版本，让 Codex 升级**导致构建失败**而不是悄悄弄坏审批。

**[实测] 打包注意**：本机 `codex` **不在 PATH 上**，在 `/Applications/ChatGPT.app/Contents/Resources/codex`。

---

## 3. macOS 窗口层实测

用 Swift 写了一个真实的 AppKit 全屏 Space（`toggleFullScreen(nil)` + 每帧 `NSApp.activate`），再用 `CGWindowListCopyWindowInfo` 逐帧比对 z-order，最后用 `screencapture` + `NSBitmapImageRep` 直方图做像素验证。

### 3.1 collectionBehavior：只有一个 flag 在起作用

**[实测]** 全部 level 1000、borderless + nonactivatingPanel，对着别人的原生全屏窗口，连续 8 次采样结果一致：

```
cb = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary] (273) → idx 0，在全屏窗口之上 ✅
cb = [.fullScreenAuxiliary] 单独 (256)                          → 完全不在屏幕窗口列表里 ❌
cb = [] (0)                                                      → 不在列表里 ❌
cb = [.managed] @level 0 (4)                                     → 不在列表里 ❌
```

→ **`.fullScreenAuxiliary` 对跨应用全屏贡献为零。** 本机 SDK 头文件 `NSWindow.h:118` 原文："Windows with this collection behavior can be shown with **the** fullscreen window" —— 指你自己 app 的。它另一个作用（`NSWindow.h:546`）是让 `toggleFullScreen:` 能作用于该面板，这是你不想要的。

真正该加的是 macOS 13+ 的 `.canJoinAllApplications` (1<<18)，`NSWindow.h:98` 原文："commonly be used for floating windows and **system overlays**"。注意它与 `.primary`/`.auxiliary` 互斥。

### 3.2 level：1000 是错的

**[实测]** 三个面板同时对着全屏窗口，像素直方图：

```
size 800x240
  r-g-b(tenths)=9-3-9 count=3600   ← 品红面板，level 3    在全屏之上
  r-g-b(tenths)=5-9-9 count=3600   ← 青色面板，level 25   在全屏之上
  r-g-b(tenths)=9-9-3 count=3600   ← 黄色面板，level 1000 在全屏之上
  r-g-b(tenths)=2-5-2 count=1200   ← 中间露出的全屏 app 背景
```

**三个 level 全都浮在上面。** 而 1000 会盖住：右键菜单(101)、菜单栏(24)、控制中心(25)、帮助(200)、拖拽预览(500)。**用 25–27。**

**[实测]** 硬天花板：`CGShieldingWindowLevel() = 2147483628`。shield 层窗口 idx 0，level-1000 的宠物 idx 1，盖不过去。覆盖：display-capture 游戏、屏保、macOS 截图 UI、屏幕共享、登录窗口。认了。

### 3.3 NSPanel 默认值的坑

**[实测]**

```
[borderless + nonactivatingPanel]  hidesOnDeactivate = false  ✅ 安全
[titled + utilityWindow  NSPanel]  hidesOnDeactivate = TRUE   ❌ app 不在前台就消失
```

对宠物来说 app **永远**不在前台，所以换成 utility/titled 面板 = 宠物永久消失。

### 3.4 线上失败案例（「可靠」被证伪）

- `live-football-transcriber#33` —— cb 0x151、level 1000、macOS 26 / PyQt6+PyObjC，覆盖层仍停在桌面 Space。疑因 app 用了 `.regular` 激活策略 + Qt 重建原生 NSWindow 后静默还原了 collectionBehavior
- `tauri#11488` —— macOS 15.0.1，`visibleOnAllWorkspaces` 不生效，**关闭为 not planned**。唯一有效解是 `ActivationPolicy::Accessory`（代价是 Dock 图标消失）
- `tauri#5566` —— `setLevel_` / `setCollectionBehavior_` 在开发环境正常，**打包后失效**
- Apple 开发者论坛 759780（2024-07）—— NSWindow + ScreenSaver level + CanJoinAllSpaces|CanJoinAllApplications，"当其它 App 进入全屏，覆盖层消失"。**零回复**

**共同点**：全部可追溯到 NSWindow 被重建或被框架覆写。
→ **level 和 collectionBehavior 必须反复重申 + 看门狗自检**，这比任何 flag 组合都值钱。

### 3.5 透明窗口命中测试回归

Apple 开发者论坛 814798：

> "On 26.3 RC, mouse events are intercepted by **the entire transparent window** rather than only the opaque regions. As a result, any third-party app that uses full-screen overlay windows blocks system interactions."

Apple 框架工程师已确认收到多份报告。26.3 正式版修了，据报 26.4 beta 又回来了。

**缓解**：窗口尺寸贴着精灵图外接框 + 阴影余量，移动**窗口**而不是移动大窗口里的精灵。这样即使 alpha 命中测试完全失效，代价也只是 200×200 的死区而不是整块屏幕。并且从第一天就写显式命中掩码（降采样 alpha 位图 + 全局 `.mouseMoved` 监听切换 `ignoresMouseEvents`），把窗口服务器的 alpha 测试降格为优化而非正确性依赖。

> 注：**鼠标移动/按下**的全局监听**不需要** Accessibility；只有**键盘**相关的才需要。

### 3.6 Tauri 被实测打穿

| 能力 | 结论 |
|---|---|
| 透明 | ⚠️ 靠**私有 API**（wry 设置未公开的 KVC 键 `drawsBackground`）。Tauri 自己的文档写着："Using private APIs on macOS **prevents your application from being accepted to the App Store**" |
| 置顶 | ⚠️ **封顶在 NSFloatingWindowLevel (3)**。`tao` 源码 L1389 只在 floating/normal 之间选，JS API 是个裸 boolean，**没有 level 旋钮** |
| 全部 Space | ✅ 但只 OR 进 `CanJoinAllSpaces` 一个 flag。`FullScreenAuxiliary` 在 tao 的 1791 行 macOS window.rs 里出现 **0 次** |
| 浮于别人全屏之上 | ❌ **证伪**。#11488 和 #11791 都 closed as not planned |
| 点击穿透 + 转发 | ❌ **证伪**。`setIgnoreCursorEvents` → `setIgnoresMouseEvents`，AppKit 层面是全有或全无。**[实测]** 用 Swift 复刻 Tauri 的确切配置，JS 里挂 mousemove 计数器：`ignoresMouseEvents=true` 时光标疯狂移动 8 秒，webview 收到 **0 个事件**；设回 false 立刻 `mousemove#1`、`heartbeat n=18`。Electron **有**这个能力（`setIgnoreMouseEvents(true, {forward: true})`），tauri#6164 开着没实现 |
| 空闲内存 <150MB | ⚠️ 误导。**[实测]** 一个比 Tauri 更轻的 Swift+WKWebView 宿主：静态页 ~54MB；**512×512 画布 8 帧精灵 60fps 的"宠物"跑 75 秒后 ~129MB**（WebKit.GPU 从 10MB 涨到 **77MB**），CPU 约 10% 单核，而画的只是个弹跳圆球。本机真实 Tauri app（Clash Verge 2.4.7）**webview 窗口关闭状态下** RSS 就 33.6MB |

→ **透明、可穿透、浮于全屏之上的 Tauri 宠物，要么做不到，要么得自己写 objc2**。选 Swift 是对的。

### 3.7 能耗基线

**[实测]** OpenUsage.app（已上架的原生 Swift 菜单栏监视器）：

```
pid 38448  RSS 42 MB  运行 2天06:26:22 (195,982s)  累计 CPU 10:09.09 (609.1s)
=> 0.31% 单核，持续平均
15 秒点采样: 0.04s CPU => 0.27%   (一致，无空闲尖峰)
```

**42MB / 0.3% 单核 = 不带动画的原生监视器在这台硬件上的经验地板。**

免费且无需授权的省电闸门（本机 SDK `NSProcessInfo.h` 确认）：`thermalState`（198–215 行）、`isLowPowerModeEnabled`、`beginActivityWithOptions:reason:`（171 行）。

> ⚠️ `powermetrics` 需要 sudo，调研环境拿不到，**能耗问题在形式上仍未关闭**。这是选渲染栈前必须自己跑一次的实验。

### 3.8 顺手捡到的两个东西

**[实测]** Focus / 勿扰状态无需任何权限即可读：`~/Library/DoNotDisturb/DB/Assertions.json`，`data[].storeAssertionRecords[]` 非空 = 当前有 Focus 开启，`assertionDetailsModeIdentifier` 说明是哪个。时间戳是 Apple 绝对时间（2001-01-01 起算）。
（待验证：从一个没有 FDA 的真实 .app 里读是否也可以——调研是在终端里读的，可能继承了终端的 FDA。）

**[实测]** macOS 26 Tahoe 的菜单栏 API 变得不可靠：`NSStatusItem.isVisible` "即使图标被刘海遮住或被菜单标题挤出屏幕也可能返回 true"，而且新增了系统设置里的 "Allow in Menu Bar" 用户级开关。
→ **宠物面板（你自己定位）是比状态栏更可靠的地盘**；`NSStatusItem` 只留给设置和退出，不要做成唯一入口。

---

## 4. 终端跳转实测

### 4.1 读环境变量这条路基本是死的

**[实测]** 门禁不是 root，是目标进程的 `cs_restricted`。XNU `bsd/kern/kern_sysctl.c :: sysctl_procargsx`：

```c
#define SYSCTL_PROCARGS_READ_ENVVARS_ENTITLEMENT "com.apple.private.read-environment-variables"
bool omit_env_vars = true;
if (p == current_proc() || !cs_restricted(p) ||
    csr_check(CSR_ALLOW_UNRESTRICTED_DTRACE) == 0 ||
    IOCurrentTaskHasEntitlement(SYSCTL_PROCARGS_READ_ENVVARS_ENTITLEMENT)) {
        omit_env_vars = false;
}
```

**注意这个列表里没有 euid == 0。`sudo ps eww` 绕不过去。** `/bin/ps` 虽然是 setuid root，但它没有 `com.apple.private.read-environment-variables` 这个 entitlement。

**[实测]** 用自己写的 C 程序调 `sysctl(KERN_PROCARGS2)` 测出来的矩阵：

```
/bin/bash 脚本   → 150 字节, 环境变量 0 个 ❌
/bin/sleep 600   →  35 字节, 环境变量 0 个 ❌
/bin/zsh -c …    →  30 字节, 环境变量 0 个 ❌
自编译的 sleeper → 3636 字节, 57 个 ✅
/opt/homebrew/bin/node → 3468 字节, 57 个 ✅
```

→ **父登录 shell 的环境变量永远读不到。**「agent 环境为空就去读它的 shell」这个 fallback 从根上死掉。
→ 而且失败是**静默截断**（返回成功 + 短字节数），不是 EPERM。**要靠数变量个数来检测，不是靠返回码。**

### 4.2 而且读到了也没用

**[实测]** 本机 7 个 `claude` 进程，全部检查：**没有一个**带 `ITERM_SESSION_ID` / `TMUX_PANE` / `WEZTERM_PANE` / `TERM_SESSION_ID` / `WINDOWID`。没装 iTerm2、WezTerm、kitty，`pgrep tmux` 无结果。4 个跑在 Ghostty 下，3 个在 VS Code/Cursor 下。

Ghostty 1.3.1 只导出 `GHOSTTY_RESOURCES_DIR` / `GHOSTTY_BIN_DIR` / `GHOSTTY_SHELL_FEATURES` / `TERMINFO`，在 pid 22269/35066/56859/6332 上**逐字节相同**——零区分度。`GHOSTTY_SESSION_ID` + `ghostty:///focus-session/` URL scheme 目前只是提案（discussion #10603、#9084），1.3.1 里没有。

**[实测]** 唯一能唯一标识每个 agent 的是控制终端 tty，而且不需要读环境变量：`ps -o pid=,tty=,command= -ax` 直接给出 ttys035/044/063/077/082/091/096。

`ps(1)` man page 自己的警告：`-E  Display the environment as well. **This does not reflect changes in the environment after process launch.**` —— 是 exec 时刻的快照，pane 移动后静默失效。

### 4.3 正确做法：注入而非提取

在 hook 触发的那一刻，它继承了 agent 的完整环境。此时读 `$CLAUDE_PID`（Claude Code 会导出）、`ps -o tty= -p $CLAUDE_PID` 拿 tty，把 `ITERM_SESSION_ID` / `TMUX` / `TMUX_PANE` / `WEZTERM_PANE` / `KITTY_WINDOW_ID` / `KITTY_LISTEN_ON` / `ZELLIJ_*` / `TERM_PROGRAM` / `__CFBundleIdentifier` 一起快照进以 session_id 为键的 sidecar JSON。

sidecar 严格优于环境变量：它不是 exec 时刻快照，pane 移动时可以刷新。

**祖先链方案会怎么崩**：走 hook 进程的祖先链向上找终端和 tty，是现有工具的通行做法，也是 Vibe Island issue #166 记录的失败点——Claude Code 把引擎移进 daemon（`claude daemon run` / `--bg-pty-host`）之后，祖先链终止于 launchd，再也看不到终端，点击变成静默 no-op。sidecar 方案不受影响，因为身份是在 hook 触发的那一刻抓的。

### 4.4 一个可占的空子

Ghostty 是增长最快的现代 macOS 终端，且没有 per-pane 环境变量，所有人（包括 Vibe Island 自己的说明）都退化到模糊 cwd 匹配。

**OSC-2 标题探针**：hook 触发时往捕获到的 tty 写 `\x1b]2;<token>\x07`，用 AppleScript 枚举 `every terminal of every window` 匹配 `name contains token`，缓存 surface UUID 对应 session_id，然后恢复原标题。在 SessionStart 缓存一次，而不是每次点击都探。**这能把 Ghostty 从 Tier 3 提到 Tier 1。**

kitty 还有个别人没用的精确键：`kitten @ focus-window --match env:CLAUDE_CODE_SESSION_ID=<uuid>`——Claude Code 本来就把这个变量导给子进程。但要做能力探测，因为 `allow_remote_control` 默认是关的。

### 4.5 已知会失败的情况（要在 UI 上明说，不要静默失败）

`--bg`/`--background` 启动、LaunchAgent 启动、SSH 会话 → `e_tdev == UInt32.max`，**没有控制终端，没有窗口可跳**。远程会话最好的提议是复制 `ssh host -t 'cd dir && claude --resume <id>'`；后台 agent 提供「在这里恢复」（开个新本地标签页）而不是假装能跳。

Cursor 的 bundle id 是 `com.todesktop.230313mzl4w4u92`，**不是** `com.microsoft.VSCode`——clawd 在这里有个静默 no-op 的 bug。

---

## 5. 竞品全景

### 5.1 一方功能（最大的威胁）

**OpenAI Codex Pets** —— **[实测]** 本机 `~/.codex/.codex-global-state.json`（71KB）里确认存在：`electron-persisted-atom-state.first-awake-pet-notification-avatar-ids: ["codex"]`，以及完整的浮窗位置持久化树 `electron-avatar-overlay-bounds.{x,y,displayId,placement,isFreelyPositioned}`、`.byDisplayId.1.*`、`.byResolution.1512x982.*`。

> `byResolution` + `byDisplayId` 双键说明 OpenAI 已经解决了多显示器宠物位置持久化——这是任何竞品都要付的真实工程成本。

公开信息：8 只默认宠物（鸭子 Dewey、Fireball、蓝屏小怪 BAOD），`/pet` 和 `/hatch` 命令（任意上传图片自动生成完整动画帧集：idle / running / jumping / waving），Codex 最小化时仍浮在其它 app 之上，会冒消息气泡讲它在干什么，任务完成/需要输入时提醒。OpenAI 员工在论坛说："The Codex pet feature was a **week 1 ship from a new joiner**."

**Anthropic `/buddy`**（2026-04-01）—— 18 个 ASCII 物种、5 个稀有度、7128 种组合，**用账号 ID 的 FNV-1a 哈希确定性分配**（不能重roll、不能刷）。"Bones vs Soul" 双层架构：物种/稀有度每次会话从哈希重算（防作弊），名字和性格 LLM 生成一次永久存储。

> **它被公开记录的"缺点"是这份调研里最有价值的产品信号**："nothing evolves… no progression system, no achievements, no reason to revisit"。
> 读法：Anthropic 在专业工具里**刻意只给了身份和愉悦，刻意扣住了 Tamagotchi 的养成/衰减循环**。这是一方的产品判断。

### 5.2 第三方（GitHub API 拉取于 2026-09-23）

| 项目 | ★ | 许可 | 要点 |
|---|---|---|---|
| **cc-haha** | 14,684 | — | 本地优先跨平台工作台，多 agent、worktree、diff、技能市场 |
| **clawd-on-desk** | 6,274 | AGPL-3.0 | **最强对手**。12 状态、28 agent、审批气泡（Allow/Deny/Always）、全局快捷键、Telegram + 飞书转发、LAN PWA、三平台、brew cask |
| **petdex** | 4,146 | — | **宠物素材市场 + 格式标准**。`pet.json` + `spritesheet.webp`，8×9 或 8×11 帧，每帧 192×208px，9 个状态 |
| **openpets** | 1,226 | MIT | 插件 SDK + MCP |
| **Claude-Code-Agent-Monitor** | 1,013 | — | — |
| **claude-code-tamagotchi** | 435 | — | 行为矫正向，会打断不当行为。**2025-10 起无提交** |
| **agentpet** | 364 | MIT | **Swift/SwiftUI**。Hatchling→Companion→Scout→Hero→Legend，14 成就，排行榜，Unix socket 守护进程，`agentpet run -- <cmd>` 通用包装器 |
| oc-claw | 351 | — | Rust |
| Agentic-Desktop-Pet | 340 | — | Python |

长尾还有 CoPet / UniPet / TermiPet / Hopet / nom-pet / chara-desk / peon-pet / vibebud / ccpet / frieren-agent-monitor-pet / campy（ASCII 终端宠物）/ InkPet（电子纸）等 15+ 个。

**petdex 的格式细节**（要兼容的话）：9 个状态 `idle` `running-right` `running-left` `waving` `jumping` `failed` `waiting` `running` `review`。注意它的状态是 **agent 形状**而不是宠物形状的——但缺 `compacting` / `rate-limited` / `disconnected` / `awaiting-permission`，正好是我们要扩展的缺口。

**agentpet 的反面教材**：XP 来自"你的 agent 烧掉的真实 token"——**直接奖励了用户第一痛点（额度浪费）所对应的行为**。要反过来：如果做游戏化，就奖励**效率**（每百万 token 完成的任务数、没撞 5 小时上限就跑完的会话数）。

### 5.3 这个品类的维护墓地

> vibe-notch（2,509★，2026-04-20 起无提交）· Claude-Code-Remote（1,286★，2025-12-06 起）· claude-code-tamagotchi（435★，2025-10-20 起）· kibitz（495★，2026-04 起）· uzi（583★，2025-06 起）· crystal（3,120★，已停更改名）

**每个新 agent 版本都会打断一个适配器。**适配器维护是主要的持续成本，必须做成声明式清单让贡献者不碰 Swift 也能加 agent。

### 5.4 非屏幕的影子市场（最强的"需求是外围感知"证据）

电子纸（`EleksCava-InkPet`）· Kindle（`AI-Workstation`）· MQTT（`crossmux-agent-monitor-hub`）· 托盘状态灯（`code-light-ai`）· 菜单栏灯效（`Agent-Signal-Bar`）· Android（`Fox-smile/AgentSignalBar`）· Wayland/QML（`noctalia-agents-status`）· tmux 状态栏（`marmonitor`、`cc-pane`）· 键盘 LED（`agent-kick75-status-lights`）

**人们在主动把 agent 状态推到电子墨水、LED、MQTT 和第二台设备上，就是为了把它移出前景。** 这是把状态引擎做成独立守护进程、宠物只是渲染器之一的最强论据。

---

## 6. 用户痛点排序（基于 HN 参与度 + 工具增殖数）

> 局限：Reddit 在调研环境里被墙（WebFetch 和公开 .json API 都不行），X 无 cookie。所有原话引用来自 HN 和两个 Reddit 自述帖，**不是代表性样本**。排序是推断的，不是频次统计。

**#1 额度焦虑** —— *Show HN: Claude Code Usage Monitor* **245 分 / 135 评论**，是全品类参与度最高的。作者："I kept slamming into Claude Code limits mid-session and couldn't find a quick way to see how close I was getting."

**#2 agent 静默卡在权限提示上**（被重复陈述最多的）：

> "Running 4+ Claude Code sessions across terminal tabs, **I'd find one sitting idle for 20 minutes waiting for approval while I was focused elsewhere. Desktop notifications didn't help — they'd vanish before I noticed.**"

> "rather than do something else until it finishes, I would constantly check on it to see if it was asking for yet another permission, **which felt like it was missing the point of having an agent do stuff.**"

> "six tmux panes, **missed permission prompts, no idea which agent was waiting on me.**"

**"通知会消失"这个细节是战略核心**——toast 的失败模式是**非持久性**，而这恰恰是持久化外围显示所修复的。

**#3 跟不住 3–10 个并行会话** —— 实践者普遍报告认知上限在 3–5 个。"到第四个终端，开发者就不再是开发者了，而是一个失去雷达的空中交通管制员。"
→ **这是桌宠形态相对于栏形态有真实信息论优势的痛点**：N 只宠物占据二维空间且可空间锚定；栏是一维的，超过约 4 项就退化。

**#4 想在手机/沙发上审批** —— Omnara *Show HN* **310 分 / 168 评论**。
**必须准备好回答的质疑**（它杀死了那个讨论）："why should a hacker submit to using tools behind a SaaS offering … I don't think there is any sort of moat here." Omnara 创始人自己承认护城河是"便利性"，且意外地有相当比例需求来自**非技术的 vibe-coder**。

**#5 用户在自己动手做"每会话身份"** —— 这是宠物独有优势的直接证据：

> "**Voxlert gives each Claude Code session a distinct character voice** so you know which session needs attention without looking. SHODAN for one window, StarCraft Adjutant for another."

> 有人把 OSC 777 `(title, body)` 从 notification hook 管进 `/dev/tty`，让 Ghostty 接收，然后"生成 macOS 通知并**给来源终端的 tab/pane 上色**"。后来他干脆用 Swift/AppKit + Ghostty 的 Zig 库写了一个完整的 macOS 终端，"because I basically just wanted vertical tabs and notifications for when AI agents are finished."

要击败的基线现状（某用户正在写团队上手指南的真实配置）：

```json
{"hooks":{
  "Stop":[{"hooks":[{"type":"command","command":"terminal-notifier -title \"✅ Claude Code\" … && afplay /System/Library/Sounds/Glass.aiff"}]}],
  "Notification":[{"hooks":[{"type":"command","command":"terminal-notifier -title \"🔔 Claude Code\" … && afplay /System/Library/Sounds/Glass.aiff"}]}],
  "PostToolUse":[{"matcher":"*","hooks":[]}],"UserPromptSubmit":[{"hooks":[]}]}}
```

他自己的评价："**in practice I still miss the sound notifications sometimes.**"
→ "完成"和"需要输入"用同一个声音，没有项目名，没有会话身份，没有升级，三个能携带上下文的事件全是空数组。

---

## 7. 设计理论依据

**五级通知等级** —— Matthews, Dey, Mankoff, Carter & Rattenbury, *Peripheral Display Toolkit* (UIST)：**ignore → change blind → make aware → interrupt → demand attention**。
"change blind" 是大多数产品跳过的关键中间级：显示确实变了，但**刻意设计成你不主动看就注意不到**。

Mankoff 2003 的环境显示启发式：显示"should be unobtrusive and remain so **unless it requires the user's attention**"。
Matthews 的博士论文（UC Berkeley EECS-2007-56）：可瞥视的视觉呈现让用户"**以更少的分心**对外围信息保持更高的感知"。

谱系：Weiser & Seely Brown《Designing Calm Technology》（Xerox PARC, 1995）→ Amber Case 2015 年的编码："technology should require the smallest possible amount of attention" / "can communicate but doesn't need to speak"。

**打断成本** —— ⚠️ 那个著名的"23 分 15 秒"**没有同行评议论文支撑**，它来自 2006 年 Gallup 的一次采访，已被多方指出。要引就引 Gloria Mark 可辩护的数据：**单屏停留时长中位数从 2004 年的 2.5 分钟降到 2023 年的 47 秒**。
另一个可靠的：临床环境下打断式告警的**覆盖/忽略率是 49–96%**——这是"默认打断的系统会训练用户反射性忽略，然后关键告警就被漏掉"的经典证据。

**吉祥物规范** —— GitHub 官方品牌指南（brand.github.com/graphic-elements/mascots）原文：

> "**less is more. Overuse or use of mascots as space fillers can be distracting and annoying.**"
> Don't: "用吉祥物做 logo" / "**用吉祥物解释、打断或推销**" / "**用吉祥物承载严肃话题**（安全、金钱、危机、道歉）"
> Do: 与社区一起用、内部用、"用来激励和取悦"

设计评注还提到 Octocat "**must never speak**"，只通过语境、动作和表情表达情绪——据说这条规则正是从分析 Clippy 为什么不讨喜得来的。

**Clippy vs Bongo Cat** —— 失败和成功模式可以干净地拆开，且都不取决于可爱程度：

| Clippy 失败 | Bongo Cat 成功 |
|---|---|
| "为首次使用优化"——第一次写信时有用，第五十次就令人抓狂 | 免费，**不挡路**（"待在角落里不碍事"） |
| 假设价值而不验证需求 | 低风险的装饰收集循环（帽子）而非养成循环 |
| **关不掉**——用户发现无法禁用后更愤怒 | 对你**已经在做**的事（打字/点击）作出反应，而不是主动提供帮助 |
| 2001 年比尔·盖茨宣布退役时全场起立鼓掌 | 峰值 **10.1 万+ 同时在线**，Steam 最热榜第 12 |

**提炼出的规则：吉祥物当镜子时被爱，当发起者时被恨。** agent 状态宠物天生是镜子——这是这个特定拟人化能成立的最强结构性论据。要防的失败模式是**从镜子漂移成发起者**（小贴士、推销、"我注意到你…"）。

**CASA 范式** —— Reeves & Nass《The Media Equation》：人与计算机的交互"fundamentally social and natural"，且是**无意识地套用过度学习的社交脚本**，不是有意识的拟人化。

应用到这里：开发者**已经**在说"Claude 卡住了"、"它在想"、"它跑偏了"。拟人化的框架是预装的。所以设计问题不是**要不要**拟人化，而是**这个角色被允许声称什么**。只反映机器状态（忙/阻塞/失败）是低风险的诚实拟人化；声称对你的代码有判断、有意见、有情感需求是高风险的，会招来 Clippy 式失败和过度信任。

**Codex Pets 的公开争论**（community.openai.com）：

> 反方："**Why are highly paid engineers being asked to spend time on features like this** when Codex still has so many serious problems?"
> 正方："It's a creative, smart way to **keep track of your ongoing tasks without constantly switching attention to a full separate screen.**"
> 正方："a nice way to keep track of active and recent status updates on tasks **while I am working on something else.**"

**两条正方辩护都是建立在外围感知论证上的。这就是能扛住专业性质疑的定位；"它很可爱"不是。**

---

## 8. 本次调研没能关闭的问题

1. **能耗**（最大的未量化风险）—— `powermetrics` 需要 sudo。这是最可能导致卸载的因素（出现在"正在使用大量能量"列表），且是不可事后修改的架构选择
2. **macOS 15 的置顶行为** —— 只在 26.2 上验证过，唯一找到的 15.0.1 报告是失败案例
3. **`sessions/*.json` 的 `status` 完整状态机** —— 只观察到 4 个值、1 次转换。需要拿一个会话跑穿权限提示、compaction、崩溃
4. **共存** —— 本机同时跑着 claude-hud 和 OpenUsage。两个监视器都装 PreToolUse hook、都要 statusLine、都监听同一批文件、都想审批同一个请求，会怎样？**所有竞品都没有"已有另一个监视器"的设计**
5. **空状态** —— 一天大部分时间没有 agent 在跑。所有状态模型都假设 agent 存在。**早上 9 点零会话时这个产品是什么？这正是 Clippy 的失败模式**
6. **配置写入并发** —— Claude Code 自己会通过 `/config` 重写 settings.json，而且（据热加载实验）是**实时读取**的。两个写者，没有锁，读者是热的
7. **留存** —— 任何 agent 宠物都没有留存/流失数据。新鲜感过去后会不会被关掉，无人测量。Bongo Cat 的"没什么理由关掉它"是记者的断言，不是实测
8. **对照实验不存在** —— 宠物 vs 刘海栏 vs 菜单栏圆点，测"发现阻塞 agent 的耗时"和"误报率"。公开资料里没有。**自己跑一个并发表，本身就是这个品类最强的营销资产**
9. **OpenAI 有没有类似的凭据使用限制** —— Codex 是所有支持矩阵里的第二 agent，但没人查过 OpenAI 是否有对应的条款
10. **Live2D 的"可扩展应用"条款细则** —— Live2D 只公开中型企业的费用，其余"请联系我们"。桌宠渲染内置模型算不算 VTuber 追踪类（¥20,000,000 门槛）**真的有歧义**，要书面答复

---

## 9. 数据来源

**一手（本机实测）**：Claude Code 2.1.220 二进制（394,254 行 strings）· 真实 hook stdin 捕获 · `pty.fork()` 交互式会话实验 · 自写 C 程序调 `sysctl(KERN_PROCARGS2)` · Swift 全屏 Space + `CGWindowListCopyWindowInfo` z-order + `screencapture` 像素直方图 · Swift+WKWebView 内存实测 · `codex app-server` 活体 JSON-RPC · 本机 SDK 头文件（NSWindow.h / NSScreen.h / CGWindowLevel.h / NSProcessInfo.h / CADisplayLink.h）· XNU `kern_sysctl.c` 源码

**官方文档**：[code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks) · [/statusline](https://code.claude.com/docs/en/statusline) · [/settings](https://code.claude.com/docs/en/settings) · [/claude-directory](https://code.claude.com/docs/en/claude-directory) · [/agent-teams](https://code.claude.com/docs/en/agent-teams) · [/legal-and-compliance](https://code.claude.com/docs/en/legal-and-compliance) · [learn.chatgpt.com/docs/hooks](https://learn.chatgpt.com/docs/hooks) · [developer.apple.com](https://developer.apple.com) 论坛 814798 / 759780

**竞品**：[vibeisland.app](https://vibeisland.app/) + [docs](https://vibeisland.app/docs/) + [privacy](https://vibeisland.app/privacy/) + [changelog](https://vibeisland.app/changelog/) + [GitHub issues](https://github.com/vibeislandapp/vibe-island/issues)（227 个，83 开放）· [boring.notch](https://github.com/TheBoredTeam/boring.notch) · [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) · [petdex](https://github.com/crafter-station/petdex) · [agentpet](https://github.com/ntd4996/agentpet) · [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) · [tauri-nspanel](https://github.com/ahkohd/tauri-nspanel) · [ccusage](https://github.com/ccusage/ccusage) · GitHub API 搜索（2026-09-23）

**学术**：Matthews et al., *Peripheral Display Toolkit* (UIST) · Matthews, *Designing and Evaluating Glanceable Peripheral Displays* (UC Berkeley EECS-2007-56) · Weiser & Seely Brown, *Designing Calm Technology* (PARC 1995) · Reeves & Nass, *The Media Equation* · [caseorganic.com](https://caseorganic.com/post/principles-of-calm-technology/)

**用户声音**：Hacker News 44317012（245分）· 44878650（310分）· 46703941 · 46692623 · 47901927 · 47287559 · 47334067 · 47468817 · community.openai.com/t/1386776
