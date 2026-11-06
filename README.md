# CodexUsage

**Codex 还剩多少，什么时候恢复？在 Mac 菜单栏一眼看见。**

无需反复打开网页，随时查看额度、重置时间和用量。

[下载 CodexUsage](https://github.com/JUNX7764/Codexusage/releases/latest) · macOS 13+ · Apple Silicon


**本地统计会话用量，不上传会话记录。**

<img src="docs/acceptance/v1.1.0/plus.png" width="330" alt="CodexUsage 开发预览：剩余额度、重置卡和用量统计" />

*截图使用演示数据。*

## 能做什么

- **随时看额度**：菜单栏显示适用的额度窗口及剩余百分比，点开即可查看重置时间。
- **管理重置卡和动态**：查看重置卡数量和到期时间，确认后可使用最早到期的可用卡；结果未知时可确认后用原请求重试。查看近期额度重置动态，预告时间仅供参考。
- **回顾使用情况**：合并查看本机今天、近 7 天和近 30 天的 OpenAI 模型 Token，点击周期行展开模型明细。
- **查看每日用量**：展示账号接口返回的累计 Token 和近 30 个源日期；图表可按日期查看，比较数据不足时明确提示。
- **了解工具分布**：查看本机 Codex、Proma、Claude Code 和 Hermes 中可识别的用量及来源状态。
- **方便日常使用**：支持立即刷新、开机自启和面板内更新进度。

额度和每日用量来自当前登录账号；周期表与工具分布来自本机可读取的会话记录，可能包含不同账号或 API 调用。两者统计范围不同，不相加。官方日数据的时区、稀疏日期含义和覆盖范围尚未确认，缺失日期不按零处理。

各工具的日志适配、订阅登录与官方汇总覆盖的核验情况见[用量来源兼容矩阵](docs/project/14-compatibility-matrix.md)。

重置卡使用后可能消耗一张卡且无法撤销。用卡接口已通过模拟响应验证，尚未进行真实兑换测试。

## 安装

1. 在 [Releases](https://github.com/JUNX7764/Codexusage/releases/latest) 下载最新的 `CodexUsage.dmg`。
2. 打开安装包，将 CodexUsage 拖入“应用程序”，然后打开。
3. 使用前请先在本机 Codex CLI 登录 ChatGPT 账号。应用会读取已有登录状态来查询额度。

首次打开如遇“已损坏”或“无法验证开发者”提示：前往“系统设置 → 隐私与安全性”，点击底部“仍要打开”；或在终端执行 `xattr -d com.apple.quarantine /Applications/CodexUsage.app`。本应用使用 ad-hoc 签名，不影响功能。

## 更新

有新版本时，点击面板顶部的更新提示，应用会显示更新进度并自动重启。较早的旧版本升级到带有此功能的版本时，仍会打开一次终端窗口。

## 数据与隐私

**本机会话记录和用量统计在 Mac 上处理，不会上传到开发者服务器。**

查询额度、重置卡和官方每日用量需要使用登录凭据连接 OpenAI；重置动态及版本检查分别连接 AIHOT 和 GitHub。登录状态过期时，应用可能续期并更新本机 Codex 凭据文件。

## 其他工具

同系列：[KimiUsage](https://github.com/JUNX7764/kimi-usage-menubar) · [GlmUsage](https://github.com/JUNX7764/Glmusage)

[开发说明](docs/DEVELOPMENT.md) · [MIT License](LICENSE)
