# 额度周期回顾 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在「用量简析」下方新增「额度周期回顾」原生卡片，按真实观测到的额度轮次比较 100% 上限与已用比例，回看是否用满、到期未用及提前重置前剩余。

**Architecture:** 新增独立的额度周期模型/纯状态机、账户隔离持久化仓库和 AppKit 图表模块；`CodexUsage.swift` 只接入已有额度刷新、用卡操作及面板组装，不继续堆叠周期算法。复用既有请求，不新增轮询，不从 Token 数反推额度；保存可核对的观测证据，无法判定的重置、起止时间及缺口明确标为未知。

**Tech Stack:** Swift / Foundation / CryptoKit / AppKit，现有 `AtomicJSONFile`，macOS 13+ universal 构建，Python unittest 驱动独立 Swift 夹具及原有 `--self-test`，Cua 原生交互验收。

---

## 0. 执行说明与边界

- 本文为待执行计划，不表示功能已经实现或测试已经通过。
- 基线：`b1b11f2`，2026-11-12 核对；实际实施前检查后续变动，使用下面的符号锚点而非机械依赖行号。
- 本计划位于独立 worktree，分支 `plan/quota-cycle-history-20261112`。当前只写计划，不构建、不安装、不消费重置卡、不提交、不推送或发布。
- 模板中的 `superpowers:*` 名称是原 Skill 约定；本工作区实际提供的是 `@executing-plans`，后续按该 Skill 分批执行即可，不安装或假装存在其他 Skill。
- 以下任务的 commit 命令是将来的检查点，仅包含本任务列出的文件。执行会话先检查 `git status --short`；用户要求不提交时保留检查点，不运行 commit。不得加入 Proma 归因。
- 每个编号 Step 是一次 2–5 分钟动作；测试矩阵按一条用例一次的方式推进，构建等待可以长于此。不得将整个 Task 当成一次未经验证的大修改。

### 0.1 已确认的产品方向

1. 新卡片顺序：用量进度 → 重置卡 → Tibo → 用量情况 → 用量简析 → **额度周期回顾** → 工具明细。
2. 每轮两根柱：中性灰为额度上限 100%，`PanelAccent.codex.color` 为已用比例。沿用动态暖橙色：浅色 `#B46539`、深色 `#E5A37D`，不写死两套独立产品主题。
3. 主动用卡、被动提前重置都结束旧轮次；标签区分「正常到期」「主动用卡」「提前重置」「重置待确认」「观测缺口」。外部工具用卡无法仅凭额度推断为“被动官方重置”。
4. 正常到期显示「到期未用」，提前重置显示「重置前剩余」，进行中显示「当前剩余」；不把后两者计作浪费。
5. 历史只用观测到的百分比，不虚构固定 Token / credits 上限，不把不同轮次的百分比简单相加成绝对浪费。

### 0.2 本计划采用的交互默认值

以下是对上一轮建议的落地默认值，用户审阅本计划时可调整：

- 每屏 **6 个周期**，默认最新一屏，当前轮次在最右；不足 6 个按实际数量显示，不填假历史。
- 首批浏览最近 **12 个周期**；可点「更早记录」扩展浏览范围，不设置 12 个周期的存储上限。
- 使用左右翻页按钮，不在已有纵向滚动面板内新增横向滚动区域。按钮具有明确「更早／更新」辅助功能标签。
- 图内只显示精简开始日期，如 `11/06`，不在六组柱子下塞入完整日期、结束原因和剩余三行文本；选中组的两行固定详情展示完整信息。
- 默认选中当前或最新轮次；鼠标悬停临时查看，点击固定选择，左右键逐组查看并可跨页。移出恢复固定选择。
- 独立折叠，默认展开；刷新、关闭重开保留本进程的选择/页位置，重启恢复最新页；切换账号清除选择。
- 卡片展开高度目标 **190pt，上限 210pt**；这是实现目标，需要在真实 330pt 面板实测，不为达标压缩现有卡片字号/行高。

## 1. 代码地图与需要阅读的事实

