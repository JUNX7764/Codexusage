# 项目约定

## 项目与入口

- CodexUsage 是 macOS 13+、Apple Silicon 的原生 AppKit 菜单栏应用；主源码为 `CodexUsage.swift`，以 top-level 代码启动，不使用 Swift Package。拆分源码时需保留符合 Swift 多文件编译规则的入口，并同步调整 `build.sh`。
- 主文件包含凭据读取/续期、额度与重置卡网络请求、Codex 和外部工具用量扫描、更新控制器、Popover UI 及离线自检。`vendor/zstd_bridge.c` 引入内置 zstd 解码，`Info.plist` 定义 Bundle 身份与菜单栏常驻属性。
- 用户说明以 `README.md` 为入口；构建、自检和权限经验见 `docs/DEVELOPMENT.md`，当前架构、维护与发布约定见 `docs/project/`。`PLAN.md`、`VISUAL_OPTIMIZATION_PLAN.md` 和 `docs/features/` 为历史记录，判断当前行为时须核对源码与测试。
- 统计区按「用量情况 → 用量简析 → 工具明细」排列，两处板块边界与页脚复用同一原生分隔线样式，不额外减淡，线上下各保留约 8pt 留白，可适当增加面板高度；具体视觉与验收约定见 `docs/project/11-usage-insights-prd.md`。

## 构建与验证

- `./build.sh` 编译 arm64 / macOS 13.0 目标，重建项目内 `CodexUsage.app` 并执行 ad-hoc 签名验证；会替换现有构建产物，纯审查可将编译输出隔离到会话工作台。
- `./CodexUsage.app/Contents/MacOS/CodexUsage --self-test` 为离线自检，使用临时目录和假凭据。`python3 -m unittest discover -s tests -p '*_test.py'` 为 PATH mock 的更新、发布及构建故障回归，不等同于真实安装验收。
- `bash -n build.sh scripts/update.sh scripts/release.sh` 检查 Shell 语法。`--visual-preview*` 使用固定假数据；真实原生交互需另外验证，不能用源码检查替代。
- `--once` 会读取真实登录态、扫描本机会话并联网，不是离线测试。`scripts/update.sh` 会替换应用并处理目标进程，`scripts/release.sh` 会推送 tag 和发布 GitHub Release；普通审查不得直接运行这些真实操作。

## 数据与安全边界

- `~/.codex/auth.json` 中认证字段不得输出到日志、状态文件、报告或提交；仅在额度返回 401 且满足冷却条件时执行 OAuth 续期并原子合并写回。更改此链路必须保留账户隔离、凭据轮换检查和仅所有者访问的文件权限。
- Token 统计读取本机 Codex JSONL / zstd 归档，以及 Proma、Claude Code JSONL 和 Hermes SQLite；原始来源只读，缓存与诊断状态位于 `~/Library/Application Support/CodexUsage`。测试须注入临时根目录和缓存路径，避免接触真实会话与凭据。
- 更新/发布身份必须保持一致：仓库 `JUNX7764/Codexusage`、Bundle/LaunchAgent `com.local.codex-usage`、应用 `CodexUsage.app`。修改需覆盖下载校验、版本拒绝降级、进程定位和故障回滚测试。

<!-- proma:memory:start -->
## 记忆维护

- 项目记忆索引：[MEMORY.md](</Users/Chester/.proma/agent-workspaces/codexusage/memory/MEMORY.md>)；详细主题按索引按需读取，新增、移动、归档主题时同步索引。
- 全局用户画像：[user_profile.md](</Users/Chester/.proma/memory/user_profile.md>)，跨项目共享；本项目补充偏好存入 /Users/Chester/.proma/agent-workspaces/codexusage/memory/project-preferences.md 并加入项目索引，仅在本项目覆盖全局偏好。
- 在任务中及时修订已确认的偏好、经验和决策，保留来源、适用范围和核验日期；不把临时任务进度写成永久偏好。超过一周的阶段性要求结合本轮证据复查；到期或被替代的内容移出有效入口并可恢复地归档。读取不等于核验，不编造用户事实。
<!-- proma:memory:end -->
