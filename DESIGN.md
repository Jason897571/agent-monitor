# Agent Monitor — 桌宠式 AI Agent 状态监视器

> 设计文档 v0.1 · 2026-09-23
> 形态：桌宠 + 吸附栏双模式 ｜ 技术栈：macOS 原生 Swift/SwiftUI ｜ MVP：只读监控 ｜ 许可：开源
>
> 配套文档：[docs/RESEARCH.md](docs/RESEARCH.md)（平台接口实测 + 竞品格局，本文结论的证据在那里）

---

## 0. 先说三个坏消息

在写任何代码之前，必须承认调研挖出来的三件事。它们不改变"做"的决定，但彻底改变"做什么"的决定。

**1. 这个赛道已经不是空白，是拥挤。**

| 项目 | 体量 | 形态 |
|---|---|---|
| OpenAI **Codex Pets** | 一方功能，已内置于 Codex 桌面端 | 8 只默认宠物、`/hatch` 任意图片自动生成动画帧 |
| Anthropic **`/buddy`** | 一方功能 | 18 物种 × 5 稀有度，7128 种组合 |
| **clawd-on-desk** | 6,274 ★ AGPL | 12 状态、28 agent、审批气泡、Telegram/飞书转发、三平台 |
| **petdex** | 4,146 ★ | 宠物素材市场，已定义 `pet.json` + 192×208 精灵图标准 |
| **agentpet** | 364 ★ MIT Swift | XP/5 级进化/14 成就/排行榜，完整游戏化 |
| **Vibe Island** | $19.99 买断 | 刘海栏，30 agent，20+ 终端精准跳转 |

**所以这些方向已经没有位置了**：可换肤角色市场（petdex 占了）、开源跨平台桌宠（clawd 占了）、XP 升级排行榜（agentpet 占了，还是 MIT）、手机远程审批（Omnara/Bark/Telegram 都有）、非刘海 Mac 支持（Vibe Island 本来就降级成浮动条）。

**2. Vibe Island 的招牌功能之一是违反 ToS 的，不能抄。**

它的额度显示读 macOS Keychain 里的 `Claude Code-credentials`，调 `https://api.anthropic.com/api/oauth/usage`。Anthropic 法律条款原文：

> "developers may not collect, store, or intermediate Claude.ai credentials or session tokens"

Vibe Island 三个动作全中：读取（Keychain）、缓存到本地文件、以及自己做 token refresh（即中转）。服务端拦截已于 2026-01 上线。**这条路对开源项目尤其走不得**——代码公开等于把违规证据公开。

**3. 唯一合规的额度数据源是 `statusLine`，而它是单槽位、且常被占用。**

`rate_limits.five_hour.used_percentage` / `.resets_at` 只通过 statusline 的 stdin 下发，全部 transcript 里 grep `five_hour` 得到 **0 个结果**。而 `statusLine` 在 settings.json 里是标量不是数组，没有 merge 语义——覆盖就是砸掉用户已有的 HUD（本机就被 claude-hud 占着）。

---

## 1. 定位

> **一个常驻的、可瞥见的 agent 状态镜子。不打断你，但你一抬眼就知道哪个 agent 卡住了。**

三条硬规则，来自调研中最有价值的那部分证据：

**规则一：卖"外围感知"，不卖"可爱"。**
Codex Pets 在 OpenAI 论坛上的公开争论里，所有站得住脚的辩护都是注意力管理论证（"不用切到另一个屏幕就能跟踪任务"），所有攻击都是严肃性论证（"为什么高薪工程师在做这个"）。"它很可爱"不是答案。

**规则二：宠物是镜子，不是发起者。**
Clippy 失败是因为它**主动发起**且**关不掉**；Bongo Cat 成功是因为它**镜像**你已经在做的事且不挡路。GitHub 官方吉祥物规范写得更直白：不得用吉祥物"解释、打断或推销"，不得用于"安全、金钱、危机、道歉等严肃话题"。

> 落到设计上：额度百分比、花费金额、权限请求、报错，一律走中性 UI（卡片/徽章/音色）；**宠物只改变姿态**。宠物永远不以第一人称谈论你的代码。

**规则三：拒绝 Tamagotchi 的养成循环。**
不做离开衰减、不做死亡、不做连续打卡、不做喂食计时、不做愧疚文案。养成循环的机制本质是**制造道德义务**——一个因为你周末休息而惩罚你的开发工具是反功能。agentpet 用"烧掉的 token"换 XP，正好奖励了用户第一痛点（额度焦虑）所对应的行为。

唯一值得移植的机制是**响应性镜像**：宠物对真实发生的事即时、清晰地反应，情感联结从准确的镜像里长出来，而不是从制造的需求里。

---

## 2. 四个差异化支点

按 (用户价值 × 可行性) 排序。前两个是 P0 就该有的骨架，后两个是护城河。

### 支点 A：零 Hook 也能跑（合规楔子）

所有竞品都要求先装 hook。Vibe Island 的 hook 二进制**已经被 CrowdStrike EDR 隔离**（issue #220），而且它把每个 hook 都路由到一个同步二进制，导致 `Stop` hook 中位数阻塞 **15.8 秒**（issue #159，未修复）。

而 Claude Code 其实在磁盘上放了一份**完整的、一方维护的会话注册表**：

```
$CLAUDE_CONFIG_DIR/sessions/<pid>.json
```

实测内容（本机真实文件）：

```json
{
  "pid": 27435,
  "sessionId": "dd099179-0f6b-4986-a9f5-1a9fe5fae977",
  "cwd": "/Users/jason/Desktop/pp/agent-monitor",
  "startedAt": 1790154990896,
  "procStart": "Wed Sep 23 09:16:28 2026",
  "version": "2.1.220",
  "kind": "interactive",
  "entrypoint": "cli",
  "name": "agent-monitor-e8",
  "status": "waiting",
  "updatedAt": 1790155527872,
  "statusUpdatedAt": 1790155527872,
  "waitingFor": "input needed"
}
```

