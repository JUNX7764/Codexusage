# CodexUsage 开发说明

需要 macOS 13 或更新版本、Apple Silicon 和 Xcode Command Line Tools。

```bash
./build.sh
```

发布正式版本前确认工作区干净且 HEAD 已推送至 main，然后运行 `scripts/release.sh v1.2.3`。脚本构建并校验发布资产后推送 tag 并创建或补全 GitHub Release。

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
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-states
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-empty
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-update
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-narrow

# 面板本地截图：只捕捉面板；scroll-end 可先滚动到底部
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-output=/tmp/codex-panel.png
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview-dark --visual-preview-scroll-end --visual-preview-output=/tmp/codex-panel-bottom.png

# 面板事件回归：Esc / 外部点击 / R 刷新，自动验证并退出
./CodexUsage.app/Contents/MacOS/CodexUsage --visual-preview --visual-preview-events
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `CodexUsage.swift` | 全部源码（单文件 AppKit 菜单栏应用） |
| `vendor/zstddeclib.c` | 上游 zstd v1.5.7 单文件解码源（BSD-3-Clause，许可见 `vendor/zstd-LICENSE`），用于进程内解压 `.zst` 会话归档 |
| `vendor/zstd_bridge.c` / `.h` | zstd 解码的 C 桥接层（供 Swift 调用） |
| `build.sh` | 编译 + 打包 + ad-hoc 签名脚本 |
| `Info.plist` | App Bundle 配置（LSUIElement = 菜单栏常驻） |
| `scripts/icon_gen.swift` | 图标生成脚本（缺 icns 时 build.sh 自动调用） |
| `scripts/update.sh` | 就地更新脚本（从 Release 下载替换；build.sh 随包内置进 .app Resources） |
| `scripts/release.sh` | 发布脚本（本地 tag → 构建与测试 → 资产校验 → 推 tag → GitHub Release） |
| `tests/script_test.py` | 更新、发布、签名故障的离线回归测试 |
| `PLAN.md` | 开发规格（数据源已实测、解析规则、UI 规格、验收标准） |
