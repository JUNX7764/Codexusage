# CodexUsage — Codex 订阅余量菜单栏小工具

macOS 菜单栏常驻，一瞥即知 OpenAI Codex（ChatGPT Plus）订阅的 5 小时 / 7 天额度余量。原生 Swift 单文件实现，纯本地运行。

与 [KimiUsage](https://github.com/JUNX7764/kimi-usage-menubar)、[GlmUsage](https://github.com/JUNX7764/Glmusage) 是同族三件套，分别盯 Kimi / GLM / Codex 的订阅余量。

## 功能

- **菜单栏**：两行常驻，5H / 7D 剩余百分比
- **下拉面板**
  - 额度：套餐等级、5H / 7D 重置时间、重置卡
  - Tibo 重置动态：预告中的重置带预估窗口、最近一条已确认动态，点击行跳最新原帖
  - Token 统计：今天 / 近 7 天 / 近 30 天
  - 外部用量（非 Codex，独立区块）：
    - Proma（agent-sessions，与 Token Monitor 的 proma 来源同款口径）
    - Claude Code 本机会话
    - hermes 中 OpenAI 系模型（gpt* / codex* / chatgpt* / o+数字）的 token
    - 与 Codex CLI 本机口径互补、不混算；input 含 cache read（与 Token Monitor 的 totalTokens 口径一致）
    - Proma 运行时双写目录（sdk-config/sessions）不扫，防双算
- **刷新机制**
  - 额度每 60 秒；Token / 重置卡每 5 分钟；手动刷新拉取全部项目
  - 一轮刷新最多运行一次，刷新中的多次手动请求合并为一轮后续完整刷新
  - 5H、7D、Token、重置卡分别记录最后成功时间；失败时保留旧值并显示错误，超过对应时限标 ⚠
  - 「最近尝试刷新」显示请求开始时间
  - Tibo 重置动态每 5 分钟刷新（ETag/304 轮询，内容未变也算有效成功），失败只降级该区块；预估窗口展示「预估/待确认」，不是倒计时（数据源：AIHOT 公开接口，匿名只读、不经凭据）

## 安装与构建

需要 macOS 13+ 与 Xcode Command Line Tools（未装先执行 `xcode-select --install`）：

```bash
./build.sh
```

产物 `CodexUsage.app`，拖到 `/Applications`（或 `~/Applications`）双击运行。首次打开如遇 Gatekeeper 提示，右键 → 打开。

## 原理

- **凭据**：只读 `~/.codex/auth.json`（Codex CLI 维护），不落盘、不外传
- **401 续期**：续期前及写回前重新读取 auth.json；若 Codex CLI 已更新认证字段，保留最新值。续期只合并认证字段到最新 JSON，使用唯一临时文件、原子替换和仅所有者权限。官方客户端不使用共享文件锁，检查与替换之间仍存在无法完全消除的并发写入窗口
- **重置卡**：接口缺少列表或结构错误时按失败处理，保留旧卡和原成功时间；只有明确返回的空列表才表示暂无可用卡
- **外部用量**：外部目录与 hermes 数据库全程只读；hermes 走累计行快照差分（首扫按 last_seen 回填近 30 天）

## 隐私与安全

- 纯本地运行，数据不上传
- 凭据只读，不写入、不外传
- 扫描的外部目录与 hermes 数据库全程只读

## 调试与自检

```bash
# 离线自检：只用临时目录和假凭据，不读真实 Codex 凭据、不联网
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test

# 真实自检：读取本机凭据、联网拉一次数据后退出
./CodexUsage.app/Contents/MacOS/CodexUsage --once
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `CodexUsage.swift` | 全部源码（单文件 AppKit 菜单栏应用） |
| `build.sh` | 编译 + 打包 + ad-hoc 签名脚本 |
| `Info.plist` | App Bundle 配置（LSUIElement = 菜单栏常驻） |
| `scripts/icon_gen.swift` | 图标生成脚本（缺 icns 时 build.sh 自动调用） |
| `PLAN.md` | 开发规格（数据源已实测、解析规则、UI 规格、验收标准） |

## License

MIT
