# CodexUsage — Codex 用量菜单栏小工具

macOS 菜单栏应用，显示 OpenAI Codex（ChatGPT Plus）订阅的 5 小时 / 7 天额度余额与本地 token 统计。原生 Swift 单文件实现，对标同机 KimiUsage / GlmUsage，替代 Electron 版 CodexMeter（省 ~200MB+ 内存）。

## 功能

- 菜单栏两行：5H / 7D 剩余百分比
- 下拉：套餐、重置时间、重置卡、今天/7天/30天 token 统计
- 数据过期标注：额度 >10 分钟、token >30 分钟未成功刷新即标 ⚠（不静默显示旧数据）
- `--once` 命令行自检；凭据只读 `~/.codex/auth.json`（Codex CLI 维护），不落盘不外传

## 构建

需要 macOS 13+ 与 Xcode CLT：

```bash
./build.sh
./CodexUsage.app/Contents/MacOS/CodexUsage --once
```

## 设计文档

开发规格见 [PLAN.md](PLAN.md)（数据源已实测、解析规则、UI 规格、验收标准）。