| 文件 / 符号 | 当前事实与修改目的 |
|---|---|
| `CodexUsage.swift:294` / `QuotaWindow` | 只有 `usedPercent`、`reset`，没有历史，也没有已验证的绝对 Token 上限。 |
| `CodexUsage.swift:560` / `Fetcher.parseUsage` | 读取旧格式百分比及新格式 used/limit 并归一化；无须为本功能扩大额度接口权限。 |
| `CodexUsage.swift:693` / `ResetUseResult`、`parseResetUseResponse` | 当前将 `reset` 和 `already_redeemed` 都折叠成 `.success`；不能据此把“核对旧请求”误记成现在发生的一次新重置。 |
| `CodexUsage.swift:2190` / `UsagePanelModel` | 给面板增加已构造的历史快照，避免视图读磁盘/网络。 |
| `CodexUsage.swift:2219` / `PanelAccent` | `.codex` 已提供动态暖橙色。 |
| `CodexUsage.swift:2840` / `UsagePanelController` | 面板最大 330pt，左右各 16pt；卡片再各内缩 8pt，内部约 282pt。 |
| `CodexUsage.swift:2998` / `rebuildContent` | 在 `makeDailySection` 与 `makeToolSection` 之间插入独立卡片。 |
| `CodexUsage.swift:3430` 附近 / `verifyCardLayoutForPreview` | 当前布局回归按六卡片预期，增加第七卡片时必须同步。 |
| `CodexUsage.swift:3930` / `AppDelegate` | 新增协调器属性；预览实例不得初始化真实历史仓库。 |
| `CodexUsage.swift:4253` / `performRefresh` | 捕获请求时间、账号 identity 与 generation；只有被接受的有效 7d 响应才进入历史模块。 |
| `CodexUsage.swift:4342` / `synchronizeAccount` | 切换历史分区并清除旧账号 UI；迟到读盘/写盘回调不得覆盖新账号。 |
| `CodexUsage.swift:4374` / `applyQuota` | 只用本次 `r.sevenDay` 入账，不能将 `QuotaMerge` 保留的旧值当新样本。 |
| `CodexUsage.swift:4835` / `beginUseReset` | 复用已有用户确认、幂等请求 ID、未知结果核对及刷新；新功能不发起用卡请求。 |
| `CodexUsage.swift:5068` / `SelfTest` | 增加离线集成检查，临时根目录与假账号；不能读取真实 auth。 |
| `Sources/DailyUsageView.swift` | 参考整列命中、鼠标跟踪、键盘、VoiceOver 的已有做法；不要直接改造 30 日日图。 |
| `build.sh:52` | 手动列出 Swift 源文件；新增生产模块后必须同时列入 arm64/x86_64 编译。保留临时 `main.swift` 入口。 |
| `tests/script_test.py` | PATH mock 脚本回归，不是原生图表验收。 |
| `docs/DEVELOPMENT.md`、`docs/project/07-standards.md` | 构建、权限、账号代际和原生验证边界。 |

## 2. 先固定数据口径与不确定性

### 2.1 轮次不是日历周

- “7 天”是接口窗口类别，不保证每个被展示的轮次都完整持续七天。
- 首次启动时，`resetAt - 604800` 只能作为**推算开始时间**，不是观测到的重置时刻。视图必须显示「开始时间推算」或「首次观测」，不能直接说“完整记录了七天”。
- 事件发生在两次成功请求之间时，只记录边界区间；“11/06–11/10，约 4 天”不能伪装成精确四天。
- 关机跨过一个或多个周期，不生成未观测的零用量柱，也不填满缺失周期。旧段结束原因记为观测缺口，新段记为首次观测的新窗口。
- API 返回过去的 reset 时间且尚未给出新窗口时，显示「等待重置确认」，不按本机时钟自动生成新周期。

### 2.2 用量与剩余

业务字段必须使用 `lastObservedUsedPercent` / `remainingAtLastObservation`，不能命名为 `finalUsed` / `wastedTokens`。

- 进行中：`已用 36% · 当前剩余 64%`。
- 正常到期但未采到终点：`最后观测已用 81% · 到期未用约 19%`，详情带最后成功时刻。
- 提前重置：`最后观测已用 72% · 重置前剩余约 28%`。
- 已观测 100% 可标「已用满」；不得因展示四舍五入得到 100 而将 99.6 判定为真正用满。
- 首次观测发生在中途：百分比可展示（接口是本窗口累计），但标记记录不完整，不把首次观测日当作额度起始日。
- 套餐变更、接口窗口不可用、时间回拨、百分比回修都不能默默解释为普通重置。
- 无绝对额度分母，不提供“跨周期总共浪费 X% / X Token”。首版不增加利用率平均值等附加 KPI。

### 2.3 判定参数是本地启发式，不是服务端保证

```swift
struct QuotaCyclePolicy {
    var resetJitter: TimeInterval = 120       // reset_after_seconds 计算与网络时延的容差
    var meaningfulDrop: Double = 1            // 至少下降 1 个百分点，仅用作候选信号
    var confirmationMinDelay: TimeInterval = 10
    var confirmationMaxDelay: TimeInterval = 180
    var maximumContinuousGap: TimeInterval = 15 * 60
    var heartbeatInterval: TimeInterval = 5 * 60
}
```

所有参数通过实例注入，测试不依赖真实 Date()/sleep。上线后不得宣传为百分之百识别官方重置。小于阈值的下降、同截止时间的未知下降可以保持待确认，不强求“永不漏分”。

### 2.4 状态转移决策表（必须先写测试）

| 前后观测 | 处理 |
|---|---|
| 同一 reset、比例不减 | 更新当前轮次，重复请求不加轮次。 |
| reset 仅漂移 ≤120s | 同轮，保留原始时刻；不能不断修改轮次 ID。 |
| 比例下降但 reset 未明显变化 | 记异常候选，不立刻拆段，详情“额度回修／重置待确认”。 |
| reset 明显变化但比例不降 | 记时间变化候选；可能是服务端修正，不直接判提前重置。 |
| 原截止尚未到，reset 明显变化且比例下降 ≥1pp | 第一笔为候选；下一独立请求在 10–180s 内确认同一新窗口且用量不回到旧值，才拆段，原因“提前重置（来源未确认）”。 |
| 候选下一笔回到旧窗口 | 撤销候选，保留异常证据，不留下伪造的已结束轮次。 |
| 正常越过旧截止，新 reset 明显向后、采样间隔 ≤15 分钟 | 用第二笔新窗口样本确认自然轮换；即使用量恰好从 0 到 0，也可判正常到期，边界仍保留观测区间。 |
| 成功消费响应 `code=reset` | 记录已确认的用卡证据，绑定操作 ID 与旧轮次；等后续有效额度样本再生成新段。即便 reset 相同，也允许用卡证据配合已用回落确认，但不能用陈旧的消费前响应。 |
| `already_redeemed` | 仅核对原操作，按原操作时间/ID 去重；缺少原操作时间时不在“现在”生成新边界。 |
| `unknown` / `nothing_to_reset` / `no_credit` | 不创造已确认边界。unknown 仅保留原操作待核对；另两项取消该操作的候选关联。 |
| 用卡成功但下一笔 7d 无任何改变 | 只记操作，不断言 7d 已重置；可能仅重置另一窗口。 |
| 两笔间隔 >15 分钟且窗口已变化 | 旧段结束类型 gap，新段开始未知；不推断漏过几个周期。 |
| 套餐类型发生变化且同时窗口变化 | 归为账户额度变化待确认，不自动当作额度浪费。 |
| 账号变化、旧代际响应、乱序请求 | 拒绝该样本或回调，不写入新账号分区。 |
| 非有限值、越界百分比、缺 reset、请求失败 | 不进入已确认状态机；错误状态可更新，但不能制造 0%/100% 记录。 |