`status` 的取值在二进制里是写死的枚举：

```js
IO_ = ["busy", "shell", "idle", "waiting"]
```

而且写入逻辑是 `status !== undefined && { statusUpdatedAt: t }`——**`statusUpdatedAt` 只在状态真正变化时才推进**，这正是"等了 20 分钟"升级计时器需要的时间戳。

> **一个目录的 FSEvents 监听 + `kill(pid, 0)` 存活校验 = 全部会话的身份、cwd、忙闲状态。零 hook、零权限、零 EDR 风险。**

这让产品在用户点"安装 hook"之前就已经能用了，是比所有竞品都好的首次体验，同时是受监管企业里唯一能过审的形态。

### 支点 B：状态模型比所有人都细

Vibe Island 4 个状态，agentpet 3 个，petdex 格式 9 个。而平台实际暴露的信息远不止这些。

| 状态 | 数据来源 | 竞品有吗 |
|---|---|---|
| `dormant` （**一个会话都没有**） | 活 pid 数为 0 | **无人区分**，见 B.1 |
| `busy` + 当前工具名 | session.json / `PreToolUse.tool_name` | 部分 |
| `shell` （用户 shell 出去了） | session.json 枚举 | **无人区分** |
| `idle` （会话在，但 agent 空闲） | session.json | 有 |
| `waiting` + `waitingFor` 文案 | session.json | **无人读 waitingFor** |
| `awaiting-permission` | `PermissionRequest` hook（即时） | 有 |
| `awaiting-answer` | `Elicitation` | 少数 |
| `compacting` | `PreCompact` → `PostCompact` | **无** |
| `done-success` | `Stop`（先查 `background_tasks[]`） | 有 |
| `done-error` | `StopFailure` / `PostToolUseFailure` | **少数** |
| `rate-limited` | statusline `rate_limits.*.used_percentage` | 部分 |
| `context-critical` | `context_window.remaining_percentage < 10` | **无** |
| `disconnected` | pid 死 / `statusUpdatedAt` 陈旧 | 部分 |
| `subagent-swarm` | `SubagentStart` 计数 / `isSidechain` | 少数 |

顺带一提，Claude Code **已经自己生成好了给人看的文案**，白嫖即可，零额外 LLM 成本：

```json
{"type":"system","subtype":"away_summary",
 "content":"目标是把导出的订单转成发放清单；两个 xlsx 都已生成并放进 out/ 目录。
            下一步只剩你确认是否把新增的映射补进 current_info.csv。 (disable recaps in /config)"}
```

配套还有：`ai-title`（模型生成的会话标题，直接当宠物名牌）、`last-prompt`（当前目标）、`tasks/<sessionId>/<N>.json` 里的 `activeForm`（现在进行时标签，如 `"对比方案"`，字面意义上是写好的气泡台词）。

> 注意：`away_summary` 末尾的 `" (disable recaps in /config)"` 要剥掉。

#### B.1 空状态：`dormant` — 宠物睡觉

一天里大部分时间是没有 agent 在跑的。**这时候宠物就睡觉。**

这不是凑合，它同时满足了三条本文已经定下的原则：

- **镜子原则**：没东西可镜像，所以静默。宠物不会在这时候跳出来给建议、推销、说"我注意到你…"——那正是从镜子漂移成发起者的时刻，也是 Clippy 的死因。
- **calm tech**：`dormant` 的通知等级是 `ignore`，**永不升级**。这是整个阶梯里唯一一个没有时间驱动升级规则的状态。
- **能耗**：睡觉是最省电的状态，而能耗是 P0 的阻塞项。见下。

**两个 idle 必须分开，因为它们的含义完全相反：**

| | 含义 | 判据 | 姿态 |
|---|---|---|---|
| `dormant` | 你没在用 agent | 活 pid 数 = 0 | 睡着，呼吸 |
| `idle` | **agent 在等你** | 有活 pid 且 `status == "idle"` | 醒着，发呆，2 分钟后抬头看你 |

把它们合并的话，一个"等了你 20 分钟的空闲会话"会被画成"你今天还没开始工作"——**信息反了**。`sessions/` 目录里活 pid 的计数天然区分这两者，零额外成本。

**睡眠的省电契约**（这是白捡的性能收益，要写进实现）：

```swift
// dormant 时
displayLink.isPaused = true          // 完全停掉，不是降频
// 或保留极低频呼吸动画：
link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 2, preferred: 1)
```

进入 `dormant` 时把精灵图集以外的资源也释放掉。目标：**`dormant` 状态的 CPU 占用与 OpenUsage 实测的 0.3% 地板持平或更低**——因为此时确实什么都不用算。这直接把「常驻小工具」最大的卸载风险（出现在"正在使用大量能量"列表里）压在了它出现频率最高的状态上。

**唤醒必须是有表演的。** `dormant → busy` 是用户一天里看到次数最多的转场，也是宠物存在感的主要来源：伸懒腰、睁眼、起身。这是 Bongo Cat 式"对你已经在做的事作出反应"的直接体现——你敲下 `claude` 的那一刻它醒过来，而不是它主动来找你。

**可见性策略：常驻 + 淡出（已定）**

宠物永不自动隐藏。睡久了会淡下去，但**始终在原地**——唤醒时不需要重新找它，这是它区别于通知控件的地方。

| 参数 | 默认值 | 说明 |
|---|---|---|
| 淡出触发 | **仅 `dormant`** | 见下方红线 |
| 淡出延迟 | 10 分钟 | 可配 `1 / 5 / 10 / 30 分钟 / 从不` |
| 淡出目标 | `alphaValue = 0.25` | 可配 `0.1 – 1.0` |
| 淡出时长 | 2 秒 ease-out | 足够慢到不像 bug |
| 悬停 | 立即恢复 1.0（0.15 秒） | 鼠标离开后重新计时 |
| 唤醒 | 立即恢复 1.0 + 唤醒动画 | 不走淡入，直接接伸懒腰 |
| 淡出态交互 | **保持可点击、可拖拽** | 淡出 ≠ 隐藏 ≠ 穿透 |

