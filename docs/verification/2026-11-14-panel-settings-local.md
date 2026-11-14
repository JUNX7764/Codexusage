# 面板卡片设置 + 五项 UI 精修 本地验证报告

日期：2026-11-14（工作日期 2026-11-13/14）
Worktree：`/Users/Chester/.zcode/worktrees/0e71/Codexusage-panel`（分支 `feat/panel-settings-20261113`，基线 `66dbefd` v1.4.0）
状态：开发与两轮审查完成后经用户本地验收（含两轮反馈修正），用户拍板 commit/push 并随 **v1.5.0** 正式发布；本节保留验收期间的门禁与部署记录。

## 交付内容（对照 GlmUsage v1.5.x 两波改动移植）

### 1. 面板卡片自定义（「···」菜单）

- 页头右上角按钮 `paintpalette` → `ellipsis`「···」，统一菜单：`卡片显示与排序…` + `背景样式 ▸` 子菜单（纯色/经典毛玻璃/液态玻璃，旧系统禁用标注保留）。
- 新增 `Sources/PanelCustomization.swift`：`PanelCardID`（7 卡：用量进度/重置卡/Tibo 重置动态/用量情况/用量简析/额度周期回顾/工具明细）、`PanelCardLayout`（顺序 + 显隐集合，JSON 存 `UserDefaults` key `panelCardLayoutV1`，损坏/未知 ID 回落默认、缺失卡片按默认次序补尾）、`PanelCardSettingsView` 原位设置页（显隐复选框 = 行标题、上移/下移、恢复默认卡片布局、完成；无「取消」，改动自动保存）。
- `rebuildContent()` 按布局组装卡片；页头、footer、更新提示行不参与配置；「隐藏」≠「收起」，隐藏卡片仍照常获取数据；允许全部隐藏 → 空态卡（说明 + 恢复默认按钮）。
- 打开设置页 `makeFirstResponder(initialKeyView)` 修 Space 键缺陷；`popoverDidClose` 退出设置页保留布局；10s 数据刷新复用同一编辑器并恢复焦点。

### 2. 五项 UI 精修

| 项 | 规格 |
|---|---|
| 每日柱圆角 | 仅顶部 1.5pt（翻转视图 minY 侧），底部基线齐平；短柱收紧不越界 |
| 数值 320ms 过渡 | 每日图悬停气泡数值 0.320s cubic ease-out；气泡可见且前后为数值才动画；首显/缺数/减少动态效果立即到位；快速扫过从当前显示值重定向；AX 值始终目标准确值；气泡尺寸按终值计算 |
| 环比胶囊 | 日环比/7日环比 soft chip（方向配色保留）；窄面板两行回退（46pt）不截断数字；说明文字 accessibilityValue 携带数值 |
| 单根额度槽 | 每周期一根居中 12pt 灰槽 + 绿色底部按该轮自身上限归一化填充；0% 不画绿、100% 填满；图例「■ 已用 ■ 距上限 ● 当前」 |
| 独立图标 | 额度周期回顾 `clock.arrow.circlepath`，用量简析保持 `chart.bar.fill` |

### 3. 新增/修改文件

- 新增：`Sources/PanelVisuals.swift`、`Sources/DeltaChip.swift`、`Sources/AnimatedTokenValue.swift`、`Sources/PanelCustomization.swift`、`tests/ui_refinements_test.py`、`tests/fixtures/ui-refinements/main.swift`
- 修改：`CodexUsage.swift`（菜单/设置页接线、布局驱动组装、自检回归、preview 钩子）、`Sources/DailyUsageView.swift`、`Sources/QuotaCycleHistoryView.swift`、`build.sh`（源文件列表 +4）
- 预览参数：`--visual-preview-card-settings-test`（自动回归）、`--visual-preview-show-card-settings`（截图）、`--visual-preview-hide-cards=id,id`（注入隐藏）

## 验证证据（均实际执行）

