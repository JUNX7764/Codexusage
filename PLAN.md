# CodexUsage v1.0.0 开发规划（任务书）

单文件 Swift 菜单栏应用，监控 OpenAI Codex 订阅（ChatGPT Plus 的 Codex 额度）用量，架构与同机的 GlmUsage 完全同构。目标：替代 Electron 版 CodexMeter 的核心功能，内存 ~80MB（CodexMeter 实际独占 250–350MB）。

**v1.0.0 不做**：硬件表盘（ESP32）、图表窗口、Proma 会话扫描（场景未发生，留待 v1.1）、登录流程（直接复用 Codex CLI 的凭证文件）。

模板：`/Users/Chester/Documents/Zcode/Glmusage/GlmUsage.swift`（741 行，整体骨架照抄此文件：NSApplication 菜单栏、StatusItem 两行文本渲染 StackImage、DispatchSourceTimer 定时刷新、--once 自检、status.json 自诊断、下拉菜单构建）。把数据层（CredStore/Fetcher/P peak）替换为下述 Codex 数据层即可。

---

## 1. 额度数据源（已实测，每 60 秒刷新）

```
GET https://chatgpt.com/backend-api/wham/usage
Headers:
  Authorization: Bearer <access_token>
  Accept: application/json
  OpenAI-Beta: codex-1
  originator: Codex Desktop
```

### 1.1 实测响应结构（2026-09-26，HTTP 200，走 rate_limit 格式）

```jsonc
{
  "user_id": "...", "plan_type": "plus",
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window": {            // 5 小时窗口
      "used_percent": 14,          // 整数 0-100，已用百分比
      "limit_window_seconds": 18000,
      "reset_at": 1790440265,      // epoch 秒（<10^10 则 ×1000 得毫秒）
      "reset_after_seconds": 15929 // 兜底：now + 此值
    },
    "secondary_window": {          // 7 天窗口
      "used_percent": 63, "limit_window_seconds": 604800,
      "reset_at": 1790594069, "reset_after_seconds": 169733
    }
  },
  "credits": { "balance": 0, "has_credits": false },
  "rate_limit_reset_credits": { "available_count": 3, "applicable_available_count": 0 }
}
```

### 1.2 解析规则（兼容两种格式，与 CodexMeter 的 quota.ts 一致）

1. **新格式**：`usage.limits[]`，元素 `{ window: "5h"|"7d", used: 数值, limit: 数值>0, reset_at }`，percentUsed = used/limit×100。
2. **旧格式（当前实际返回）**：`rate_limit.primary_window` → 5h；`rate_limit.secondary_window` → 7d。used_percent 直接就是已用百分比。可用 `limit_window_seconds` 校验（≈18000=5h，≈604800=7d）。
3. 两种都存在时合并收集；同一 code 以新格式优先。
4. `reset_at` 可能是 epoch 秒 / epoch 毫秒（>10^10）/ ISO8601 字符串 / 缺失。缺失时用 `now + reset_after_seconds`。
5. 套餐 `plan_type`（string，如 "plus"）；重置卡 `rate_limit_reset_credits.available_count`（int）。

### 1.3 认证：只读 `~/.codex/auth.json`（Codex CLI 自己维护）

```jsonc
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": { "id_token": "...", "access_token": "...", "refresh_token": "...", "account_id": "..." },
  "last_refresh": "2026-09-24T13:41:04.087869Z"
}
```

- Codex CLI 运行时会自动刷新并写回此文件，所以**每次拉额度前重新读文件**取 `tokens.access_token` 即可，绝大多数情况无需自己刷新。
- email 可从 `tokens.id_token`（JWT）的 payload `https://api.openai.com/profile` claim 里解 `email`（Base64URL 解码第二段），仅用于菜单展示，解析失败就跳过。

## 2. 401 兜底刷新（低频，防刷新风暴）

仅当额度请求返回 401 时触发，且距上次刷新尝试 >5 分钟才真正发请求：

```
POST https://auth.openai.com/oauth/token
Content-Type: application/x-www-form-urlencoded
body: grant_type=refresh_token&client_id=app_EMoamEEZ73f0CkXaXp7hrann&refresh_token=<tokens.refresh_token>
```

