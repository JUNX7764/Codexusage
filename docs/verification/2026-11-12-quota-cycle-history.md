# 额度周期回顾验证记录

日期：2026-11-12。对象为独立 worktree 的构建和固定假数据，不代表已安装或发布。

## 已执行

- `python3 -m unittest discover -s tests -p '*_test.py' -v`：50 项通过。包括周期状态机、账户隔离、读取/写入故障、候选恢复和既有脚本 mock。
- `./build.sh` 与 `./CodexUsage.app/Contents/MacOS/CodexUsage --self-test`：通过；`lipo -archs` 显示 x86_64、arm64，`codesign --verify --deep --strict CodexUsage.app` 通过；`bash -n build.sh scripts/update.sh scripts/release.sh` 通过。链接器警告 compatibility packs 缺 x86_64 slice，但双架构构建成功。
- `--visual-preview --visual-preview-quota-history --visual-preview-events`、`--visual-preview-dark --visual-preview-quota-history=25 --visual-preview-events` 和 `--visual-preview-narrow --visual-preview-quota-history=25 --visual-preview-events`：最后一轮均通过。NSEvent 分发覆盖双柱组点击、悬停到空白区恢复固定选择、方向键跨页、更早记录、按钮翻页、折叠、模型刷新、账号 UI 状态重置，以及 Esc 关闭后重开保持历史选择和页码，也回归原有布局与关闭交互。
- 固定假数据截图已检查浅色、深色、320pt 窄面板、空数据、套餐变更待确认和历史未保存；均为生成预览，并非真实账号。

## 限制与待父会话验收

- **真实 AppKit 窗口的 Cua 验收尚未执行，不能标为通过。** 子会话未使用 Cua；父会话需实际检查鼠标移出卡片恢复、悬停、点击、键盘跨页、折叠/重开、滚动、工具明细及辅助功能，尤其在 330pt 和窄屏、浅深色下检查。
- 离线全量回归曾出现一次 `test_update_uses_only_own_label_and_cleans_up` 模拟自检超时，单项及完整重跑通过；排查发现 mock sleep 零延迟可能抢跑后台进程，测试替身改为 10ms 等待，未修改生产更新逻辑或放宽断言。
- 自动事件测试中，探索期间曾出现一次 Escape 未关闭和一次刷新后面板关闭，重跑及最后三组命令通过；未证明根因，需真实桌面验收继续关注。合成 `mouseExited` 未能绑定有效 trackingNumber，已改测鼠标移动至图内空白的恢复；真实移出仍待 Cua。
- 未连接真实账户、未联网、未真实消费重置卡，未做真实多周观测、安装、更新或发布。固定数据和临时文件回归不能证明真实长期数据口径或实际安装环境。