注意：Tibo 是第三方公共公告，不是当前账号额度执行证据，不能用它确认个人账户的重置或原因。轮次“来源未确认”不等于“官方被动重置已证实”。

## 3. 文件与接口契约

### 新文件

- `Sources/QuotaCycleHistory.swift`：Foundation 模型、参数、候选/确认状态机、浏览窗口计算、详情语义。
- `Sources/QuotaCycleStore.swift`：分区路径、版本校验、原子保存、证据去重、失败回退；writer 注入，不读 auth。
- `Sources/QuotaCycleCoordinator.swift`：串行队列、账户激活代际、读写协调、UI 快照回调；依赖上面两层。
- `Sources/QuotaCycleHistoryView.swift`：AppKit 绘制与交互；不依赖磁盘/URLSession/凭据。
- `tests/quota_cycle_history_test.py`：Python unittest 编译一次轻量 Swift 测试 runner，按 case 名执行。
- `tests/fixtures/quota-cycle-history/main.swift`：测试 runner 与假数据，编译 Foundation 模块即可，不启动菜单栏 App。
- `docs/project/17-quota-cycle-history.md`：实施时新增的现行功能口径文档。
- `CHANGELOG.md`：实施时新增 Unreleased 条目，仅写本次实际变化，不虚构旧发布历史。

### 核心值类型（Task 1 的起点）

```swift
import Foundation

struct QuotaObservation: Codable, Equatable {
    let requestStartedAt: Date
    let observedAt: Date
    let usedPercent: Double
    let resetAt: Date
    let planType: String?

    var isValid: Bool {
        requestStartedAt <= observedAt && usedPercent.isFinite
            && (0...100).contains(usedPercent)
            && resetAt.timeIntervalSince1970.isFinite
            && observedAt.timeIntervalSince1970.isFinite
            && requestStartedAt.timeIntervalSince1970.isFinite
    }
}

enum QuotaCycleEnd: String, Codable {
    case natural, redeemed, earlyUnknown, gap, unconfirmed
}

enum QuotaCycleStart: String, Codable {
    case inferred, observedTransition, redeemed, afterGap
}

struct QuotaCycleRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var startKind: QuotaCycleStart
    var inferredStartAt: Date?
    var firstObservedAt: Date
    var expectedResetAt: Date
    var lastObservedAt: Date
    var lastObservedUsedPercent: Double
    var boundaryLower: Date?
    var boundaryUpper: Date?
    var end: QuotaCycleEnd?
    var incomplete: Bool
    var evidence: [QuotaObservation]

    var remainingAtLastObservation: Double {
        max(0, min(100, 100 - lastObservedUsedPercent))
    }
    var wasObservedFull: Bool { lastObservedUsedPercent == 100 }
}

enum QuotaRedemptionStatus: String, Codable {
    case requested, reset, alreadyRedeemed, unknown, nothingToReset, noCredit
}

struct QuotaRedemptionEvidence: Codable, Equatable {
    let operationHash: String
    let originalRequestedAt: Date?
    let responseAt: Date
    let status: QuotaRedemptionStatus
    let baselineCycleID: UUID?
}
```

`QuotaCycleState` 补充 `schemaVersion=1`、已结束记录、current、上一有效观测、pendingTransition、redemptions、最近接收的 requestStartedAt。候选包含原轮次 ID、第一笔新样本、原因以及待确认标记。首版不要增加数据库、云同步或通用事件总线。

### 生产接口约定

```swift
// QuotaCycleHistory.swift
struct QuotaCycleReducer {
    init(policy: QuotaCyclePolicy)
    func ingest(_ sample: QuotaObservation, into state: inout QuotaCycleState)
    func record(_ evidence: QuotaRedemptionEvidence, into state: inout QuotaCycleState)
}

// QuotaCycleStore.swift：同步仓库，只允许协调器的串行队列调用。
// 分区文件不包含原始 account identity、邮箱、auth 或卡片 ID。
final class QuotaCycleStore {
    typealias Writer = (Data, URL) throws -> Void
    init(root: URL, writer: @escaping Writer)
    func load(accountKey: String) throws -> QuotaCycleState
    func save(_ state: QuotaCycleState, accountKey: String) throws
}

// QuotaCycleCoordinator.swift：入口以账号代际区分旧回调。
// generation 既用于真实账号切换，也保留现有用卡后递增的保护行为。
final class QuotaCycleCoordinator {
    init(root: URL, writer: @escaping QuotaCycleStore.Writer,
         deliver: @escaping (QuotaCycleSnapshot) -> Void)
    func activate(accountIdentity: String?, generation: Int)
    func observe(_ sample: QuotaObservation, identity: String, generation: Int)
    func recordRedemption(_ evidence: QuotaRedemptionEvidence,
                          identity: String, generation: Int)
}
```