> 🔴 **红线：`idle` 绝对不能淡出。**
> `idle` 的语义是「**agent 在等你**」。把它淡掉就是把唯一需要你看见的状态藏起来，正好和产品目的相反。淡出逻辑必须显式判 `state == .dormant`，不能图省事写成"非 busy 即可淡出"。这是这一节最容易写错的一行。

两个实现注意：

- **淡出用 `window.alphaValue`，不要动 `ignoresMouseEvents`。** 两者无关——前者是视觉透明度，后者是事件穿透。低 `alphaValue` 的窗口仍然接收鼠标事件（需在目标 macOS 版本上实测确认一次，连同 §7.1 提到的 26.3/26.4 命中测试回归一起测）。
- **淡出完成后 `displayLink` 保持 `isPaused = true`。** 淡出动画本身走一次性的 `CABasicAnimation`，由渲染服务器执行，不需要唤醒主循环。省电契约在淡出期间也不破。

> 为什么不做自动隐藏：那会让宠物退化成"只在忙时出现的通知控件"，**放弃桌宠形态唯一的真实优势——空间锚定的持久存在**。真需要那个行为的人，直接用吸附模式。

### 支点 C：注意力升级阶梯（可配置一等公民）

这是学术上有依据、产品上没人做的东西。Matthews & Mankoff 的外围显示工具箱定义了五级通知等级：

```
ignore → change-blind → make-aware → interrupt → demand-attention
         ↑ 大多数产品跳过的那一级：画面变了，但刻意设计成你不主动看就注意不到
```

绑定 `statusUpdatedAt` 做**时间驱动的自动升级**：

| 状态 | 初始等级 | 时间台阶 |
|---|---|---|
| `dormant` | ignore | **永不变化**（唯一一个） |
| `busy` | ignore | — |
| `shell` | change-blind | — |
| `idle` | change-blind | 2 分钟 → make-aware；**30 分钟 → 退回 change-blind** |
| `waiting` + `waitingFor` | make-aware | 90 秒 → interrupt；5 分钟 → demand-attention；**1 小时 → 退回 make-aware** |
| `awaiting-permission` | make-aware | 20 秒 → interrupt（P1） |
| `done-success` | make-aware | **永不升到 interrupt**（P1） |
| 额度 > 90% | make-aware 一次 | 带 `resets_at` 倒计时，不重复（P1） |

**台阶可升也可降，这不是客气，是这张表能否成立的前提。**

只升不降的阶梯会把每个长寿会话永久钉在它最吵的那一级。这不是推演——第一次拿真机跑就复现了：13 个会话 idle 了几小时到 13 天，全部停在 make-aware，整体注意力被一个"空闲 13 天"的会话钉住。**一个永远亮着的信号等于没有信号**，而这正是临床研究里打断式告警**忽略率 49–96%** 的成因。

所以正确的形状是**窗口**：进入某状态后短时间内值得一瞥，等到显然你已经看见并选择了不处理，就安静退回去。`waiting` 同样要衰减——一小时都没喊动，再喊也没用，而一个被丢在半路的会话不该让宠物连喊三天。它仍然可见，只是不再打断。

另一条硬规则：只有**阻塞且用户可解决**的状态配得上 interrupt。用户现状的基线是——同一个 `Glass.aiff` 同时用于"完成"和"需要输入"。

### 支点 D：Agent Teams 拓扑（真护城河）

Claude Code 已经内置多 agent 编排（`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`），并且在磁盘上留下了完整依赖图：

```
~/.claude/tasks/<sessionId>/<N>.json
  → { id, subject, activeForm, status, blocks[], blockedBy[] }
```

配套 hook 事件 `TeammateIdle` / `TaskCreated` / `TaskCompleted`——**调研范围内没有任何一个竞品读过这些**（clawd-conduit 接了 31 个事件中的 15 个，这三个都没接）。

于是：lead 是一只大宠物，每个 teammate 是一只小宠物，位置由 DAG 决定。一个 teammate 进入 `TeammateIdle` 而它的 `blockedBy` 是空的 → **这是一个停摆的工人**，一个刘海栏在物理上就无法表达的状态。

> 这也正好是"多 agent = 多只会互动的宠物"的字面实现，而刘海栏是一维的、超过 4 项就退化。桌宠占据二维屏幕空间，可以按项目/显示器做空间锚定——**这是桌宠形态相对于栏形态唯一真实的信息论优势**，要吃透它。

---

## 3. 产品形态：双模式，共享内核

```
   桌宠模式                          吸附模式
   ┌────────────────────┐            ┌────────────────────┐
   │                    │            │ ▂▂▂ ●2 ◐3 ▂▂▂     │ ← 顶栏/刘海
   │      ∧__∧          │            │                    │
   │     ( ･ω･)  ← busy │    ⇄       │                    │
   │     /    ⌒ヽ       │            │   (开会/录屏时)     │
   │    (人＿_,ﾉ        │            │                    │
   └────────────────────┘            └────────────────────┘
     自由拖拽 · 跨屏 · 空间锚定         贴顶不挡路 · 一维紧凑

   ────────────────── 共享内核 ──────────────────
    AgentSession 状态机 │ 事件总线 │ 注意力升级器 │ 审批队列(P2)
    ↑ 两种模式只有渲染层不同，内核零感知
```

切换成本必须是**一个快捷键**。开会、录屏、演示时收成吸附条；写代码时放出来。

配套白送一个功能，一行代码，竞品都没有：

```swift
window.sharingType = .none   // 从屏幕录制/共享中隐藏宠物
```

对要直播和录教程的人是真需求。

---

## 4. 技术架构