| 门禁 | 结果 |
|---|---|
| `./build.sh`（arm64+x86_64 universal，ad-hoc 签名） | PASS（v1.4.0-dirty） |
| `--self-test`（含新增：布局规范化/持久化回退/过渡数学/几何原语/符号存在性） | PASS |
| `python3 -m unittest discover -s tests -p '*_test.py'`（55 tests，含 ui_refinements 5 项） | OK |
| `bash -n build.sh scripts/update.sh scripts/release.sh` | OK |
| `--visual-preview-events`（卡片布局/状态按钮/模型行/工具周期/图表悬停键盘/周期事件/Escape/外点/刷新） | PASS |
| `--visual-preview-card-settings-test`（菜单结构、焦点交接、Space 不关面板、显隐/排序/焦点恢复/恢复默认/完成重建/重开保留） | PASS |
| `--visual-preview-background-test` / `--visual-preview-confirm-test` | PASS |
| 截图（`/tmp/codexusage-ui-verify/`）：panel-light/dark/settings/hidden/empty/narrow/hover | 已人工核对 |

## 已知限制（非本次回归）

- `--visual-preview-popover-test` 在本机屏幕 FAIL（面板已达 0.85 屏高上限，展开行不再增高）：**基线 HEAD 构建同样失败**，为屏幕高度相关的存量测试限制，与本次改动无关。
- 真实账号链（`--once`）、安装/更新/发布流程未运行（按约定不在本次范围）。
- 截图中顶部「用量进度」卡被 `scrollQuotaHistoryForPreview` 滚出画面属截图前置行为，narrow 截图确认其渲染正常。

## 审查记录

- Advetor 第一轮：11 findings（2×P1、1×P2、8×P3），已全部修复：move 焦点恢复死代码、气泡终值定尺寸（并加固为起点/终值较宽者定宽）、10s 重建保留编辑器+焦点、提示文案、死代码、空态 8pt、键盘链接入返回/恢复默认、行标题合并复选框、测试按宿主架构选 target、isPreviewMode 收敛、属性归位。
- Advetor 第二轮：11 项修复逐项 PASS，结论「可部署」；新增 2 条 P3 已修复——
  - N1：编辑器复用跨 10s 重建的宽度约束滞留 → 复用时显式失活旧约束（finish/popoverDidClose 同步清理）。修复中曾因「未挂父栈先激活约束」触发 NSLayoutConstraint 异常，已按先挂子视图再激活的顺序修正，卡片设置回归覆盖。
  - N2：焦点恢复路径补门禁 → `verifyPanelSettingsForPreview` 新增「设置页打开时 update(model:) 触发重建，firstResponder 保持同一控件」断言，并把 focusWindow 收紧为 guard。
- 最终门禁（N1/N2 修复后的产物）：build ✓、--self-test PASS、55 tests OK、事件回归 PASS、卡片设置回归 PASS（含新断言）、background/confirm PASS。

## 用户验收反馈修复（2026-11-14，均已过门禁并重部署本地实例）

- 设置页 footer：「返回」（灰底 pill）加入「完成」左侧；两键改为带底色 + hover 的按钮质感（`PanelSettingsButton`，neutral/accent 两种样式，键盘链接入 footer 返回）。截图 `panel-settings.png`。
- 重置卡行：「过期」两字只是过期时间说明词，取消单独橙色 badge，并入日期同一标签、同次级色（`ResetCardSectionView`，重置卡行渲染）；≤72h「即将到期」的卡名语义色保留未动。截图 `panel-resetcards.png`。

## 部署说明

- 验收期间生产实例（`~/Applications/CodexUsage.app`，LaunchAgent `com.local.codex-usage`）保持运行、未被替换；本地验证实例直接启动 worktree 构建产物（footer `v1.4.0-dirty`）。
- 用户验收通过后按「commit → push → release.sh v1.5.0 → 部署 ~/Applications」收尾，正式实例经更新流程升级到 v1.5.0。
