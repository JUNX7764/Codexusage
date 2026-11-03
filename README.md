# CodexUsage — Codex 订阅余量菜单栏小工具

macOS 菜单栏常驻，一瞥即知 OpenAI Codex（ChatGPT）订阅的 5 小时 / 7 天额度余量。原生 Swift 单文件实现，纯本地运行。

与 [KimiUsage](https://github.com/JUNX7764/kimi-usage-menubar)、[GlmUsage](https://github.com/JUNX7764/Glmusage) 是同族三件套，分别盯 Kimi / GLM / Codex 的订阅余量。

## 功能

- **菜单栏**：两行常驻，5H / 7D 剩余百分比；≥80% 绿色、40–79% 系统文本色、20–39% 橙色、<20% 红色，浅色/深色分别配色
- **下拉面板**
  - `.popover` 材质 + 90% 不透明窗口底色、16px 圆角；系统开启“减少透明度”时使用纯色背景
  - 信息文字使用正常主/次文本色，不再显示为禁用菜单项灰字
  - 额度：套餐等级、5H / 7D 重置时间、重置卡
  - Tibo 重置动态：预告中的重置带预估窗口、最近一条已确认动态，点击行跳最新原帖
  - Token 统计：今天 / 近 7 天 / 近 30 天
  - 外部用量（Codex 之外，独立区块）：统计本机其他 AI 工具消耗的 token，与 Codex 用量分开显示、不合并计算
    - 覆盖来源：Proma、Claude Code 本机会话、Hermes Agent 中走 OpenAI 系模型（gpt* / codex* / chatgpt* / o 系列）的会话
    - 没装对应工具时该来源自然为 0；input 含 cache read
    - 同一会话在多个目录重复写入时只统计一处，避免双算
- **刷新机制**
  - 额度每 30 秒；Token / 重置卡每 5 分钟；手动刷新拉取全部项目
  - 一轮刷新最多运行一次，刷新中的多次手动请求合并为一轮后续完整刷新
  - 5H、7D、Token、重置卡分别记录最后成功时间；失败时保留旧值并显示错误，超过对应时限标 ⚠
  - 「最近尝试刷新」显示请求开始时间
  - 打开下拉面板即触发一轮全量刷新；面板打开期间不重建内容，数据在关闭后更新、下次打开即最新
  - 近 7 天 / 近 30 天为含今天共 7 / 30 个日历日；本机未安装 zstd 时压缩归档会话不计入，菜单会给出提示
  - 外部用量来源全部不可读时保留旧值并显示错误与 ⚠ 过期标注，不静默清零
  - Tibo 重置动态每 5 分钟刷新（ETag/304 轮询，内容未变也算有效成功），失败只降级该区块；预估窗口展示「预估/待确认」，不是倒计时（数据源：AIHOT 公开接口，匿名只读、不经凭据）；事件链接仅放行 http/https

## 安装与更新

需要 macOS 13+。安装：到 [Releases](https://github.com/JUNX7764/Codexusage/releases) 下载最新 `CodexUsage.dmg`，打开后把 CodexUsage 拖进 Applications（或 `~/Applications`）双击运行。首次打开如遇 Gatekeeper 提示，右键 → 打开。

**更新**：发布新 Release 后（每 30 分钟检查一次，打开面板也会触发一次节流检查），面板最上方出现「⬆ 新版本可用，点击更新」，点击即自动下载替换并重启（zip 经 SHA256 校验后才替换）；也可以随时手动重跑安装步骤。日常代码提交不会触发更新提示——只有正式发版才会。

从源码构建（开发者）：

```bash
./build.sh
```

发布新版本（开发者，要求工作区干净且已推送）：`scripts/release.sh v1.2.3`——创建本地 tag → 构建与离线自测 → 签名及 DMG/zip 校验 → 推送 tag → 创建 GitHub Release。验证失败不会推送远端 tag。

## 原理

- **凭据**：只读 `~/.codex/auth.json`（Codex CLI 维护），不落盘、不外传
- **401 续期**：续期前及写回前重新读取 auth.json；若 Codex CLI 已更新认证字段，保留最新值。续期只合并认证字段到最新 JSON，使用唯一临时文件、原子替换和仅所有者权限。官方客户端不使用共享文件锁，检查与替换之间仍存在无法完全消除的并发写入窗口
- **重置卡**：接口缺少列表或结构错误时按失败处理，保留旧卡和原成功时间；只有明确返回的空列表才表示暂无可用卡
- **外部用量**：外部会话目录与数据库全程只读；Hermes 按累计快照差分统计，首次扫描回填近 30 天

## 隐私与安全

- 纯本地运行，数据不上传
- 凭据只读，不写入、不外传
- 扫描的外部会话目录与数据库全程只读

## 调试与自检

```bash
# 离线自检：只用临时目录和假凭据，不读真实 Codex 凭据、不联网
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test

# 脚本回归：PATH mock 故障注入，不操作真实 app、LaunchAgent 或 GitHub
python3 -m unittest discover -s tests -p '*_test.py'

# 真实自检：读取本机凭据、联网拉一次数据后退出
./CodexUsage.app/Contents/MacOS/CodexUsage --once

# 固定假数据视觉预览：不联网、不写真实 status.json
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-normal
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-dark
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-long

# 面板事件回归：Esc / 外部点击 / R 刷新，自动验证并退出
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-events
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `CodexUsage.swift` | 全部源码（单文件 AppKit 菜单栏应用） |
| `build.sh` | 编译 + 打包 + ad-hoc 签名脚本 |
| `Info.plist` | App Bundle 配置（LSUIElement = 菜单栏常驻） |
| `scripts/icon_gen.swift` | 图标生成脚本（缺 icns 时 build.sh 自动调用） |
| `scripts/update.sh` | 就地更新脚本（从 Release 下载替换；build.sh 随包内置进 .app Resources） |
| `scripts/release.sh` | 发布脚本（本地 tag → 构建与测试 → 资产校验 → 推 tag → GitHub Release） |
| `tests/script_test.py` | 更新、发布、签名故障的离线回归测试 |
| `PLAN.md` | 开发规格（数据源已实测、解析规则、UI 规格、验收标准） |

## License

MIT