以上为计划接口，不应将未完成的声明空壳提交成生产代码。各 Task 必须以对应断言驱动实现。

## Task 1：建立模型、轻量测试 runner 与首次/同周期逻辑

**Files:**
- Create: `Sources/QuotaCycleHistory.swift`
- Create: `tests/quota_cycle_history_test.py`
- Create: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写首个失败测试。** Python setUpClass 使用 `tempfile.TemporaryDirectory()` 保存二进制，在 setUpClass 中运行下列编译；测试启动 `runner firstObservation`，非零退出视为失败。测试不要读取 HOME。

```bash
swiftc Sources/QuotaCycleHistory.swift tests/fixtures/quota-cycle-history/main.swift -o "$TEMP_RUNNER"
```

Swift runner 的第一个 case 使用固定时间与自定义 check：

```swift
import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let t = Date(timeIntervalSince1970: 1_800_000_000)
func sample(_ seconds: Double, _ used: Double, _ reset: Double = 604800) -> QuotaObservation {
    QuotaObservation(requestStartedAt: t.addingTimeInterval(seconds - 1),
        observedAt: t.addingTimeInterval(seconds), usedPercent: used,
        resetAt: t.addingTimeInterval(reset), planType: "plus")
}
var state = QuotaCycleState()
let reducer = QuotaCycleReducer(policy: QuotaCyclePolicy())
reducer.ingest(sample(0, 43), into: &state)
check(state.current != nil, "first sample must create current")
check(state.current?.lastObservedUsedPercent == 43, "used percentage must survive")
check(state.current?.remainingAtLastObservation == 57, "remaining is not token count")
check(state.current?.startKind == .inferred, "first start is not an observed reset")
check(state.closed.isEmpty, "must not fabricate old cycles")
print("PASS: firstObservation")
```

将 runner 包装为 `switch CommandLine.arguments[1]`，每次 case 独立初始化，不依赖上一个 case 进程状态。Python 的具体测试方法命名 `test_first_observation`，后续用例继续加入同一 runner。

**Step 2: 运行，确认失败原因正确。**

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
```

预期：源文件或类型尚不存在导致编译失败；不是因为本机凭据或网络。

**Step 3: 实现值类型与最小 ingest。** 首样本只创建 current；同窗口更新当前观测值；保留首次推算标记。不要一口气实现提前重置。

**Step 4: 逐条加入并运行测试。** 加入同轮增长、完全重复、reset ±30s/±120s、非有限值、-1/101、乱序 requestStartedAt；确认记录 ID 稳定、无多余 closed。原始读数下降不能取 max 掩盖，留给 Task 2 候选处理。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: model quota cycle observations and same-window updates"
```

## Task 2：实现被动重置确认与观测缺口

**Files:**
- Modify: `Sources/QuotaCycleHistory.swift`
- Modify: `tests/quota_cycle_history_test.py`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写正常到期及提前重置的失败测试。** 关键用例：

```swift
// earlyResetConfirmed：旧 reset 在 t+604800，t+100 尚未到期。
var state = QuotaCycleState()
reducer.ingest(sample(0, 72), into: &state)
let oldID = state.current!.id
reducer.ingest(sample(100, 2, 604900), into: &state) // 只移 100s，在容差内
check(state.closed.isEmpty, "jitter and decline alone must not split")
// 新 case 重新建 state，用大于容差的新截止：
var changed = QuotaCycleState()
reducer.ingest(sample(0, 72), into: &changed)
reducer.ingest(sample(100, 2, 605800), into: &changed)
check(changed.closed.isEmpty && changed.pendingTransition != nil, "need confirmation")
reducer.ingest(sample(120, 3, 605800), into: &changed)
check(changed.closed.count == 1, "two stable new-window samples split once")
check(changed.closed[0].end == .earlyUnknown, "source must remain unknown")
check(changed.closed[0].lastObservedUsedPercent == 72, "do not overwrite old use with reset value")
check(changed.current?.lastObservedUsedPercent == 3, "new current must use new window")
```

**Step 2: 运行新增 case，确认目前不会正确拆分。** 使用 Task 1 的 unittest 命令，预期对应 check 失败。

**Step 3: 按 §2.4 实现候选状态机。** 确认样本必须来自不同 requestStartedAt；同笔重放不充当第二次确认。候选回滚、确认超时、跨缺口均有显式分支。旧段在第一笔新窗口样本之前封存，不能把新窗口百分比累加到旧段。

