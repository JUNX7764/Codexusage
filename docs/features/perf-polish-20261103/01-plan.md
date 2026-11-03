# CodexUsage 性能与体验优化 — 2026-11-03

分支：`perf-polish-20261103`。范围来自 2026-11-03 全量代码审查（前端菜单 → 网络 → 本地扫描 → 发布链）。
单文件 app + 两个脚本，改动均为小切口；不写九件套，本文即开发计划与验收清单。

## 范围

| # | 项 | 改动 | 验收 |
|---|---|---|---|
| 1 | `--once` tiboVar 锁外读取 | 与其余变量一起在 `onceLock` 内取快照 | self-test 通过（编译期+行为不变） |
| 2 | 外部用量无失败面 | `ExternalTokenScanner.Result` 增 `error`；已安装来源全部不可读（目录存在但枚举失败 / state.db 存在但查询失败）时置错；`applyExternal` 改三态：失败保留旧值、不推进 lastOK，⚠ 过期机制自动生效；菜单增错误行 | self-test 新夹具：root 指向普通文件、hermes 指向非 sqlite 文件 |
| 3 | 一轮刷新重建菜单 5 次 | 5 个 apply 回调只更新数据，`group.notify` 统一 `updateUI()` 一次（renderBar + rebuildMenu + status.json 每轮 1 写） | 行为不变，self-test 通过 |
| 4 | 菜单生命周期 | `NSMenuDelegate`：`menuWillOpen` 触发手动全量刷新（RefreshGate 合并）；菜单打开期间不重建（`pendingMenuRebuild`），`menuDidClose` 时补重建——打开中的菜单不被替换闪断，数据下次打开即最新 | 手测：打开菜单浏览不被打断；打开即触发刷新 |
| 5 | zstd 缺失静默丢 30 天口径 | `TokenScanner.scan` 增 `zstdPath` 注入参数；发现 .zst 但无 zstd 时 `Result.zstdMissing=true`；菜单 Codex用量区块增提示行「未安装 zstd…brew install zstd」；status.json 同步 | self-test：zstdPath=nil 时 zstdMissing 且归档不计入 |
| 6 | 活跃 rollout 全量读入内存 | .jsonl 改 tail-read：先读尾部 1MB，找不到 `total_token_usage` 再全量兜底；.zst 路径不变 | self-test 新夹具：>1MB 文件尾部命中 / 仅开头有 token_count 时兜底 |
| 7 | DateFormatter 每次新建 | `Fmt.time/dayTime/day/expires` 改静态缓存 formatter | 行为不变 |
| 8 | Tibo 第三方链接直开 | `Fmt.webURL` 仅放行 http/https，菜单建项与 `openLink` 双保险 | self-test：javascript:/file: 拒绝 |
| 9 | 更新包无哈希校验 | release.sh 生成并上传 `CodexUsage.zip.sha256`；update.sh 下载后 `shasum -a 256 -c`，缺失或不匹配即中止 | tests/script_test.py 新夹具：mismatch 时中止且旧 app 不动 |
| 10 | 7d/30d 窗口口径 | 现状 `day >= now-7d/30d` 实际含今天共 8/31 个日历日，与「近 7 天/近 30 天」文案不符；Token Monitor 对账基准是 today（不受影响）。统一为含今天共 7/30 个日历日（cutoff 改 now-6d / now-29d），展示数字会略降，属修正而非丢数据 | self-test 窗口断言同步；PLAN 注明口径 |
| 11 | 文档同步 | 头注释与 PLAN §1「每 60 秒」→ 30 秒（代码现状）；PLAN §3 周期数修正；PLAN 增 §4.9 记录本轮变更；docs/ 随分支提交 | 文档与代码一致 |

## 不做

- 刷新周期保持额度 30s / 慢项 5min 不变。
- 不引入 Developer ID 公证（需付费账号，README 已有右键打开指引）。
- 不改 LaunchAgent 开机自启方案、不动姊妹项目同构架构。

## 总验收

1. `build.sh` 零 warning。
2. `CodexUsage --self-test` 全过（含新增夹具）。
3. `python3 -m unittest discover -s tests -p '*_test.py'` 全过。
4. `CodexUsage --once` 实跑一次联网自检正常。
