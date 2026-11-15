# 模型响应卡 + 缓存命中卡（第 8/9 张可选卡）Implementation Plan

**Goal:** 新增两张独立可选卡片，共用同一次 rollout 扫描扩展，一趟解析同时产出两组统计：

1. **「模型响应」卡**：按周期（今天/近7天/近30天）展示各模型端到端响应速度（加权 tok/s）与中位耗时。
2. **「缓存命中」卡**：同周期展示整体（周期汇总行）与各模型的缓存命中率与输入量。

数据只读本机 Codex rollout（`~/.codex/sessions/` 的 JSONL 与 zst 归档，**现有数据源，无新增**），不新增网络请求与定时器，挂现有 5 分钟 token 扫描周期。两卡进入现有「···」显隐/排序设置列表，默认可见、按「模型响应 → 缓存命中」排在末两位。

**Architecture:** 在 `TokenScanner` 现有扫描趟内新增并行统计管线：以 `token_usage_record`（逐请求终值记录）为唯一统计源，按 `turn_context` 流式归属模型，用 `task_started`/`tool_call_output` 事件时刻重建每请求端到端耗时；**现有 `token_count` 差分管线（用量情况数字）零改动**。State 升 v4 整体重扫（归档覆盖 30 天窗口，重扫代价秒级）。两卡视图复用 `TokenSection` 体系（`PanelSectionHeading` + `TokenDetailRow` + bucket 展开行），仅扩展列标题通道，确保与其他卡片视觉完全对齐。离线回归用临时 fixture 会话先行写失败断言。

**Tech Stack:** Swift、AppKit、既有 vendor zstd 解码、现有 `build.sh` / `--self-test` / preview 回归，无新依赖。

---

## 数据事实（2026-11-15 本机实测，实现前无需重验，口径注释须引用）

- 记录类型 `token_usage_record`：每 response 一条，payload 含 `thread_id/turn_id/root_turn_id/response_id` 与 `usage`（字段：`input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens`），envelope `timestamp` 为 ISO8601 毫秒精度。**`usage` 是逐请求终值**，`turn_token_usage/thread_token_usage` 是累计值（不得求和）。
- **`cached_input_tokens ⊆ input_tokens`**（实测 6912⊆32234 等多例反例为 0）；`cache_write_input_tokens` 本机当前全为 0 但字段存在，不得假设恒为 0。
- **`token_usage_record` 与 `token_count` 1:1 共存**（11-13/14/15 会话实测 5/5、13/13）——两源叠加必双计，解析必须二选一（本方案：record 为源，`token_count.last_token_usage` 仅作整文件级回退）。
- **needle 红线**：现扫描器逐行预筛只 JSON 解析含 `"total_token_usage"` 或 `"turn_context"` 子串的行；`token_usage_record` 行不含 `"total_token_usage"` 子串（payload 键为 `usage/turn_token_usage/thread_token_usage`），不加 needle 会被整类静默跳过。
- **时间边界代理**：rollout 无流式 delta（`_delta` 事件实测 0 条），无 first_token_at/completed_at/time_to_first_token_ms 等价物——**decode tok/s 与 TTFT 不存在于 Codex 数据**。可重建的是端到端耗时：请求起点 = turn 内首请求取 `task_started`、后续请求取最近一次 `tool_call_output`（`custom_tool_call_output`/`function_call_output`）时刻，终点 = record 时刻。已用真实会话验证：10.2s 长工具被正确排除（usage→tool_out 10.2s→下一 usage 6.1s）；紧贴 TASK_START 的 1ms 注入输出（environment_context 类）作边界不引入误差。
- 本机近 30 天基线（93 个文件含全部 zst 归档，4547 有效请求，零解析异常）：gpt-6.1-terra **23.8 tok/s**/中位 5.3s/缓存 99%、gpt-6.1-sol **31.0**/9.5s/98%、gpt-6-astra **28.0**/5.9s/98%、gpt-5.6-terra **23.7**/4.3s/80%。
- **口径警示**：端到端 tok/s 含 prefill+首字+网络+decode 全程（单请求输入普遍 40k~65k），与 zcode-tps/GlmUsage 的 decode 口径（58~153 tok/s）**系统性偏低且不可比**；跨模型比较受请求结构混杂（sol 单请求输出均值 478 vs terra 227，输出大者 decode 占比高）。中位耗时是更稳的体感指标，故主展示耗时。
- 本机 30 天窗口内所有含请求的会话均有 `token_usage_record`；`token_count.last_token_usage`（同为逐请求口径，含 cached 字段）回退仅为更旧归档兜底。
- 无运行态过滤需求：rollout 只记已完成请求；取消请求若落 record 则按实际用量计入（README 注明）。

## 口径定义（实现必须逐条对齐，不得自行发挥）