**Step 4: 一次补一条矩阵测试并运行。** 必测：自然到期后 0→0、新 reset 回拨、仅比例回修、仅 reset 移动、候选回滚、候选超过 180s、同笔重放、缺 reset 由接入层拒绝、关机跨三周只产生 gap 而不是三根零柱、首次安装中途、99.6% 展示不算用满、套餐变化待确认。时间与区间对比使用真实 epoch，不按日期字符串运算。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: detect quota transitions conservatively and preserve gaps"
```

## Task 3：保留用卡结果证据并去重

**Files:**
- Modify: `CodexUsage.swift` / `ResetUseResult`、`parseResetUseResponse`、`SelfTest` 的 reset response 断言
- Modify: `Sources/QuotaCycleHistory.swift`
- Modify: `tests/quota_cycle_history_test.py`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写 reducer 的失败用例。** 使用相同 operationHash 重放 `.reset`、随后 `.alreadyRedeemed`，要求只关联同一事件，不制造两轮；记录用卡成功本身不能创建缺少实际额度的新柱。

**Step 2: 运行纯模型测试，确认缺少用卡关联逻辑而失败。**

**Step 3: 实现 record 及 API 分类最小修改。** 保留 `.success` 对应 `code=reset`，新增 `.alreadyRedeemed`，用计算属性统一“已确认请求成功”的 UI 行为；不能继续丢弃分类：

```swift
enum ResetUseResult: Equatable {
    case success, alreadyRedeemed, nothingToReset, noCredit, unknown
    var acknowledgesRedemption: Bool {
        self == .success || self == .alreadyRedeemed
    }
}
```

更新 `parseResetUseResponse` 的两个分支，`beginUseReset` 的 switch 先兼容新增枚举，并使成功后的刷新条件使用 `acknowledgesRedemption`。详细业务关联留到 Task 6，不在解析层写历史。

**Step 4: 测试并补边界。** `.nothingToReset`、`.noCredit` 不拆段；`.unknown` 保留核对；旧操作无时间不在现在生成新边界；仅 5h 重置而 7d 无变化不拆段；消费前启动的响应不能作为消费后证据。更新现有 `SelfTest`，分别断言 `reset` 和 `already_redeemed`，不改变请求体/权限/确认弹窗。

运行：

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
./build.sh
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test
```

预期：模型与现有用卡安全断言全部通过；不会真实消费卡。此时尚未接入历史卡片。

**Step 5: Commit。**

```bash
git add CodexUsage.swift Sources/QuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "fix: distinguish fresh quota redemption from idempotent confirmation"
```

## Task 4：账户隔离持久化与证据保留

**Files:**
- Create: `Sources/QuotaCycleStore.swift`
- Modify: `tests/quota_cycle_history_test.py`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写 round-trip、分区和写入失败的测试。** runner 编译加上新 Store。所有 I/O 在 `TemporaryDirectory` 下；writer 注入，失败注入通过闭包 throw，不能写真实 Application Support。

**Step 2: 运行，确认 Store 尚不存在而失败。**

**Step 3: 实现版本化 JSON 与安全路径。**

- 生产根目录：`~/Library/Application Support/CodexUsage/quota-history/`。
- accountKey：`SHA256("quota-cycle-v1|" + 完整稳定账号 identity)` 的 hex；保留 workspace/account 隔离语义，不用邮箱或 access token。只接受现有 `account:` 稳定身份；只有临时 token 指纹时暂不持久化、不跨启动串联。
- 路径：`<root>/<accountKey>/history-v1.json`，目录 0700、文件 0600；路径只允许固定长度 hex，拒绝 `../`。
- 复用现有 `AtomicJSONFile.replace` 作为生产 writer；Store 不再实现一套认证或通用原子写机制。
- JSON 保存确认轮次、当前轮次、候选、用卡证据哈希与观测点；不存邮箱、原始 identity、卡片 ID、请求原 ID、任何 token、URL header 或服务端原始 JSON。
- 验证所有解码数值/时间、UUID、单调顺序与 schemaVersion，禁止读入 NaN 或重复 ID 后静默继续。
- 不存在返回空状态；损坏/未来 schema 报可读错误并保留原文件，只允许本进程临时记录，不自动覆盖不认识的数据。升级迁移要有单独版本方案。
- 写失败保留最后一份磁盘成功状态，本进程可以继续观测，但 UI 显示「历史未保存」；下一次保存成功清除此状态。

**Step 4: 实现去重及写入频率，再运行测试。** 每笔接受的采样先经过 reducer；不变量快照只在首次、百分比/状态变化、有效窗口变化、用卡证据变化，或五分钟心跳时保存。容差范围内仅时间抖动不每 10 秒写盘。边界相关的候选/确认/回滚证据不得被心跳压缩掉；已结束记录不按 12 周期清理。纯重复样本不增长证据数组，心跳仅更新最近观测时刻与末端观测，不每五分钟追加一条等值历史；每次写入前与最后成功写入的语义版本去重。状态机保留真正发生过的下降，不用 `max(used)` 隐藏回修。测试断言 writer 调用次数、重启恢复候选、损坏文件不变、未来版本不被降级覆盖、两账号文件互不混用、文件权限。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleStore.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: persist account-isolated quota history with recoverable writes"
```

## Task 5：串行协调器与可测试浏览模型

**Files:**
- Create: `Sources/QuotaCycleCoordinator.swift`
- Modify: `Sources/QuotaCycleHistory.swift`
- Modify: `tests/quota_cycle_history_test.py`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写账户切换/迟到加载和翻页测试。** 注入测试 writer、回调调度器或 completion，使用 expectation/semaphore 等待明确任务结束，不靠 sleep。测试输入 0/1/5/6/7/12/13/25 个稳定 ID。

**Step 2: 运行，确认缺少协调器/浏览模型而失败。**

**Step 3: 实现串行队列和激活令牌。** load → reduce → persist 在单一 utility 串行队列；每个结果携带 identityHash、activationToken/generation，交付主线程之前再核对。旧账号可保存到自己的分区，但绝不覆盖新账号 UI。同账号因用卡递增 generation 时不可误清空或重新从旧磁盘加载历史；已有队列中的用卡证据按操作时的账号分区写入，只丢弃过期 UI 交付，不丢弃已确认事实。UI 选择状态不存 Store。

**Step 4: 实现并测试 `QuotaCycleBrowser`。** newest 页面含最新 min(6,n) 条，按时间从旧到新排列；earlier()/newer() 每次移动 6 条、边界禁用；初始可浏览最近 min(12,n)，`loadEarlier()` 将上限继续扩展 12。用 selectedCycleID 和页面锚点 ID 保持刷新前后位置，不持有易过期的数组下标。

可直接采用的分页边界函数：

```swift
func visibleRange(total: Int, olderPage: Int, pageSize: Int = 6) -> Range<Int> {
    let safeTotal = max(0, total)
    let safeSize = max(1, pageSize)
    let maxPage = max(0, (safeTotal - 1) / safeSize)
    let page = min(max(0, olderPage), maxPage)
    let upper = max(0, safeTotal - page * safeSize)
    return max(0, upper - safeSize)..<upper
}
```

测试：25 条默认索引 19..<25，前一页 13..<19；边界无负范围。显示新记录时，正在看历史页不跳回最新；切号才重置。新加轮次不能导致当前选中 ID 突然变成另一条。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleCoordinator.swift Sources/QuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: coordinate quota history updates and stable cycle paging"
```