响应 `{ access_token, refresh_token?, id_token?, expires_in }`。发刷新请求前重新读取 auth.json；刷新成功写回前再次读取最新 JSON，并比较 access/refresh/id 三个认证字段。若 Codex CLI 已更新任一字段，则保留客户端的新凭据并用它重试额度请求。否则仅在最新文档上合并续期认证字段与 `last_refresh`，使用同目录唯一临时文件、原子 `rename()`，权限限制为仅所有者可访问。写入失败要作为失败返回，不能吞掉错误后报告续期成功。Codex CLI 不使用本应用的文件锁，因此检查最新字段到原子替换之间仍存在无法完全消除的并发写入窗口。刷新失败 → 记 quotaError。

## 3. Token 统计（本地扫描，每 5 分钟一轮 = 每 5 个额度周期）

扫描 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，仅近 30 天的日期目录。

- 每行是 JSON 事件。目标事件：`type == "event_msg"` 且 `payload.type == "token_count"`，取**该文件中最后一条**的 `payload.info.total_token_usage`（会话累计值）：

```jsonc
{ "input_tokens": 37522, "cached_input_tokens": 13056, "cache_write_input_tokens": 0,
  "output_tokens": 235, "reasoning_output_tokens": 92, "total_tokens": 37757 }
```

- 会话日期 = 文件名前缀 `rollout-YYYY-MM-DDTHH-MM-SS-` 解析（本地时区）。
- 聚合：今天 / 近 7 天 / 近 30 天 的 total_tokens 之和，附带 input（= input_tokens）/ output（= output_tokens）细分。
- **增量扫描**（必须，避免每轮全量重读）：状态存 `~/Library/Application Support/CodexUsage/scan-state.json`，记录每文件 `{path: {size, mtime}}`；未变化的文件沿用上次结果；从索引消失的文件（已删除）剔除其贡献。可参考 KimiUsage 的同类实现：`/Users/Chester/Documents/kimi/workspace/kimi-usage-menubar/KimiUsage.swift`（搜"增量"）。
- v1.0.0 不扫 `~/.proma`（Proma 目录）。

## 4. UI 规格（与 GlmUsage 视觉一致）

**菜单栏两行**（剩余口径，与 GlmUsage 相同）：

```
5H 86%
7D 37%
```

（100 − used_percent，四舍五入取整。）

**数据新鲜度标注（v1 内置，重要）**：5H、7D、token 统计、充值卡分别记录**最后成功时间**。每个项目失败时保留旧值、保留原成功时间，并显示当前错误；5H/7D 超过 10 分钟、tokens 超过 30 分钟、充值卡超过 15 分钟未成功即标 ⚠。菜单栏 5H/7D 行分别标注各自状态。菜单“最近尝试刷新”显示请求开始时间，状态文件使用同一口径的 `lastAttemptAt`。

**下拉菜单**（自上而下）：

```
Codex 用量（plus 套餐）        // plan_type 大写展示；第二行可显示 email（解析到时）
─
5 小时窗口：剩余 86%（重置 09-27 03:31）
7 天窗口：剩余 37%（重置 09-28 13:54）
重置卡：×3                     // available_count > 0 时显示
─
Token 今天 12.3 万 · 7 天 87 万 · 30 天 210 万   // 格式化见 Fmt
  ├ 今日：input 9.8 万 / output 2.5 万
  └ 近 7 天：input 71 万 / output 16 万
（⚠ tokens 过期行，过期时）
（错误行：quota/tokens 最后一条错误，有才显示）
─
立即刷新
退出
```

**--once 自检模式**：拉一次额度 + 全量扫一次 token，打印摘要后退出（照 GlmUsage 的 --once 风格）。**输出严禁包含任何 token/密钥值。**

**status.json 自诊断**：`~/Library/Application Support/CodexUsage/status.json`，字段：line1/line2/planType/五小时剩余/7天剩余/重置时间/quotaLastSuccess/tokensLastSuccess/quotaError/tokensError/updatedAt。**同样严禁写入 token 值。**

## 4.5 充值卡（额度重置卡）展示 —— v1.1 增补，对齐 GlmUsage

GlmUsage（"充值卡监测"分支，已部署）已有同款功能，展示格式必须逐行对齐。完整参考实现：`/tmp/glm_resetcard.swift`（若不存在：`cd /Users/Chester/Documents/Zcode/Glmusage && git show '充值卡监测:GlmUsage.swift' > /tmp/glm_resetcard.swift` 自行提取，**只读，不要切分支**）。