**通用（两卡共享）：**

- 统计源：`token_usage_record.usage`（逐请求值）；整文件级回退 = `token_count.info.last_token_usage`（文件内出现过任一 record 即不回退；两源都无则该文件零贡献；旧格式只有累计 total 的不造 0）。
- 模型归属：流式跟随最近 `turn_context`（复用现有 `entry.currentModel` 机制）；无标注归「未知模型」。
- 无效记录整条剔除（timing 与缓存都不进）：`dur ≤ 0`、`dur > 900s`（挂起/休眠污染守卫）、`input_tokens ≤ 0`。**两卡「请求」列 = 有效记录数，同源一致。**
- 窗口：事件本地日（`dayFmt` + 文件名回退，复用现有机制），含今天共 7/30 个日历日（与 TokenScanner 现口径一致）。
- 解压失败 → 该文件本轮不读（现有语义）；空窗口 → UI「本周期暂无用量」，不静默造 0。
- 显示名不做大小写归一（Codex 模型名大小写稳定，实测 4 个模型名各自唯一）；仅 trim 空白（对齐现有）。

**响应卡：**

- 加权 tok/s = `SUM(output_tokens) / SUM(dur)`（分母秒），显示整数；按模型分组汇总口径，不做单请求平均。
- 中位耗时 = 8 桶直方图（秒级上界 [1,2,4,8,16,32,64,900]）累积插值派生，显示一位小数秒（`5.3s`）。
- 排序：按窗口内 SUM(output_tokens) 降序。无常驻脚注（对齐「每日用量」无脚注既有决定）；端到端口径说明进 README，不进卡片。

**缓存命中卡：**

- 模型命中率 = `SUM(cached_input_tokens) / SUM(input_tokens)`（input 为含缓存总输入）；整体命中率 = 全模型合计比值，即周期汇总行（bucket 行）本身——**不另设「整体」明细行**（对齐用量情况的周期汇总视觉，与 GlmUsage 版差异点）。
- 命中率显示整数百分比（`96%`）；输入量复用 `Fmt.tokensAbbr`（`328M`/`864K`）。
- **`—` 规则**：窗口内该模型无任何 `cached > 0` 或 `cache_write > 0` 的行 → 命中率显示 `—`（区分「没有缓存数据」与「0% 命中」），不影响其他行；全模型无证据 → 汇总行同规则。
- 排序：按窗口内 SUM(input_tokens) 降序（缓存与输入量直接相关）。

## 已确认范围与不可变边界

- 两卡显示名「模型响应」「缓存命中」，默认可见，默认顺序：… → 工具明细 → 模型响应 → 缓存命中；可经「···」隐藏/排序，恢复默认包含两卡。存量布局 JSON 无需迁移（`PanelCardLayout.init` 规范化自动补末尾）。
- 现有 `token_count` 差分管线（`entry.previous`/`days`/`daysByModel` 及用量情况全部数字）**零改动**；新统计在 `FileEntry` 新增独立字段、独立聚合，绝不与累计差分混算。
- 同一次扫描趟产出两卡数据（`Result.today/seven/thirty` 各扩展 runs 字典），挂现有 5 分钟扫描周期；无新定时器/网络请求/数据源，不碰凭据/钥匙串。`loadState` 缓存与 `NSLock` 机制不动，vendor zstd 桥不动。
- 其他 7 张卡片布局、数据、交互零改动；`PanelCustomization.swift` 仅因枚举新增 case 被动扩展。
- 首版不做：单请求明细列表、按天趋势展开、decode/TTFT 口径（数据不存在）、菜单栏实时速度、缓存写入量独立展示。
- 离线回归与 preview 不读真实会话、不联网、不写生产 state（fixture 一律临时 `statePath`/临时 root）。
- `AGENTS.md` 仅更新「主体按…排列」一行（板块数变化），不追加本功能细节。执行以实际符号为准，不机械依赖行号。

## UI 规格（视觉对齐硬约束）

```text
模型响应                          [⌄]
周期        tok/s     耗时    请求
› 今天        24      5.3s     12
⌄ 近 7 天     24      5.3s   4383
    gpt-6.1-sol      31    9.5s  1030
    gpt-6.1-terra    24    5.3s  3370
    …
缓存命中                          [⌄]
周期        命中      输入    请求
› 近 7 天    99%     328M   4383
› 近 30 天   99%     494M   4547
```

