# CodexUsage 开发说明

> **当前工程事实源**。构建、测试、发布或权限行为发生变化时，应在同一个提交中更新本文。
> 最后核对：2026-11-10。

## 文档入口与效力

| 文档 | 用途 | 当前效力 |
|---|---|---|
| `README.md` | 功能、安装、更新与隐私说明 | 面向用户的当前说明 |
| `docs/DEVELOPMENT.md` | 构建、测试、发布和验证边界 | 面向维护者的当前说明 |
| `docs/project/02-architecture.md` | 模块、数据流和信任边界 | 当前架构概览，细节以源码为准 |
| `docs/project/07-standards.md` | 修改、测试、凭据和文档约定 | 当前维护约定 |
| `docs/project/10-release.md` | 发布资产、门禁和回滚边界 | 当前发布清单 |
| `docs/project/11-15`（PRD、核验、交接、评审） | 用量总览专项的设计与验收过程记录 | **历史记录**；11 号 PRD 的基础卡片样式仍适用，周期扩展见 17 号文档 |
| `PLAN.md` | 初始任务书及历次设计记录 | **历史资料，不代表当前行为** |
| `VISUAL_OPTIMIZATION_PLAN.md`、`docs/features/` | 已完成专项的实施记录 | **历史资料，不代表当前行为** |

判断当前行为时，优先级为：**源码与测试 → 本文及 `docs/project/` → 用户 README → 历史计划**。文档与代码冲突时，先修正文档，不得用历史计划证明现状。

## 构建

需要 macOS 13 或更新版本和 Xcode Command Line Tools。`build.sh` 产出 arm64 + x86_64 的 universal 双架构（在 Apple Silicon 上交叉编译 x86_64，无需 Intel 机器）；x86_64 切片可用 Rosetta 跑 `--self-test` 验证。

```bash
./build.sh
```

`build.sh` 会重建项目内的 `CodexUsage.app`，替换已有构建产物，并执行 ad-hoc 签名验证。版本号来自 `git describe`；多文件拆分后必须保留合法的 top-level 入口，并同步调整构建脚本。

## 调试与自检

```bash
# 离线自检：只用临时目录和假凭据，不读真实 Codex 凭据、不联网
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test

# 周期状态机／仓库／协调器：仅使用假账号和临时目录
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v

# 脚本回归：PATH mock 故障注入，不操作真实 app、LaunchAgent 或 GitHub
python3 -m unittest discover -s tests -p '*_test.py'

# Shell 语法检查
bash -n build.sh scripts/update.sh scripts/release.sh

# 真实自检：读取本机凭据、联网拉一次数据后退出；不属于离线测试
./CodexUsage.app/Contents/MacOS/CodexUsage --once
```

固定假数据视觉预览不联网，也不写真实 `status.json`：

```bash
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-normal
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-dark
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-long
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-states
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-empty
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-update
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-updating
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-updating-install
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-narrow
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-pro
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-tools
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-full
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-daily-collapsed
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-hover-fixture
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-events --visual-preview-output=/tmp/codex-hover.png --visual-preview-hover-index=29
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-popover-test=/tmp/codex-popover
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-empty --visual-preview-empty-failure --visual-preview-tools
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-models
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-quota-history
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-dark --visual-preview-quota-history=25
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-narrow --visual-preview-quota-history=25 --visual-preview-events
```

面板截图与事件回归：