```
┌─────────────────────────────────────────────────────────────┐
│  渲染层  PetPanel (NSPanel)  │  DockedPanel (NSPanel)        │
│          精灵图 + CADisplayLink · 命中掩码 · 多屏定位          │
├─────────────────────────────────────────────────────────────┤
│  表现层  PetStateMachine  ·  AttentionEscalator (五级阶梯)    │
│          姿态/音色/HUD 决策，与数据源完全解耦                   │
├─────────────────────────────────────────────────────────────┤
│  内核    SessionRegistry  ·  EventBus  ·  ApprovalQueue(P2)  │
│          规范化的 AgentSession 模型，与具体 agent 无关          │
├─────────────────────────────────────────────────────────────┤
│  采集层  ClaudeCodeAdapter  │  CodexAdapter  │  …            │
│          ┌── 被动（P0，零 hook）  sessions/*.json、transcript │
│          └── 主动（P1，选装）      hooks → 本地 socket         │
└─────────────────────────────────────────────────────────────┘
```

**采集层必须是声明式的**。这个品类最大的持续成本是适配器维护——每个 agent 发版都会打断一个适配器。调研里一串墓碑为证：vibe-notch（2,509★，2026-04 起无提交）、Claude-Code-Remote（1,286★，2025-12 起）、claude-code-tamagotchi（435★，2025-10 起）、crystal（3,120★，已弃）。

> 所以：每个 agent 一份 JSON/TOML 清单，贡献者加新 agent 不需要碰 Swift。这是开源项目能否活过一年的关键结构决策。

### 4.1 采集层 · Claude Code（P0 被动路径）

| 源 | 给你什么 | 代价 |
|---|---|---|
| `$CLAUDE_CONFIG_DIR/sessions/*.json` | **主状态源**：pid / sessionId / cwd / status / waitingFor / name | 一个目录的 FSEvents |
| `$CLAUDE_CONFIG_DIR/history.jsonl` | 全局活动流；`project` 字段是**未打码的真实 cwd** | tail 一个文件 |
| `projects/<slug>/<uuid>.jsonl` | `away_summary` / `ai-title` / `last-prompt` / `turn_duration` | 按需读，不做主信号 |
| `tasks/<sessionId>/<N>.json` | 任务 DAG + `activeForm` 台词 | 目录监听 |
| `ide/<port>.lock` | 哪些编辑器挂着 agent、workspace 路径 | 六个小文件 |
| `stats-cache.json` | 历史用量（**不含凭据、不碰 ToS**） | 读一次 |

> `~/.claude/todos/` 和 transcript 的 `type:"summary"` 行**都已经不存在了**——它们出现在几乎所有第三方文章里，但 2.1.220 上 todos 目录不存在，约 400 个 transcript 里 `summary` 行是 0 条。不要照抄网上的写法。

### 4.2 采集层 · Codex

调研推翻了一个常见误解：Codex 不只有 `notify`。

- **`notify`**（`~/.codex/config.toml`）——确实是 fire-and-forget（三个 stdio 全 `Stdio::null()`，不读 exit code），只能当"回合结束"的廉价提示。**而且它是标量单槽位，本机已被 ChatGPT.app 的 Computer Use 占用**——写它会静默搞坏用户的功能。别碰。
- **`~/.codex/hooks.json`**——12 个生命周期事件，和 Claude Code 对等，`PreToolUse` 能阻塞和 deny。代价：新 hook 落地是 `trustStatus: "untrusted"`，要用户跑一次 `/hooks` 确认，而且**信任哈希覆盖命令字符串本身**，升级时那一行必须字节级不变。
- **`codex app-server --listen unix://<path>`**——双向 JSON-RPC，99 个请求方法 + 81 个通知 + 10 个需要回复的服务端请求（含三种审批）。实测在本机跑通了 `initialize` 和 `hooks/list`。这是 GUI 监视器的正确答案，但协议标着 `[experimental]`，要拿 `codex app-server generate-json-schema` 在 CI 里锁版本。

> 打包注意：本机 `codex` **根本不在 PATH 上**，它在 `/Applications/ChatGPT.app/Contents/Resources/codex`。别假设 `which codex`。

### 4.3 渲染层 · 窗口（每一条都经过像素级实测）

```swift
final class PetPanel: NSPanel {
    init(...) {
        super.init(contentRect:..., styleMask: [.borderless, .nonactivatingPanel], ...)
        isFloatingPanel  = true
        isOpaque         = false
        backgroundColor  = .clear
        hasShadow        = false
        isMovable        = false          // 自己实现拖拽以支持吸边
        level            = .statusBar     // 25。不是 1000
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if #available(macOS 13, *) {
            collectionBehavior.insert(.init(rawValue: 1 << 18))  // canJoinAllApplications
        }
    }
    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }
}
```

四条被实测纠正的常见错误：

1. **不要用 `.screenSaver` (1000)。** 实测 level 3 / 25 / 1000 三个面板同时对着别人的全屏窗口，**三个都浮在上面**。而 1000 会让宠物盖住右键菜单（101）、菜单栏（24）、控制中心（25）、拖拽预览（500）。用 25–27。
2. **`.fullScreenAuxiliary` 对跨应用全屏毫无作用。** SDK 头文件原文是"可以和**该全屏窗口**一起显示"——指你自己 app 的全屏窗口。实测单独开它的面板直接**从屏幕窗口列表里消失**。真正起作用的只有 `.canJoinAllSpaces`。
3. **窗口尺寸必须贴着精灵图外接框。** macOS 26.3 RC / 26.4 beta 回归了透明窗口的逐像素命中测试（Apple 论坛 814798，工程师已确认），整个透明窗口会吞掉点击。如果你把宠物塞在一个全屏大窗口里，这个 bug 会让整块屏幕失去响应；贴着外接框的话，最坏情况只是 200×200 的死区。
4. **level 和 collectionBehavior 是需要反复重申的状态，不是设一次就完事。** 所有找到的线上失败案例都能追溯到 NSWindow 被重建或被框架覆写。在 `didActivateApplication` / `didChangeScreenParameters` / `activeSpaceDidChange` / 唤醒时重新 apply，再加一个几秒一次的 `isOnActiveSpace` 自检看门狗。