- **两卡整体复用 `TokenSectionView` 结构**：`PanelCardView(padding: 8)`（经 `makeCardSection`）+ `PanelSectionHeading`（12pt semibold 标题 + 14pt symbol + chevron）+ `TokenDetailRow` 表头 + 周期 bucket 行（今天/近 7 天/近 30 天，悬停 0.08 高亮、可展开、键盘可达）+ 展开后的 modelDetail 行（9pt 截断模型名 + 10pt 右对齐数值，monospacedDigits）。
- 实现路径：`UsagePanelModel.TokenSection` 增加可选 `columnTitles`（默认 `["周期","总量","输入","输出"]` 不变，既有卡零视觉变化）；列定义——响应卡 `["周期","tok/s","耗时","请求"]`、缓存卡 `["周期","命中","输入","请求"]`。
- 数值语义映射（bucket = 周期汇总）：响应卡 total=全模型加权 tok/s、input=全模型中位耗时、output=请求数；缓存卡 total=整体命中率、input=输入量、output=请求数。
- 空态：bucket 无有效记录 → 复用「本周期暂无用量」占位样式与文案；无缓存证据 → `—`；两卡无独立刷新按钮，跟随面板全局刷新。
- accent/symbol：`PanelAccent` 新增 2 case，色值取自现有柔彩色板家族（dynamic provider 深浅色双态，模式对齐 `.external` 实现；**禁止紫蓝渐变**）；`PanelVisuals` 新增 `responseSymbol = "speedometer"`、`cacheSymbol = "arrow.triangle.2.circlepath"`（macOS 13 可用）。
- 展开状态管理（记忆哪些 bucket 展开）对齐 tokens 卡现状（`codexExpanded`/`expandedCodexBuckets` 同款模式）。
- 无新分隔线、无脚注；卡片间距与内边距 8pt 约定不变；区块头无来源后缀、数值行无解释性限定语（文案纪律照旧）。

---

### Task 1: `TokenScanner` 双统计管线 + 失败回归先行

**Files:**
- Modify: `CodexUsage.swift`（`TokenScanner`：needle 常量、`parseLine` 分支、`FileEntry`/`State` v4 字段、窗口聚合、`Result`/`Stats` 扩展；`--self-test` 的 TokenScanner fixture 区追加断言）

**Step 1: 先写失败回归（fixture 会话，模式照抄现有 TokenScanner fixture 与 hermes fixture 断言）**

临时目录 fixture rollout-*.jsonl（与 .zst 帧），逐行构造已知时间戳/字段。断言：

响应：
1. 已知起止时刻两组行 → 加权 tok/s 精确等于手算值（毫秒→秒换算正确）。
2. turn 内多请求边界切分：`task_started` → 请求1 → 长工具（tool_out 隔 10s）→ 请求2 → 1ms 注入输出 → 请求3，三段耗时各自精确；跨 turn（`task_complete` 后新 `task_started`）边界不串。
3. `dur ≤ 0`、`dur > 900s`、`input_tokens ≤ 0` 的记录整条剔除，不出现在任何统计。
4. `turn_context` 切换模型后各请求归新模型；无 `turn_context` 的记录归「未知模型」。

缓存：
5. 加权命中率精确等于手算值（`SUM(cached)/SUM(input)`）。
6. 窗口无缓存证据的模型命中率 = nil（UI `—`）；全部模型无证据 → 汇总行同 nil；`input_tokens ≤ 0` 不进分母。

管线与边界：
7. **双计红线**：同一 fixture 同时含 `token_usage_record` 与 `token_count`，统计只出 record 一份；仅含 `token_count.last_token_usage` 的文件回退一份；旧格式只有累计 total 的贡献为 0。
8. needle 守卫：不含新 needle 子串的行（消息/推理行）不被解析、不产生统计（对齐现有预筛行为）。
9. State v4：v3 状态文件 → 作废整体重扫不崩溃；`FileEntry` arity 校验拒绝坏条目（对齐现有 valid 检查扩展）。
10. 窗口口径：毫秒时间戳按事件本地日归日（`dayFmt`）；周期外行不进统计；zst 夹具（现有真实帧模式扩展 record 帧）与明文结果一致。

**Step 2: 实现管线使回归转绿**

- needle 集：现有 `"total_token_usage"`、`"turn_context"` 之外新增 `"token_usage_record"`、`"call_output"`（同时覆盖 custom/function 两种 tool_call_output）、`"task_started"`。
- `parseLine` 新分支（与现有 `turn_context` 分支并列）：
  - `task_started`：`entry.turnStartTs = ts; entry.boundaryTs = ts`；
  - `*_call_output`：`entry.boundaryTs = ts`（须 ≥ turnStartTs）；
  - `token_usage_record`：`dur = ts − max(boundaryTs, turnStartTs)`；过守卫后写入 `entry.recordDaysByModel[day][model]`（13 值：requests, sumDur, sumOut, sumIn, sumCached + hist[8]），并置 `entry.usageSource = 1`；
  - `token_count` 现分支不动，仅在整文件零 record 且 `info.last_token_usage` 存在时按同样结构记入（`usageSource = 2`，先到先得，append 恢复语义与 `entry.previous` 一致持久化）。
