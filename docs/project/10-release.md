# CodexUsage 发布与回滚说明

> 状态：当前发布清单。最后核对：2026-11-06。
> 本文区分脚本已经自动执行的检查与仍需人工完成的验收。

## 1. 发布资产

每个正式版本必须包含：

- `CodexUsage.dmg`：人工下载与拖拽安装；
- `CodexUsage.zip`：应用内自动更新；
- `CodexUsage.zip.sha256`：ZIP 完整性校验。

Bundle、LaunchAgent、更新器和发布目标必须继续使用既有身份，不得在不同仓库或应用之间混用。

## 2. 发布前本地门禁

```bash
git status --short
./build.sh
./CodexUsage.app/Contents/MacOS/CodexUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

确认工作区干净、HEAD 已推送且目标版本符合变更类型后，执行：

```bash
scripts/release.sh vX.Y.Z
```

脚本自动完成：远端与身份检查、标签创建、构建、二进制自检、ad-hoc 签名验证、DMG / ZIP 打包、DMG 校验、ZIP 完整性检查、SHA256 生成以及 GitHub Release 创建或补全。

**脚本不会自动执行 Python 回归、真实面板更新、崩溃回滚或最低系统版本验收。**这些项目不得被“脚本跑完”替代。

## 3. 更新链路验收

更新器或更新控制器变化后，至少在真实安装副本上验收：

1. 从上一个正式 Release 安装旧版；
2. 通过面板点击更新并观察下载、安装和重启状态；
3. 核对新版版本、额度加载、面板交互和开机自启；
4. 注入启动失败，确认旧包恢复且旧版可以重新运行；
5. 分别覆盖 LaunchAgent 正常、关闭自启和安装路径含空格等状态；
6. 保留测试版本、路径、日期和结果，不把 mock 通过写成真实验收。

纯文档或不涉及更新链路的改动可以缩小范围，但应在提交或发布说明中明确未执行哪些测试。

## 4. 发布后检查

- 重新下载 Release ZIP，核对 SHA256 和压缩包完整性；
- 核对 `CUBuildVersion`、Bundle Identifier 和签名状态；
- 从发布包再次运行离线自检；
- 确认 Release 非 draft、非 prerelease，三个资产均已上传；
- 检查更新列表能选中目标版本，且不会选择资产不完整的更高版本。

## 5. 回滚与事故处理

更新脚本在停止旧进程后发生失败时，应恢复旧包并尝试重启。当前启动健康检查仍不能完全排除崩溃循环被误判为成功，因此发布者必须保留上一个已知可用的 Release 和安装包。

更新器拒绝降级。线上版本出现严重问题时，应撤回或预发布化受影响 Release，并发布版本号更高的修复版，而不是要求用户通过自动更新降到旧版本。

## 6. 当前公开分发限制

- 仅使用 ad-hoc 签名，README 需要指导用户处理 Gatekeeper；这不是 Developer ID 公证。
- ZIP 与 SHA256 来自同一 Release，尚无独立发布者签名验证。
- 尚无 CI 和 macOS 13 / 14 / 15 的完整兼容性矩阵。
- 完整面板点击升级尚未成为每个版本的固定验收证据。

在上述限制未解决前，发布说明应准确描述验证范围，不宣称“全链路可靠”或“所有系统均已验证”。