**浮在别人全屏之上**：公开 API 不保证。要做就上 SkyLight 私有框架（`SLSSpaceCreate` / `SLSSpaceSetAbsoluteLevel` / `SLSSpaceAddWindowsAndRemoveFromSpaces`，boring.notch 2025-10 就是这么迁的）。**做成开关，默认关，标注"可能在未来 macOS 版本失效"**。硬天花板是 `CGShieldingWindowLevel() = 2147483628`（屏保、锁屏、截图 UI、屏幕共享），那个盖不过去，认了。

### 4.4 渲染层 · 角色

**v1 用 PNG 精灵图集 + `NSView.displayLink(target:selector:)`**（macOS 14+，`CVDisplayLink` 在 15 已废弃）。

```swift
link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 10)  // 待机
// 活跃时才升到 24
```

不设这个的话，ProMotion 上会跑满 120fps 烧电池换不到任何视觉收益。

动画技术选型（法务尾巴是主要判据）：

| 方案 | 结论 |
|---|---|
| **PNG 精灵图** | ✅ v1 选它。零第三方许可、可 AI 生成、帧级可控、10fps 下约 0.3% CPU |
| **Rive** | ✅ 后续升级选它。运行时 MIT、支持 AppKit、**无运行时费用**，状态机正好 1:1 映射 agent 状态 |
| Lottie | ⚠️ Apache-2.0 可用，但必须确认走了 Core Animation 路径，否则回退到主线程渲染（历史上出现过 43% CPU） |
| **Live2D** | ❌ 允许用户导入自己模型 = "可扩展应用"，**无视公司规模**都要 Live2D 审批 + 销售额 5% 或每笔 ¥300 |
| Spine | ❌ 年收入 $500K 以上强制 Enterprise $2,499/年 |
| WebView | ❌ 实测一个 512px 弹跳圆球就吃掉 129MB、约 10% 单核 |

