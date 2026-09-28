# CodexUsage — Codex 用量菜单栏小工具

macOS 菜单栏应用，显示 OpenAI Codex（ChatGPT Plus）订阅的 5 小时 / 7 天额度余额与本地 token 统计。原生 Swift 单文件实现，对标同机 KimiUsage / GlmUsage，替代 Electron 版 CodexMeter（省 ~200MB+ 内存）。

## 功能

- 菜单栏两行：5H / 7D 剩余百分比
- 下拉：套餐、重置时间、重置卡、今天/7天/30天 token 统计
- 5H、7D、Token、充值卡分别记录最后成功时间；刷新失败时保留旧值，同时显示错误，超过对应时限后标 ⚠
- “最近尝试刷新”显示请求开始时间；额度每 60 秒刷新，Token/充值卡每 5 分钟刷新，手动刷新会拉取全部项目
- 一轮刷新最多运行一次；刷新中的多次手动请求合并为一轮后续完整刷新
- `--once` 命令行自检；凭据只读 `~/.codex/auth.json`（Codex CLI 维护），不落盘不外传
- 401 续期前及写回前重新读取 auth.json；若 Codex CLI 已更新认证字段，则保留最新值。续期只合并认证字段到最新 JSON，使用唯一临时文件、原子替换和仅所有者权限。官方客户端不使用共享文件锁，检查与替换之间仍存在无法完全消除的并发写入窗口

## 构建

需要 macOS 13+ 与 Xcode CLT：

```bash
./build.sh
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test
./CodexUsage.app/Contents/MacOS/CodexUsage --once
```

`--self-test` 仅使用临时目录和假凭据，不读取真实 Codex 凭据、不访问网络或会话文件。

## 设计文档

开发规格见 [PLAN.md](PLAN.md)（数据源已实测、解析规则、UI 规格、验收标准）。
