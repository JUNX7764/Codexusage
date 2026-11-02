#!/bin/bash
# 发布流程（成熟项目惯例）：打 tag → 构建 → ditto 打包 → 创建 GitHub Release 并上传产物。
# 版本提示只认 Release，所以「发版」是唯一让已装 app 弹更新横幅的动作。
# 用法：scripts/release.sh vX.Y.Z（要求工作区干净且 HEAD 已推送）
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="JUNX7764/Codexusage"
TAG="${1:-}"

if [ -z "$TAG" ]; then
    LATEST="$(git -C "$DIR" describe --tags --abbrev=0 2>/dev/null || echo 无)"
    echo "用法: $0 vX.Y.Z（当前最新 tag: ${LATEST}）"
    exit 1
fi
case "$TAG" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "!! tag 需形如 v1.2.3（只发正式版：releases/latest 不含预发布，发了也不会提示）"; exit 1 ;;
esac

cd "$DIR"
git diff --quiet && git diff --cached --quiet || { echo "!! 工作区有未提交改动，先提交"; exit 1; }
git fetch origin main --quiet
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "!! 本地 HEAD 与 origin/main 不一致，先 push"; exit 1
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "!! tag ${TAG} 已存在"; exit 1
fi

echo "==> 打 tag ${TAG} 并推送"
git tag "$TAG"
git push origin "$TAG"

echo "==> 构建（此时 git describe = ${TAG}，产物版本注入正确）"
./build.sh

echo "==> 打包发布资产（双格式）"
# DMG 给人下载：打开拖进 Applications 安装（MonitorControl/Stats 同款，DMG 内含
# /Applications 符号链接做拖拽落点）；zip 给 update.sh 程序化替换（Sparkle 官方支持的
# 更新包格式，资产名固定 CodexUsage.zip，供 releases/latest/download/ 稳定下载）
TMP="$(mktemp -d)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$TMP" "$STAGING"' EXIT
cp -R "$DIR/CodexUsage.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "CodexUsage ${TAG}" -srcfolder "$STAGING" -ov -format UDZO "${TMP}/CodexUsage.dmg" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$DIR/CodexUsage.app" "${TMP}/CodexUsage.zip"

echo "==> 创建 GitHub Release 并上传产物"
gh release create "$TAG" --repo "$REPO" --title "$TAG" --generate-notes "${TMP}/CodexUsage.dmg" "${TMP}/CodexUsage.zip"

echo "✅ 已发布 ${TAG}（产物 CodexUsage.zip）；已装旧版本将在下轮检查（≤2 小时）提示更新"