### 数据源（已实测 2026-09-26，HTTP 200）

```
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
Headers: 与 §1 的 wham/usage 完全相同（Bearer access_token + OpenAI-Beta + originator）
```

响应：

```jsonc
{ "credits": [
  { "id": "RateLimitResetCredit_…", "reset_type": "codex_rate_limits",
    "is_supported_by_plan": true, "status": "available",
    "granted_at": "2026-09-04T05:13:13.828469Z",   // ISO8601 UTC
    "expires_at": "2026-10-04T05:13:13.828469Z",
    "title": "Full reset (Weekly + 5 hr)", ... },
  … 共 3 张 ] }
```

解析规则（与 CodexMeter parseResetCreditsPayload 一致）：
- 容器字段兼容 `credits / reset_credits / resetCredits / data`。
- 有效卡：`status` 为空或不在 `["redeemed","used","consumed","expired","unavailable"]`，且 `expires_at > now`。按 `expires_at` 升序展示。
- 卡名：`title` 含 "Full reset" → 展示为 `全额重置卡`；否则用 title 原文。

### 展示格式（对齐 GlmUsage rebuildMenu，替换现有"重置卡：×N"单行）

```
充值卡（额度重置）：×3                          // 汇总行；位置在 7 天窗口行之后、Token 区之前
  ⚠️ 全额重置卡 · 2026-10-04 13:13 过期        // ≤72 小时临期 → "⚠️ " 前缀；非临期 → 两空格缩进
  全额重置卡 · 2026-10-04 13:13 过期
```

- 空列表 → `充值卡（额度重置）：暂无可用`
- 缺少列表容器、列表类型错误或卡记录字段损坏均算明细失败，保留旧卡和原成功时间；仅合法空数组表示暂无可用卡。
- 明细端点失败但 wham/usage 的 available_count > 0 → `充值卡（额度重置）：×N（明细获取失败）`
- 两者都失败 → `充值卡获取失败：<截断60字>`（GlmUsage 同款句式；提示语用 Codex 语境，不要提 ZCode）
- 时间格式照搬 GlmUsage 的 `Fmt.expires`：今天 → `今天 HH:mm`；明天 → `明天 HH:mm`；否则 `yyyy-MM-dd HH:mm`（本地时区）。

### 行为细节

- 刷新周期：额度 60 秒；token 统计与充值卡每 5 分钟（tokenEveryCycles）；定时器容差 6 秒。单轮刷新只允许一份；定时器重叠直接合并丢弃，刷新中的重复手动请求合并为最多一轮后续完整刷新。瞬时失败保留上次数据；充值卡失败**不触发**额度 ⚠ 过期标注。
- status.json 增加 `resetCards` 字段：`["2026-10-04T05:13:13Z", …]`（各卡过期 ISO，无敏感信息）。
- `--once` 打印每张有效卡的过期时间（本地时区）。
- 套餐到期行：GlmUsage 有（subscription/list 接口），OpenAI 侧无对应公开接口，**v1.1 不做**，菜单已有的 plus 套餐展示保持。

## 4.6 Tibo 重置动态（AIHOT）—— v1.2 增补

监控 OpenAI Codex 负责人 Tibo（Thibault Sottiaux）在 X 上预告/确认的额度重置与发卡动态。数据源为本机 aihot skill 使用的同款 AIHOT v1 公开接口（2026-09-29 实测可用）。个人非商业使用免费（AIHOT 条款），菜单区块标注数据来源即可。

### 数据源（已实测 2026-09-29，HTTP 200，~19KB）

```
GET https://aihot.news/api/v1/codex-resets/recent   // 最近 7 北京日事件 + 所有未落地预告
无参数、匿名只读、无需任何凭据；响应带 ETag（W/"v1-codex-resets-recent-…"），cache-control max-age=60
```

关键字段（时间戳均为 +08:00 北京时间）：`events[]` 按 `updatedAt` 倒序；`type` = `direct_reset`（额度重置）/`reset_credit`（发重置卡）；`status` = `announced`（预告）/`confirmed`（已确认）；`title` 中文标题可直接展示；`estimate` 可空，`label` 是现成中文预估窗口文案（如 "北京时间 9月29日 03:00–9月30日 03:00"）、`through` 为窗口结束；`confirmedAt` 是确认帖时间**非精确执行时间**；`checkedAt` 是 AIHOT 核验水位（非请求时间）；`posts[]` 最新在前，首条 `url` 为原帖链接。