- `FileEntry` 新字段随 `State.version = 4` 落盘（`turnStartTs/boundaryTs/usageSource` 持久化保证 append 增量恢复正确；`recordDaysByModel` 随 `days` 同步按 cutoff30 修剪）。
- 窗口聚合镜像现有 `daysByModel` → `addModel` 模式：`Stats` 新增 `runs: [String: ModelRunStats]`，`ModelRunStats { requests, sumDuration, sumOutput, sumInput, sumCached, histogram[8] }`，派生 `weightedTps`/`medianSeconds`（直方图累积插值）/`cacheHitRate: Double?`。
- 中位耗时插值：累积计数跨过 n/2 的桶内按计数占比线性插值；requests=0 → nil。

### Task 2: 卡片注册与数据接线

**Files:**
- Modify: `Sources/PanelCustomization.swift`（`PanelCardID` 尾部加 `case response`「模型响应」、`case cache`「缓存命中」）
- Modify: `CodexUsage.swift`（buildPanel 卡片 switch 加两分支；`UsagePanelModel` 加两 `TokenSection` 字段；扫描结果装配；preview fixture）

**Step:** 注册两卡（同一次扫描结果喂两卡）；扫描回调处（tokensToday/tokens7d/tokens30d 装配点同区）新增 runs 快照存放（对齐既有 today/7/30 三份存放模式）；离线回归补断言：`PanelCardLayout.default.order == PanelCardID.allCases`（现有断言自动覆盖新 case）、设置列表 9 行、新 case title 正确、旧布局 JSON（7 卡 order）解码后新卡补至末尾。

### Task 3: 两卡视图

**Files:**
- Modify: `CodexUsage.swift`（`TokenSection`/`TokenSectionView` 增加列标题通道；两卡 section 构建与格式化；展开状态管理）

**Step:** `TokenSection.columnTitles: [String]?`（nil = 既有默认，既有卡零视觉变化）；两卡从 runs 快照构建（格式化：`Fmt.tokensAbbr`、tok/s 整数、耗时一位小数秒、命中率整数百分比、请求整数；模型行排序按口径）；展开/收起与悬停高亮零新样式；`--visual-preview` 注入固定假数据（对齐现有 preview fixture 模式），preview 下两卡渲染正确（人工核对布局与对齐）。

### Task 4: 全量验证与文档

- `bash build.sh` 通过（universal 双架构）；`--self-test` 全绿（含新增 10 项断言）。
- 真机验收：两卡出现在面板，数字各抽 2 个模型与手工 `jq` 对拍（附录命令）；隐藏/排序/恢复默认后其余卡片无布局回归；设置列表 9 行；**升级 v4 重扫后用量情况三周期总量与升级前一致**（token_count 管线零回归的直接证据）。
- `README.md`「能做什么」补两条；「统计口径」补：端到端耗时定义（含 prefill/首字/网络，非纯生成速度，与 zcode-tps decode 口径不可比）、有效记录守卫（0<dur≤900s、input>0）、`—` 规则、请求数=有效记录数、取消请求按实际用量计入。
- `AGENTS.md` 主体排列行更新（九板块）；本文档标记实现完成日期。

## 验收清单

- [ ] 回归断言 10 项全绿，fixture 不触真实会话与生产 state
- [ ] 两卡出现在设置列表，默认末两位可见，可隐藏/排序/恢复默认；旧布局 JSON 无迁移问题
- [ ] tok/s、中位耗时、命中率与手工 jq 一致（各抽 2 模型）
- [ ] 挂起/零输入记录不影响任何数字；请求数两卡一致（有效记录数）
- [ ] 无缓存模型显示 `—` 非 0%；空周期显示「本周期暂无用量」，无静默 0
- [ ] **用量情况数字升级前后零变化**；其他 7 卡零回归
- [ ] 无新网络请求、无新定时器、无凭据触碰、无新数据源

---

## 附录：手工对拍基线（验收用）

单文件按模型汇总（替换 F 为具体 rollout 路径）：

```bash
jq -r 'select(.type=="token_usage_record") | [.payload.turn_id, (.payload.usage.input_tokens|tostring), (.payload.usage.cached_input_tokens|tostring), (.payload.usage.output_tokens|tostring)] | @tsv' "$F"
```

配合 `select(.type=="turn_context")` 的 turn_id→model 映射与 `task_started`/`*_call_output` 时间戳手工核算；会话级探测脚本（本次会话 `/tmp/codex_speed_probe/probe.py`，30 天全量）可作为量级参照，验收以手工 jq 为准。

实现完成：2026-11-15（Task 1–4 代码级与全部离线验证由子会话完成，含 fixture 回归 10 项、universal 构建与浅深色 preview 截图；真机验收与部署由主会话执行）
