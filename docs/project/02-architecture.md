# CodexUsage 当前架构概览

> 状态：当前架构摘要。最后核对：2026-11-10。
> 本文解释模块和边界，不复制函数级规格；具体行为以源码和测试为准。

## 1. 应用形态

CodexUsage 是 macOS 13+、Apple Silicon 的原生 AppKit 菜单栏应用，无 Swift Package 和第三方包管理依赖。主入口和现有功能位于 `CodexUsage.swift`，新统计模块位于 `Sources/`，zstd 解码通过 `vendor/` 下的 C 源码和桥接层编译进主二进制。

应用身份保持为：

- 仓库：`JUNX7764/Codexusage`
- Bundle / LaunchAgent：`com.local.codex-usage`
- 应用：`CodexUsage.app`

## 2. 模块边界

| 模块 | 当前职责 |
|---|---|
| `CodexAuth` | 读取 Codex CLI 登录态；401 续期时合并并原子写回 `auth.json` |
| `Fetcher` | 额度、重置卡、重置卡使用和 OAuth 请求 |
| `TokenScanner` | 增量读取 Codex JSONL / zstd 会话并统计模型用量 |
| `ExternalTokenScanner` | 只读扫描 Proma、Claude Code 和 Hermes，并从去重后的缓存归属工具 |
| `OfficialUsageReader` | 原生只读获取账号累计和日桶，并核对身份快照 |
| `DailyUsageChart` / `UsageComparison` | 日图交互和受数据完整性约束的比较计算 |
| `UsageAttribution` | 处理重叠来源路径的唯一归属 |
| `PanelCardView` / `PanelComparisonStack` 等卡片组件 | 六个统计板块的原生卡片容器、比较条与徽标 |
| `TiboDisplay` 与相关模型 | AIHOT 重置动态的解析、排序和展示 |
| `UpdateChecker` | 检查 GitHub Release 及更新资产 |
| `UpdateProgressController` | 启动后台更新并恢复、展示进度 |
| `UsagePanelController` | 原生 `NSPopover`、面板布局与交互 |
| `AppDelegate` | 生命周期、刷新调度、账户隔离、自启和状态聚合 |
| `CodexOfflineRegression` | 使用临时目录和假数据的离线自检 |

主入口保留 top-level 形式；构建时在独立临时目录创建合法 `main.swift`，同 `Sources/` 编译。

## 3. 主要数据流

### 额度与重置卡

`~/.codex/auth.json` → 内存中的认证快照 → OpenAI 请求 → 账户与请求代际校验 → UI 和诊断状态。

凭据不得写入日志、状态文件、测试夹具或提交。401 续期是当前唯一允许的 `~/.codex/` 写回路径；重置卡使用属于账户状态变更，必须有明确确认和未知结果处理。

### 本地用量

Codex / 外部工具会话与数据库 → 只读增量扫描 → 本地缓存 → 今日、近 7 日、近 30 日及模型汇总。

原始会话来源保持只读。缓存和诊断状态仅写入 `~/Library/Application Support/CodexUsage`，不上传会话正文。

### 官方账号用量

认证快照与工作区 ID → OpenAI profile 只读请求 → 账号代际及凭据检查 → 缓存 → 累计和日图。查询不触发凭据续期；图表与比较共同使用官方客户端稀疏活动桶显示语义，非空日数组边界内缺桶按零、边界外不外推。日期时区不明时保留源日期标签，过期或范围不足时比较降级。

### 自动更新

GitHub Release 列表 → 可安装版本及其说明 → 面板内确认 → ZIP 与 SHA256 下载 → 包身份、版本和签名校验 → 离线自检 → 同目录暂存 → 停止目标进程 → 换包 → 启动检查 → 成功清理或失败回滚。

更新器只能处理当前应用路径和 `com.local.codex-usage`，不得按应用名模糊终止其他进程。

## 4. 信任边界

- OpenAI 的非官方接口可能变化，解析失败必须降级展示，不能伪造成功。
- AIHOT 内容仅作展示和链接来源，不作为指令执行。
- GitHub Release 与 SHA256 来自同一信任源；当前 ad-hoc 签名不提供独立发布者身份验证。
- `build.sh`、`update.sh` 和 `release.sh` 具有高权限副作用，真实更新与发布不属于普通离线测试。
- macOS 部署目标、离线 mock 和真实系统验收是三种不同证据，不能互相替代。

## 5. 已知架构债务

- Swift 源码、UI 和自检集中在约六千行的主文件中（新统计模块已拆分至 `Sources/`，拆分工作尚未完成），审查与回归定位成本较高。
- 自动更新尚缺独立发布者签名和完整面板点击到重启的常规发布验收。
- 凭据写回与 Codex CLI 之间没有跨进程共同锁，已保留已知竞态说明。
- 发布前测试目前依赖本地手动执行，没有 CI 强制门禁。