## Task 6：接入现有刷新/用卡链路，不增加网络行为

**Files:**
- Modify: `CodexUsage.swift` / `AppDelegate`、`performRefresh`、`applyQuota`、`synchronizeAccount`、`beginUseReset`、`rebuildMenu`、`SelfTest`
- Modify: `build.sh` / Swift 源文件列表

**Step 1: 写离线集成断言。** 在 `SelfTest.run` 的临时根中注入协调器和假 `QuotaData`；要求 r.sevenDay=nil 但旧 usage 存在时不入账，迟到 generation 拒绝，用卡后旧请求拒绝，切号不清除另一账号磁盘记录。把“接收样本的 gate”提炼成可测试小函数，不在测试中实例化真实联网 AppDelegate。

**Step 2: 加入 build.sh 的三个非 UI 新模块，运行构建/自检确认断言失败。** 不要改成不透明的全目录通配符，不改 universal 或 top-level 入口。

**Step 3: 接入协调器。**

- 非预览 AppDelegate 构造协调器，root 显式传入。预览走固定内存快照，不能先创建真实仓库再用 guard 禁止写。
- `performRefresh` 在发请求前捕获 requestStartedAt、identity、generation；接受响应后传给 applyQuota/history adapter。
- 只有本次合法 `r.sevenDay` 且 reset 非 nil、稳定身份可确认时构造 Observation。额度失败不推进历史成功时间。
- history 回调只更新 typed snapshot 并 `rebuildMenu()`；不要调用会写真实 status.json 的 `renderBar()` 造成额外诊断写入循环。
- `synchronizeAccount` 激活新分区，立刻清空旧历史展示；current-account加载完成之前显示中性“读取历史”。

**Step 4: 接入用卡证据并验证。** 原 pending defaults 追加可选 `createdAt` 与基线轮次 ID，保留已有 identity/cardID/key 和幂等流程，兼容旧 V1 缺字段。用户确认保存成功后记录 requested；响应分类后记录 evidence。operationHash 由原 key 哈希生成，副本不含 cardID/key。成功后的 generation 递增、pending 清理、错误提示和刷新次数保持原有语义。unknown 不生成新请求，不因记录功能而自动重试。先让协调器按串行顺序记证据再处理后续新额度，不允许回调乱序覆盖。

运行：

```bash
./build.sh
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
```

预期：离线测试通过，已有脚本测试无退化。不要运行 `--once` 或真实用卡。

**Step 5: Commit。**

```bash
git add CodexUsage.swift build.sh
git commit -m "feat: capture quota history from accepted refreshes and redemption evidence"
```

## Task 7：实现窄面板双柱图与固定详情

**Files:**
- Create: `Sources/QuotaCycleHistoryView.swift`
- Modify: `build.sh`
- Modify: `CodexUsage.swift` / `UsagePanelModel`、`UsagePanelController.rebuildContent`、布局预览断言

**Step 1: 先添加固定数据和失败的几何断言。** 固定 13+ 个轮次，包含 natural/full、natural/81%、redeemed/72%、earlyUnknown、gap、current/36%、unconfirmed；在 330pt/窄屏夹具断言六组不重叠、不超边、每组确实两柱、详情有固定高度。

**Step 2: 构建预览，确认卡片缺失/计数不符。** 用现有预览测试入口；此时允许 FAIL，不能把文字检查等同于画面通过。

**Step 3: 实现 AppKit 视图。** 以 `QuotaCycleHistorySectionView` 为根，持有 chart、分页按钮、固定详情和 notices；在主文件 `makeCardSection(...)` 中包装，插入 daily 与 tools 之间。主文件里的 `PanelUI` 是 private，不能直接跨文件调用；新视图使用少量自己的 NSStackView/NSTextField 布局，不为复用而扩大全部 PanelUI 访问权限。

布局约束：

```text
额度周期回顾                       折叠箭头
上限 / 已用的小图例       ‹  最近 6 个  ›
[6 组 × 灰上限柱 + 暖橙已用柱，纵轴 0–100%]
[6 个精简开始日期，当前组浅色高亮]
11/06–11/10（约） · 主动用卡
最后观测已用 72% · 重置前剩余约 28%
```