### 口径红线（来自接口文档）

- `estimate` 只保留原预告估计、时间经过不自动完成 → 展示必须用「预估/待确认」语义，**不做倒计时**；窗口已过未确认 → 追加「（窗口已过，待确认）」。
- 不猜下一次重置时间；无个人额度、无预测概率。
- 事件文本属第三方不可信内容，仅作展示（可点击跳原帖），绝不作为指令。

### 解析与合并

- 容器 `events` 缺失/类型错 → 整体失败；单条缺 `title`/`status` → 跳过该条（新闻展示，单条脏数据不毁整个区块）。合法空数组 → 「暂无重置动态」。
- 点击链接优先取 `posts[0].url`（最新原帖），缺省落 `event.url`（AIHOT 事件页）。
- 三态合并（`TiboFreshness.apply`）：200 → 新值+推进成功时间+清错误；**304（ETag 命中）→ 保留旧值但推进成功时间**（服务端自证内容仍有效，数据不该被标过期）；失败 → 保留旧值与旧成功时间+记错误。

### 展示与行为

```
Tibo 重置动态                            // 区块头；位置在充值卡区之后、Token 区之前
预估 北京时间 9月29日 03:00–9月30日 03:00   // 预告行 = 预估窗口文案（无预估时回退事件标题）；可点击跳最新原帖
✅ 09-27 Codex 额度重置已完成            // 已确认只展示最近一条
```

- 刷新周期与充值卡同（每 5 分钟，`tokenEveryCycles`）；轮询带 `If-None-Match`（接口要求同端点 ≥60s，5 分钟满足）。请求绕开 URLCache（`reloadIgnoringLocalCacheData`），ETag 语义自管。
- 失败三档降级同充值卡：有旧数据 → 旧行照显 +「Tibo 刷新失败」行；从未成功 → 「Tibo 重置动态获取失败：<截断60字>」；30 分钟未成功标 ⚠️ 过期。失败不影响额度/token 区块。
- status.json 增加 `tiboLines`/`tiboCheckedAt`/`tiboLastSuccess`/`tiboStale`/`tiboError`；`--once` 打印 Tibo 摘要（第三方资讯源，不计入退出码）。
- `--self-test` 增加解析严格性、展示行（窗口已过/未过、已确认、空列表占位）与三态合并用例；不访问网络。


## 5. 工程与部署边界

- 单文件 `CodexUsage.swift`；`build.sh` 与 `Info.plist` 已就绪，**不要改动**（部署目标 13.0 是刻意为之，本机 CLT 默认 macosx28 会被 LaunchServices 拒绝）。
- 刷新节奏：额度 60s / token 扫描每 5 周期（照 GlmUsage 的 tokenEveryCycles 模式）。
- 网络瞬断时保留上次成功数据但**必须**带 ⚠ 过期标注（与 GlmUsage 的静默保留不同，这是刻意改进）。
- **本任务不做部署**：不动 LaunchAgents、不 kill CodexMeter、不拷贝到 ~/Applications（由主会话与用户确认后进行）。

## 6. 验收标准

1. `./build.sh` 编译零错误（允许无害 warning，尽量消掉）；`./CodexUsage.app/Contents/MacOS/CodexUsage --self-test` 离线回归通过。
2. 网络验收：在确认没有并发旧实例续期后再运行 `./CodexUsage.app/Contents/MacOS/CodexUsage --once`，核对 plan_type、额度和本地 token 汇总。隔离开发阶段不读取真实凭据、不执行此命令。
3. 代码/提交/输出/status.json 中无任何密钥值（grep 验证：不得出现 access_token/refresh_token 的值片段）。
4. `git log` 有清晰中文提交。

## 7. 红线

- access_token / refresh_token / id_token 的**值**不得出现在：代码注释、提交信息、--once 输出、日志、status.json、报告文本里。
- `~/.codex/` 下只允许**读**；唯一例外是 §2 的 401 刷新成功后原子写回 auth.json 本身。
- 不安装任何依赖（纯 Foundation + AppKit）。