> 素材获取路线：v1 买/生成一套 6 状态 × 6 帧、128×128 @2x 的图集（约 $0–100，一下午）。**并且实现 [petdex](https://petdex.dev) 的 `pet.json` + 精灵图格式**——它已经有 4,146★ 的素材库，兼容它等于白捡全部素材，而不是分裂生态。然后把我们多出来的状态名（`compacting` / `rate-limited` / `shelled-out` / `disconnected`）提 PR 回上游。

---

## 5. 预算（可验证的硬指标，不是口号）

本机实测的参照系：**OpenUsage.app**（已上架的原生 Swift 菜单栏监视器）跑了 2 天 6 小时，RSS 42MB，累计 CPU 609 秒 = **持续平均 0.31% 单核**。

这是"不带动画的原生监视器"的经验地板。于是指标定为：

| 指标 | 目标 | 说明 |
|---|---|---|
| 空闲 RSS | ≤ 60 MB | 动画暂停时 |
| 动画中 RSS | ≤ 80 MB | 比 Vibe Island 宣称的 100MB 更严 |
| 空闲 CPU | ≤ 0.3% 单核 | 对齐 OpenUsage 地板 |
| 动画中 CPU | ≤ 1% 单核 | 10fps 待机动画 |
| TCC 权限 | **0 个**（P0/P1） | 见下 |

### 5.1 实测结果

**数据层**（`agent-monitor-cli watch`，14 个真实会话，debug 构建）：**0.083% 单核，RSS 7.2 MB**。
低是因为定时器不轮询 —— 它睡到"下一次注意力等级会自己变化"的确切时刻（`AttentionAssessment.nextChange`），所有会话 settle 后完全不排程，只靠 FSEvents 唤醒。

**渲染层**（`scripts/measure.sh`，release 构建，自测 `getrusage`）：

| 状态 | fps | CPU | 内存 |
|---|---|---|---|
| dormant 已淡出 | 0（display link 暂停） | ~0 | ~26 MB |
| dormant 呼吸 | 2 | 低 | ~28 MB |
| active | 请求 24 / 实投 30 | **约 0.5%** | ~23–31 MB |
| 显示器休眠时（任意状态） | 0 | 0.09% | — |

> ⚠️ **绝对值是暂定的。** 测量机器当时 load average 17（被开发会话自己占满），同一配置连续三次跑出 2.15% / 2.80% / 0.48%，6 倍离散。取值取的是最低观测值，它和另一次独立测量（0.494%）吻合。**上线前要在空闲机器上重测。**

### 5.2 渲染栈的选择是被数据逼出来的

最初每帧用 Core Graphics 现画，实测 **每帧约 1.5ms CPU，24fps 下 3.55% 单核** —— 超预算 3.5 倍，且成本随帧率线性增长（这正是"每帧绘制"而非固定开销的特征）。

改成**预渲染精灵帧 + 换 `layer.contents`** 后，同等条件下 **3.55% → 0.50%，7 倍改善**，视觉零损失。每帧成本退化成一次指针比较加一次赋值，合成交给渲染服务器。

> 这验证了 §4.4 的选型：精灵图集不是省事，是唯一能进预算的方案。而且这层抽象（`SpriteCache` + `CharacterRenderer`）正是真实素材接入的位置——动画路径不关心图像从哪来。

**内存边界**：每姿态 16 帧 × 132pt@2x ≈ 4.5MB，只缓存当前姿态。姿态切换时重渲染 16 帧（一次性约 25ms）。

### 5.3 三个实测得到的坑

1. **显示器休眠时 CADisplayLink 完全停止投递回调。** 这是想要的省电行为（此时 app 只花 0.09%），但它意味着**任何无人值守的基准测试都在测空气**。`caffeinate -d` 只阻止未来休眠、**不能唤醒已睡的屏**，必须用 `-u`。这条坑吞掉了一小时。
2. **`preferredFrameRateRange` 的上限会被量化。** 请求 24fps，稳定投递 30.0fps —— 落到显示器支持的档位上。省电靠的是"请求低帧率"而不是"请求精确帧率"。
3. **`ps -o time=` 不够精确。** 10ms 分辨率在这个量级和信号同数量级，外部采样还容易抓错进程（两次连续运行对同一状态给出 0.8% 和 0.0%）。改成 app 自己调 `getrusage`。

三个免费且无需授权的省电闸门，`NSProcessInfo` 上都有：`thermalState`、`isLowPowerModeEnabled`、`beginActivity(options:reason:)`。宠物的帧率应该同时受这三者约束。

> ⚠️ 这一条必须在选定渲染栈**之前**用 `sudo powermetrics --samplers cpu_power,gpu_power -i 1000` 实测一次。调研环境拿不到 sudo，所以这是唯一一个还没关闭的定量风险。能耗是最可能导致卸载的因素（出现在"正在使用大量能量"列表里），而且它是架构选择，事后改不了。

**权限阶梯**（这是最大的转化杠杆）：

- **零权限即可**：画面板、读 `~/.claude/**` 和 `~/.codex/**`、FSEvents、状态栏项、**鼠标移动/按下的全局监听**、开机自启（`SMAppService`）、读 Focus 状态（`~/Library/DoNotDisturb/DB/Assertions.json`）
- 需要 **Accessibility**：全局**键盘**监听、`CGEventTap`、读别的 app 的窗口 —— P2 的全局快捷键才需要
- 需要 **Automation**（每个目标 app 弹一次）：AppleScript 控制终端 —— P2 的跳转才需要

> P0 和 P1 一个 TCC 弹窗都不出。冷启动就弹 Accessibility 是菜单栏工具第一大流失点。

---

## 6. 里程碑

### P0 — 只读监控（MVP，目标 2–3 周）

**验收标准：装上就能用，不改用户任何配置文件，不弹任何权限。**

- [x] `SessionRegistry`：FSEvents 监听 `$CLAUDE_CONFIG_DIR/sessions/`，存活校验（启动时刻为准，进程名兜底）
- [x] 五状态基线：`dormant` / `busy` / `shell` / `idle` / `waiting`（+ `waitingFor` 文案）
- [x] `dormant` 睡眠：暂停 displayLink；`dormant → busy` 的唤醒动画
- [x] 淡出：仅 `dormant` 触发（**`idle` 不淡**，有测试锁死），10 分钟 → `alphaValue 0.25`，悬停/唤醒即恢复，淡出态仍可点击拖拽
- [x] `PetPanel` + `DockedPanel`，⌃⌥⌘P 切换，多屏按 CGDisplay UUID 记忆
- [x] 精灵图渲染 + displayLink 限帧 + 遮挡/低电量/过热降级
- [x] 注意力升级器：五级阶梯 + 基于 `statusUpdatedAt` 的时间升降
- [x] 会话名牌 —— **实现与原计划不同，见下**
- [x] 性能测试：见 §5.1

> **名牌的实现偏离**：原计划是 `name` → `ai-title` → `cwd` basename 的回退链。但 `name` 字段几乎总是存在（如 `agent-monitor-e8`），那条链里 `ai-title` 永远轮不到。
> 实际做成两个独立字段更有用：`displayName`（`name` → basename，**保证有值**）作卡片标签，`title`（`ai-title`，可能没有）作内容描述——它是模型写的、对人可读的一句话，比如「设计桌面宠物助手和任务监测系统」。
> 代价：`title` 要按 sessionId 去 `projects/*/` 搜（slug 有损不可逆，算不出路径），且只读 transcript 末尾 256KB。所以它是**尽力而为**的，缓存 + 120 秒重试，拿不到就只用 `displayName`。

**快捷键用 Carbon `RegisterEventHotKey`**，不是 `CGEventTap` —— 前者**不需要 Accessibility 授权**，这样 P0「零权限」的验收标准才守得住。默认 ⌃⌥⌘P 故意选得冷僻：某竞品占了 `Ctrl-U`，把每个终端的 readline kill-line 都吞了。

**P0 明确不做**：审批、终端跳转、Codex、额度显示、hook 安装。

### P1 — 丰满状态 + 多 agent（目标 +3–4 周）

- [ ] 可选 hook 安装（`type: "http"` 指向 `127.0.0.1:<port>`，避免每次工具调用 fork 一个 shell）
- [ ] 完整 13 状态模型（含 `compacting` / `done-error` / `context-critical` / `subagent-swarm`）
- [ ] `away_summary` / `activeForm` 气泡
- [ ] Codex 适配器（`hooks.json` + `app-server` 只读订阅）
- [ ] 声明式 agent 清单格式 + 文档，开放贡献
- [ ] **Agent Teams 多宠物拓扑**（支点 D）
- [ ] 额度显示：**仅当 statusLine 槽位为空**时主动提议填充；已被占用则显示"额度不可用（statusLine 被 X 占用）"并提供一行 tee 脚本让用户自己加

### P2 — 交互（目标 +4–6 周，风险最高）

- [ ] GUI 审批：`PreToolUse` 阻塞 → 本地 socket → 面板 → 返回 allow/deny
- [ ] 终端精准跳转（分层降级，见下）—— **Tier 4（只激活应用）已提前做了**：卡片里点会话行，沿进程树找到宿主应用并切到前台，本机 14/14 会话都能找到宿主。标签页和分屏级别的精确跳转仍在这里
- [ ] 全局快捷键（此时才申请 Accessibility）

---

## 7. 已验证的坑（照着躲）

这一节是整个文档里最值钱的部分。每一条都有实测或一手证据，详见 [docs/RESEARCH.md](docs/RESEARCH.md)。

### 7.1 路径与数据

| # | 坑 | 后果 | 对策 |
|---|---|---|---|
| 1 | **`CLAUDE_CONFIG_DIR` 会重定向一切** | 硬编码 `~/.claude` → 重度用户看到空面板（本机就是 `~/.claude-official`） | 先读环境变量再回退。**且 Finder 启动的 GUI 不继承 shell 导出**，得从运行中的 `claude` 进程用 `ps eww <pid>` 取 |
| 2 | **项目目录 slug 是有损且不可逆的** | 每个非 `[A-Za-z0-9-]` 字符各变一个 `-`。`slug.test_dir 中文 v1.2` → `slug-test-dir----v1-2` | **永远不要反解 slug**。cwd 从 `sessions/<pid>.json`、`history.jsonl` 的 `project` 字段、或 transcript 每行的 `cwd` 取 |
| 3 | **`procStart` 是 UTC，`ps -o lstart` 是本地时间** | 拿它俩比对防 PID 回收 → 在 UTC 以外的**所有时区把每个活会话判成幽灵**。作者在 UTC 开发的话根本测不出来 | 解析成绝对时间再比 |
| 4 | **session 文件大量残留且陈旧** | 17 个文件对应 1 个活进程；同时 13 天没动的文件可能是健康的空闲会话 | **陈旧度不携带任何信息**。只能 `kill(pid,0)` + `ps -o args=` 含 `claude` + 正确的 `procStart` 比对 |
| 5 | transcript 异步落盘且滞后 | `Stop` 时最后一条助手消息不保证已写入；实测活跃工作中 6 秒内文件增长 0 字节 | transcript 只做对账，不做实时信号。要末条消息用 `Stop` hook 的 `last_assistant_message` |
| 6 | 一次 API 响应 = 多行 JSONL | 每个 content block 一行，共享同一个 `message.id` 和 `usage` | 按 `message.id` 去重再求和，否则 token 虚高 2–4 倍 |
| 7 | 1 小时缓存写入是 2.0× 计价，不是 1.25× | 只看 `cache_creation_input_tokens` 会低估约 37%（ccusage 自己踩过，issue #899） | 分开读 `cache_creation.ephemeral_1h_input_tokens` 和 `ephemeral_5m_input_tokens` |
| 8 | 保留期默认 30 天会删掉历史 | 历史图表在第 31 天集体蒸发 | 自己存聚合值。`history.jsonl` 和 `stats-cache.json` 在"永不清理"档 |
| 9 | 临时目录也会有自己的 project slug | UI 里会冒出 `-private-tmp-claude-501--…-scratchpad-hooktest` 这种垃圾条目 | 过滤 |
| 10 | 别写 `~/.claude.json` | 182KB、高频重写、已知损坏风险，Claude Code 自己每次重写都备份 | 只读不写 |

### 7.2 写用户配置

| # | 坑 | 对策 |
|---|---|---|
| 11 | `statusLine` 是标量单槽位，无 merge | 检测到已占用就**不要碰**。要接管只能链式包装并保存原命令，且必须能干净卸载还原 |
| 12 | `hooks` 是数组且跨层级 merge | 追加，绝不替换。所有 `command` 指向自己目录下的一个 wrapper，卸载 = 删掉命令含该前缀的条目 |
| 13 | Claude Code 实时读 settings.json，而且**自己也会写** | 写之前先备份 + `jq` 校验 + 临时文件 rename 原子写 |
| 14 | hook **会热加载进已运行的会话** | 实测注入后 5.99 秒就在下一次工具调用时触发，**不需要重启**。现有工具普遍提示"请重启会话"，省掉这一步就是更好的首次体验 |
| 15 | 企业策略会静默禁用一切 | `allowManagedHooksOnly` 会屏蔽所有用户/项目/插件 hook，并把 statusLine 收归 managed。要检测并显示"你的组织已禁用 hook"，而不是看起来像坏了 |
| 16 | Codex 的 `notify` 也是单槽位，本机已被占 | 用 `Stop` hook（数组，可追加），不要写 `notify` |

### 7.3 审批（P2，全是 fail-open 陷阱）

`PreToolUse` 阻塞式 GUI 审批是**可行的**——实测 35 秒阻塞后返回 `allow`，工具正常执行；45 秒阻塞后 `allow` 让一个需要授权的 `curl` 跑通并返回 200，`permission_denials` 为空；在真实 pty 交互式会话里，40 秒阻塞后原生权限提示**完全没有出现**。

但危险全在失败路径上：

| # | fail-open 模式 | 后果 |
|---|---|---|
| 17 | **超时 ≠ 拒绝** | 超时后走正常权限流程。在 `bypassPermissions` 会话里 = **直接执行**。实测确认 |
| 18 | **hook 脚本没有执行位 = 守卫静默失效** | 实测 `chmod -x` 后工具照跑，零拒绝记录。已知未修 bug #94362 |
| 19 | **`hookEventName` 对不上 = 解析失败 = 放行** | 必须回显 stdin 里的 `hook_event_name`，不能写死。调试输出一律走 stderr |
| 20 | **`ask` 在 headless 下是静默拒绝** | 已知 bug #95726。GUI 必须自己产出终态 allow/deny |
| 21 | `auto` 模式下 hook 的 `allow` 可能被 Bash 分类器推翻 | bug #94740。别在 `auto` 模式下把 hook 当唯一闸门 |

**对策**：默认超时是 **600 秒**（不是网上常说的 60），但要显式设 120，并在 hook **内部**设一个更短的死线（如 100 秒），到点主动打印 `deny`。任何 hook 可能死掉的路径（GUI 崩了、socket 没了、app 没装）都必须走 `deny` 分支而不是 error 分支。硬失败用 `exit 2`——它无条件阻塞，连 `--dangerously-skip-permissions` 都盖不过去（实测确认）。

另外白送一个能力：`hookSpecificOutput.updatedInput` 可以**改写** tool_input，也就是"批准，但把这条命令改成这样"，严格强于是非闸门，UI 值得围着它设计。

### 7.4 终端跳转（P2）

调研推翻了最常见的设想：**从运行中的进程读环境变量拿 pane id 这条路基本是死的。**

- 门禁不是 root，是目标进程的 `cs_restricted`。`sudo` **不能**绕过。所以 `/bin/zsh`、`/bin/bash` 这类 SIP 二进制的环境变量**永远读不到**（实测返回 0 个变量，且是成功返回不是报错）。"agent 环境变量为空就去读父 shell"这个 fallback **从根上不成立**。
- 本机 7 个 `claude` 进程，**没有一个**带 `ITERM_SESSION_ID` / `TMUX_PANE` / `WEZTERM_PANE`。Ghostty 1.3.1 导出的四个变量在所有 pid 上**逐字节相同**，零区分度。

**真正可靠的主键是控制终端 tty**，而且不需要读环境变量：`ps -axo pid=,ppid=,tty=,command=` 直接给你 ttys035/044/063…

**正确做法是注入而非提取**：在 hook 触发的那一刻，它继承了 agent 的完整环境，此时把 `ITERM_SESSION_ID` / `TMUX_PANE` / `WEZTERM_PANE` / `KITTY_WINDOW_ID` / `TERM_PROGRAM` / `__CFBundleIdentifier` 快照进一个以 session_id 为键的 sidecar JSON。sidecar 比环境变量严格更好——环境变量是 exec 时刻的快照，pane 移动后就悄悄失效了，sidecar 可以刷新。

分层降级，并且**在 UI 上诚实标注每个会话处于哪一层**（把最大的局限变成信任信号）：

```
Tier 1 精确 ID   iTerm2 / WezTerm pane-id / kitty window-id / tmux pane / zellij
Tier 2 tty 匹配  Terminal.app
Tier 3 启发式    Ghostty（cwd/标题匹配）
Tier 4 仅激活app Warp / Alacritty / Hyper / Zed / VS Code / Cursor
Tier 5 复制命令  「复制 cd 命令」—— 一行代码，永不失败
```

> 一个可占的差异化：Ghostty 没有 per-pane 环境变量，所有人都退化到模糊 cwd 匹配。可以用 **OSC-2 标题探针**——hook 触发时往捕获到的 tty 写一个唯一 token 作为标题，用 AppleScript 枚举 `name contains token` 找到 surface UUID，缓存后恢复原标题。这能把 Ghostty 从 Tier 3 提到 Tier 1。

---

## 8. 开源策略

**许可证：MIT 或 Apache-2.0。** 理由：clawd-on-desk 是 AGPL——选宽松许可是对着它的可组合性打。目标是成为**标准**，不是成为另一只宠物。

**架构上的开源决策**：把状态引擎做成一个**独立的本地守护进程 + 有文档的事件流**，宠物只是其中一个渲染器。

调研发现了一整个"非屏幕环境显示"的影子市场——有人把 agent 状态推到**电子墨水屏、Kindle、MQTT、键盘 LED、托盘灯、tmux 状态栏、Wayland/QML shell、Android**。这是需求本质是"外围感知"而非"可爱角色"的最强证据。

这么做一石二鸟：
1. 团队里那个觉得卡通宠物不专业的人，可以用同一个守护进程跑菜单栏小圆点 —— 在组织层面中和了专业性质疑；
2. 这是成为标准而不是成为第 26 只宠物的唯一路径。

**兼容而非分裂**：实现 petdex 的 `pet.json` 格式，把多出来的状态名提 PR 回去。

**向上游走**：给 Warp 提 `WARP_SESSION_ID` + `warp://session/<id>`（issue #8611 开着）、给 Ghostty 提 per-surface 环境变量。这两个小改动能让精准跳转变得平凡正确——**当那个把它们推上游的人，比当那个 hack 得最狠的人，定位好得多。**

**要准备好回答"没有护城河"这个质疑**——它杀死了同类最高分 Show HN 的讨论。站得住的答案是：(a) 升级阶梯和验证信号是产品判断力，周末复刻品没有；(b) 零 hook 被动架构是合规主张；(c) Agent Teams 拓扑要求正确读四种未文档化的磁盘格式。**"它可爱且跨平台"不是答案。**

---

## 9. 未决问题

| # | 问题 | 影响 | 怎么关掉 |
|---|---|---|---|
| 1 | **能耗未实测** | 最可能导致卸载，且是不可事后修改的架构选择 | 选渲染栈前跑 `sudo powermetrics`。**这是 P0 的阻塞项** |
| 2 | macOS 15 上的置顶行为未验证 | 调研机器是 26.2；唯一找到的 15.0.1 报告是失败案例 | 首次启动做运行时自检（造一个全屏 Space 看 `isOnActiveSpace`），失败就降级成菜单栏形态 |
| 3 | `sessions/*.json` 的 `status` 完全无文档 | 只观察到 4 个值和 1 次转换；写入时机和持久性未知 | 拿一个会话跑穿权限提示、compaction、崩溃，把真实状态机枚举出来 |
| 4 | 共存问题：用户同时装了别的监视器怎么办 | 本机已有 claude-hud + OpenUsage。两个监视器抢 statusLine、抢审批、都装 hook | 需要明确的"检测到已有 X"设计。目前所有竞品都没有 |
| ~~5~~ | ~~空状态~~ | **已关闭**：`dormant` 睡觉 + 常驻淡出，规格见 B.1 | — |
| ~~1~~ | ~~能耗未实测~~ | **大部分关闭**：渲染栈已选定并实测（§5.1/§5.2），精灵缓存把 24fps 从 3.55% 压到约 0.5% | 只剩一件事：在**空闲机器**上复测绝对值 |
| 6 | 没有任何留存数据 | 新鲜感过去后宠物会不会被关掉，无人测量过 | — |
| 7 | 没有 A/B：宠物 vs 刘海栏 vs 菜单栏圆点 | "发现阻塞 agent 的耗时"和"误报率"的对比实验，公开资料里**不存在** | 自己跑一个。**发表它本身就是这个品类最强的营销资产** |

---

## 附：命名

`agent-monitor` 是仓库名，不是产品名。产品名待定——建议往"外围感知"而不是"宠物"的语义走，因为定位要求不卖可爱。