- 图表总高建议 96pt（含日期），详情两行预留 32–36pt；总高目标见 §0.2。
- 内宽约 282pt；预留约 20pt 轴区，其余均分 6 列；每柱宽约 7pt、组内间隔 3pt。窄屏通过实际 bounds 计算，不能用宽幅示意图坐标。
- 上限在轴上统一标 100%，不在六根灰柱顶重复长标签；数值在选中详情里读。
- 灰柱使用动态 `.secondaryLabelColor` 的适当透明度，暖橙复用 `PanelAccent.codex.color`；选择底色使用同色低透明度。只用文字/形状区分状态，不依靠色盲难辨的颜色。
- 明确零值显示低基线；缺失显示占位/斜线，不画成零柱。
- 候选未确认时不新增已确认历史柱，当前详情显示“重置待确认”；可在当前柱增加中性虚线描边，保留最后可信读数。
- gap 与部分记录能查看，但不展示确定到期未用百分比；写盘失败显示“历史未保存”；暂无数据提示“从首次成功读取额度后开始记录”。
- 不足六条时仍保留固定卡片高度，避免每次累积一条就改变整页布局。
- 第七卡片加入后修正现有 layout test 的数量/顺序断言，不放宽间距 8pt、内边距 8pt、圆角 12pt 的检查。