```bash
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-output=/tmp/codex-panel.png
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-dark --visual-preview-scroll-end --visual-preview-output=/tmp/codex-panel-bottom.png
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-events
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `CodexUsage.swift` | 入口、AppKit UI、原有数据层、更新控制和离线自检 |
| `Sources/OfficialUsage.swift` | 账号用量只读请求、账号快照校验和严格解析 |
| `Sources/DailyUsageView.swift` | 日期图表、悬停／键盘查看和工具占比条 |
| `Sources/QuotaCycleHistory.swift` / `QuotaCycleStore.swift` / `QuotaCycleCoordinator.swift` / `QuotaCycleHistoryView.swift` | 额度轮次状态机、隔离存储、异步协调与原生图表 |
| `Sources/PanelVisuals.swift` / `DeltaChip.swift` / `AnimatedTokenValue.swift` | 柱形与额度槽几何、环比胶囊、每日数值过渡的纯状态 |
| `Sources/PanelCustomization.swift` | 卡片布局模型（显隐/顺序，JSON 持久化）与原位卡片设置页 |
| `Sources/UsageAttribution.swift` / `UsageComparison.swift` | 来源归属及比较计算 |
| `vendor/zstddeclib.c` | 上游 zstd v1.5.7 单文件解码源，许可见 `vendor/zstd-LICENSE` |
| `vendor/zstd_bridge.c` / `.h` | zstd 解码的 C 桥接层 |
| `build.sh` | 编译、打包和 ad-hoc 签名 |
| `Info.plist` | App Bundle 身份、最低系统版本和菜单栏常驻配置 |
| `scripts/icon_gen.swift` | 图标生成脚本；缺少 icns 时由构建脚本调用 |
| `scripts/update.sh` | 从 Release 下载、校验、暂存、替换并重启应用 |
| `scripts/release.sh` | 创建标签、构建、自检、打包并创建或补全 GitHub Release |
| `tests/script_test.py` | 更新、发布和签名故障的离线回归测试 |
| `tests/ui_refinements_test.py` | 面板视觉原语、数值过渡与卡片布局模型的离线 fixture 回归 |
| `PLAN.md` | 历史任务书，不作为当前规格 |

## 用量与更新的校验边界

Codex 会话按 `token_count` 事件的本地日期统计，累计值按同一会话前后差额入账，并按最近一条 `turn_context.payload.model` 归入模型；缺少模型信息的旧记录归为「未知模型」。缺少事件时间的旧记录使用文件名日期。未修改文件复用缓存，活跃明文会话只读取新增内容，压缩归档发生变化时重新解压。

官方用量通过 `GET /backend-api/wham/profiles/me` 只读请求，使用已有认证快照及 `ChatGPT-Account-ID`，查询本身不续期；401 等待额度链路按既有规则处理。请求结果接受前后核对账号身份和凭据，失败保留同账号上次成功值。官方数据及本机扫描随约五分钟调度，鼠标与控件交互只使用缓存。图表及比较遵循[官方客户端稀疏活动桶显示行为](https://github.com/openai/codex/blob/2c502d8b3d382dd609179164f31396d95deee55c/codex-rs/tui/src/analytics/activity_chart.rs)：非空官方日数组范围内缺桶按零，范围外与未知来源不外推；以本地今日为 D，官方日桶尚未含当日时以与用量情况同口径的本机合并今日用量（Codex 与外部工具之和）补足（描边空心柱，界面文案不标注来源），源日期时区未确认不阻止相邻标签计算。缺失范围、空数据或查询过期时显示数据不足。

构建时在专属临时目录生成合法 `main.swift` 并编译 `Sources/`；真实只读能力可通过 `--official-usage-check` 检查，该命令联网，只输出成功或失败类别及日／周比较是否可计算的布尔值，不输出日期、账号或个人用量。

额度周期历史只消费现有 7d 请求中本次有效的数据，以稳定账户身份派生哈希分区；缺少稳定身份时不落盘。首次周期开始时间是推算，提前重置来源未确认，跨观测缺口不补造轮次。重置卡 `already_redeemed` 仅确认原请求，单独出现时即使携带原请求时间也不独立生成边界；已有同操作的 `reset` 证据不会被覆盖。面板内每屏显示 6 轮，初始浏览最近 12 轮，可继续加载更早轮次；预览不创建真实历史仓库。

面板卡片设置只作用于七张业务卡片的显隐与纵向顺序，改动即时写入本机偏好；「隐藏」不同于折叠，隐藏的卡片仍照常获取数据，页头、页脚、更新提示与凭据恢复区不参与排序。预览与离线回归使用默认布局基线，不读取也不写入生产偏好（截图可用 `--visual-preview-hide-cards=` 注入）。

更新脚本接收已确认的 Release 标签和正在运行的应用路径，校验包身份、构建版本和实际安装版本后仅处理目标进程。离线脚本测试使用临时应用、伪造进程和网络命令，**不能替代真实安装环境中的更新、回滚和面板点击验收**。

更新进程由应用通过 `Process` + `nohup` 启动，输入输出关闭并切到独立临时目录；应用退出后任务继续执行，同时保留 macOS TCC 的责任应用归属。不要改回 `launchctl submit` 启动裸 shell：2026-11-04 的真实故障日志显示其责任进程变成 `/bin/bash`，换包的 `mv` 被拒绝（`Operation not permitted`）。失败日志保留在系统临时目录的 `usage-update-*/log`。

## 发布前必须执行

```bash
git status --short
./build.sh
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

确认工作区干净、HEAD 已推送至 `main` 后，再运行：

```bash
scripts/release.sh vX.Y.Z   # 具体版本号发布前确定，只发正式版
```

`release.sh` 会执行构建、二进制自检、签名与资产校验，但**不会自动运行上面的 Python 脚本回归，也不代表真实更新验收已经完成**。完整发布边界见 `docs/project/10-release.md`。

## 已记录的验证证据与限制

- 2026-11-04：24 项脚本测试（23 通过、1 项条件跳过）、构建、签名验证和离线自检通过。另用原生测试应用实际完成 v1.0.11 → v1.0.12 下载、替换、旧进程退出及新进程驻留；未覆盖面板按钮点击。
- 2026-11-06：当前构建的离线自检通过；25 项脚本测试为 24 通过、1 项条件跳过；三个 Shell 脚本语法检查通过。
- 2026-11-10：全仓审查后复验——构建、签名验证和离线自检通过；34 项脚本测试全部通过（移除了本应用不存在的 `--peak-test` 死测试后无跳过项）；三个 Shell 脚本语法检查通过。
- 尚无证据表明所有版本都在 macOS 13、14、15 或干净用户环境完成实机验收。部署目标为 macOS 13 不等同于完成兼容性验证。

面板背景使用 macOS 26+ SDK 构建，运行目标仍为 macOS 13+。旧系统的液态玻璃选择降级为经典毛玻璃；系统降低透明度时暂时显示纯色。更新说明来自选中的可安装 Release，确认后才启动更新。