**Step 4: 运行预览几何测试并截图检查。** 加入第四个 UI 源到 build.sh，构建/原有 self-test 通过。浅/深色、空状态、短历史、长历史、窄面板不溢出。此步骤只是固定数据预览，不声称真实账号历史正确。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift CodexUsage.swift build.sh
git commit -m "feat: add native quota cycle history card below usage insights"
```

## Task 8：补齐选择、翻页、折叠与辅助功能

**Files:**
- Modify: `Sources/QuotaCycleHistoryView.swift`
- Modify: `CodexUsage.swift` / 预览事件测试、开合状态
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写交互失败断言。** 鼠标跨六列（含柱间空白）、点击固定、移出恢复、方向键边界/跨页、13 条的更早记录、折叠重开、刷新后保持 selectedID、切号重置。不要直接调用目标 handler 就宣称真实点击通过。

**Step 2: 运行新增 preview interaction test，确认缺交互而失败。**

**Step 3: 实现交互。** 命中按整列计算，不限柱实体；鼠标查看不发网络、不写盘。页码/展开状态属于 `UsagePanelController` 或独立 UI state，使用稳定轮次 ID 保存；不要藏进每次重建就丢失的 view。VoiceOver 逐组提供开始精度、结束状态、已用、剩余与最后观测时间。Home/End 可选，不增加隐蔽复杂手势。

**Step 4: 回归交互及异步重建。** 后台更新到来时历史页不能跳回当前；关闭重开保留本进程选择，账号切换后不留另一账号详情；原日图悬停、工具周期、模型行、Esc、外点关闭、刷新不关闭面板全部保持。

**Step 5: Commit。**

```bash
git add Sources/QuotaCycleHistoryView.swift CodexUsage.swift tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: support cycle navigation and accessible history details"
```

## Task 9：完整回归与真实原生窗口验收

**Files:**
- Modify: `CodexUsage.swift` / 仅必要的测试修复
- Create after verification: `docs/verification/2026-11-12-quota-cycle-history.md`（若实际验收晚于此日，使用实际日期）

**Step 1: 跑全部离线回归并保存摘要。** 在此 worktree 运行，不替换用户原目录的构建。

```bash
./build.sh
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
lipo -archs CodexUsage.app/Contents/MacOS/CodexUsage
codesign --verify --deep --strict CodexUsage.app
```

预期：全部测试通过、shell 无输出、架构同时包含 arm64/x86_64、签名验证成功。若本机支持 Rosetta，可另外执行 x86_64 --self-test，未执行就如实记未验证。

**Step 2: 增加并执行专用假数据预览开关。** 这些是待新增的参数，不是当前已存在的命令：

```bash
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-quota-history
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-dark --visual-preview-quota-history
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-narrow --visual-preview-quota-history
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-empty --visual-preview-quota-history
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-quota-history --visual-preview-events
```

夹具由固定 epoch/假账号生成，不创建真实 history 目录。覆盖一个/六个/十三个/二十五个周期、候选/失败/损坏版本/无稳定账号、跨年与本地时区；固定 epoch 的状态含义不得因真实运行日变化。

**Step 3: 用 Cua 在真实 AppKit 窗口检查。** 读取 `@cua-driver-cli`，先列出窗口并展示预览，再操作。不得用网页/HTML 证明原生布局成功。实际点开折叠、翻页、选择第六组、移出、键盘跨页、关闭重开、滚到工具明细；记录实际画面及观察结果。预览窗口验证的是原生 UI 与假数据，不等于真实账号跨多周历史已验收。

**Step 4: 回读隔离证据并写验收报告。** 使用临时注入目录模拟保存→退出→恢复、账号 A/B 切换、损坏文件和不可写目录；断言 fixture 目录外没有历史写入。测试流程不得访问 auth、消费卡、执行真实 update/release。报告区分：纯状态机已测、磁盘失败已测、原生 UI 已测、真实账号长期采样尚未验证。不要把截图工具成功当作布局通过。

**Step 5: Commit。** 如 Step 1–4 发现代码问题，回到对应 Task 补失败用例并修复/提交，再重新完成本 Task；不要把修复藏进仅声明报告文件的提交。

```bash
git add docs/verification/2026-11-12-quota-cycle-history.md
# 若实际日期不同，使用 Step 4 真正创建的路径。
git commit -m "test: record quota cycle history verification and limits"
```

## Task 10：同步当前文档与交付，不擅自安装/发布

**Files:**
- Create: `docs/project/17-quota-cycle-history.md`
- Create: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `docs/project/02-architecture.md`
- Modify: `docs/project/11-usage-insights-prd.md` / 只添加后续扩展说明，不改写历史交付事实
- Modify: `AGENTS.md` / 实施后将六板块顺序改为七板块，补新模块入口；只改必要句子

**Step 1: 写文档验收检查清单。** 必须能找到：位置、6/12 翻页、实际轮次、历史从首次采样开始、提前重置/主动用卡区别、未知来源、百分比非 Token、缺口/最后观测、账号隔离和本地目录。缺一项视为文档未完成。

**Step 2: 先核对代码实际行为。** 与本文出现分歧时先修正实现或在计划“执行偏差”节说明，不把计划照抄成已实现事实。

**Step 3: 写用户说明、维护说明与 CHANGELOG。** README 只写用户需要知道的几句话；`17-quota-cycle-history.md` 保留完整判定/数据格式/不确定性；DEVELOPMENT 补新模块、预览命令与测试；CHANGELOG 详细写新功能、重置响应分类修正、缺口与风险，不顺手改版本号或补造发布历史。

**Step 4: 最后核验改动范围。**

```bash
git diff --check
git status --short
git diff --stat
```

不应出现真实历史 JSON、auth、图片草稿或 build 缓存。若本轮产生日常知识维护，只保存本功能的已验证稳定事实；本计划阶段不改长期记忆或项目规则的现行行为描述。

**Step 5: Commit 并交付。**

```bash
git add README.md docs/DEVELOPMENT.md docs/project/02-architecture.md docs/project/11-usage-insights-prd.md docs/project/17-quota-cycle-history.md AGENTS.md CHANGELOG.md
git commit -m "docs: document quota cycle history semantics and verification"
```

向用户交付：功能摘要、离线测试结果、原生 UI 证据、尚未验证的真实长期观测边界。合并、替换正在运行的 App、真实用卡与公开发布不属于本计划默认授权，另行确认。

## 4. 最终验收矩阵

| 编号 | 必须满足 |
|---|---|
| A1 | 卡片在用量简析之后、工具明细之前；7 张卡片，8pt 间距/内边距和原字体层级不变。 |
| A2 | 330pt 面板每屏 6 组，每组恰好两柱，纵轴为百分比、上限 100%；没有假 Token 上限。 |
| A3 | 能看最近 12 轮并继续查看更早；当前轮次在最新页右侧，少于六轮不伪造历史。 |
| A4 | 正常到期/主动用卡/来源未知提前重置/待确认/缺口均能区分；未知不能写成官方重置已确认。 |
| A5 | 缺口不补零、不按机器日历造周期；首轮推算开始和最后观测误差明确展示。 |
| A6 | 重放响应/幂等核对/网络错误不多造轮次，不发额外额度请求或真实用卡请求。 |
| A7 | 账号隔离、请求代际、异步加载切换、原子写与 0700/0600 权限均有自动化用例。 |
| A8 | 历史持久化且可恢复候选；损坏、未来版本、写入失败不覆盖旧数据，状态可见。 |
| A9 | 翻页/选择/键盘/折叠/刷新保持稳定，原日图及原生关闭交互不退化。 |
| A10 | 所有自动化测试、universal 构建、签名、浅深色原生预览通过；真实长期账号观测未做则明确未验证。 |

## 5. 实施风险与停止条件

1. **接口不可识别性：** 同截止时间的比例回落、低比例归零、reset 缺失或第三方用卡原因无法可靠判定时，保留待确认。不能为了好看而强制拆段。
2. **误把核对时间当重置时间：** `already_redeemed` 没有原始时间证据时，不生成“现在”的重置；这是现有解析需要先修正的关键点。
3. **小面板可读性：** 六组仍有溢出时，先减少重复标签、优化详情布局，不擅自把主面板加宽或压缩字体；若实际只有四组可读，应把截图和实测尺寸交用户决定，而非暗中改验收数。
4. **账户身份不足：** 没有稳定 account identity 时不使用 token hash 持久化，不显示另一账号历史，也不扩大读取凭据的范围。
5. **磁盘格式/容量：** 首版去重与心跳降低增长，按需分页读取/呈现；不悄悄删除旧历史。若真实数据出现不可接受的性能成本，再提出分年归档方案，不在首版引入数据库迁移。
6. **新功能权限范围：** 若必须更换认证、自动消费卡、写原始会话、替换用户运行中的 App 或执行公开发布，停止并请求确认，这些不属于“显示历史”的授权。

## 6. 执行交接

- 推荐按 Task 1–3（判定正确性）、Task 4–6（落盘与接入）、Task 7–8（原生 UI）、Task 9–10（验收与文档）四个检查点推进。
- 方式 A：当前会话逐任务执行并在每个检查点审阅；独立对抗审查可委派，但不要把互相依赖的接入/UI 任务并行写同一主文件。
- 方式 B：另开会话使用 `@executing-plans`，绑定同一实施 worktree，读取此计划后分批执行。
- 无论哪种方式，都先完成失败测试再改生产逻辑；不要仅凭示意图或纯源码检查宣称上线完成。
