#!/bin/bash
# 发布流程：本地 tag → 构建与离线测试 → 签名和资产校验 → 推 tag → 创建 Release。
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="JUNX7764/Codexusage"
APP_NAME="CodexUsage.app"
EXECUTABLE="CodexUsage"
LABEL="com.local.codex-usage"
NEEDS_PEAK_TEST=0
TAG="${1:-}"
TMP=""
STAGING=""
TAG_CREATED=0
TAG_PUSHED=0

on_exit() {
    local rc=$?
    trap - EXIT
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
    if [ -n "$STAGING" ]; then rm -rf "$STAGING"; fi
    if [ "$rc" -ne 0 ] && [ "$TAG_CREATED" = 1 ] && [ "$TAG_PUSHED" = 0 ]; then
        git -C "$DIR" tag -d "$TAG" >/dev/null 2>&1 || echo "!! 请手动删除本地 tag ${TAG}"
    fi
    exit "$rc"
}
trap on_exit EXIT

if [ -z "$TAG" ]; then
    LATEST="$(git -C "$DIR" describe --tags --abbrev=0 2>/dev/null || echo 无)"
    echo "用法: $0 vX.Y.Z（当前最新 tag: ${LATEST}）"
    exit 1
fi
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "!! tag 需形如 v1.2.3（只发正式版）"
    exit 1
fi

cd "$DIR"
git diff --quiet && git diff --cached --quiet || { echo "!! 工作区有未提交改动，先提交"; exit 1; }
git fetch origin main --quiet
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "!! 本地 HEAD 与 origin/main 不一致，先 push"
    exit 1
fi

ORIGIN="$(git remote get-url origin)"
ORIGIN="${ORIGIN%.git}"
ORIGIN="${ORIGIN#https://github.com/}"
ORIGIN="${ORIGIN#git@github.com:}"
ORIGIN="${ORIGIN#ssh://git@github.com/}"
if [ "$ORIGIN" != "$REPO" ]; then
    echo "!! origin 仓库 ${ORIGIN} 与发布目标 ${REPO} 不一致"
    exit 1
fi
for expected in \
    "REPO=\"${REPO}\"" \
    "APP_NAME=\"${APP_NAME}\"" \
    "EXECUTABLE=\"${EXECUTABLE}\"" \
    "LABEL=\"${LABEL}\""; do
    if ! /usr/bin/grep -Fqx "$expected" "$DIR/scripts/update.sh"; then
        echo "!! update.sh 配置不匹配：${expected}"
        exit 1
    fi
done

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    if [ "$(git rev-parse "refs/tags/${TAG}^{commit}")" != "$(git rev-parse HEAD)" ]; then
        echo "!! tag ${TAG} 已存在且指向其他 commit"
        exit 1
    fi
else
    git tag "$TAG"
    TAG_CREATED=1
fi

echo "==> 构建 ${TAG}（本地 tag 用于版本注入）"
./build.sh
APP="$DIR/$APP_NAME"
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CUBuildVersion' "$APP/Contents/Info.plist")" != "$TAG" ]; then
    echo "!! 构建版本与 ${TAG} 不一致"
    exit 1
fi

echo "==> 离线回归与签名校验"
"$BINARY" --self-test
if [ "$NEEDS_PEAK_TEST" = 1 ]; then
    "$BINARY" --peak-test
fi
codesign --verify --deep --strict "$APP"

echo "==> 打包并校验发布资产（DMG 人工安装，zip 自动更新）"
TMP="$(mktemp -d)"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$EXECUTABLE $TAG" -srcfolder "$STAGING" -ov -format UDZO "$TMP/$EXECUTABLE.dmg" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP/$EXECUTABLE.zip"
# zip 附带 SHA256 校验文件：update.sh 下载后 shasum -c 校验，缺失或不匹配即中止
(cd "$TMP" && shasum -a 256 "$EXECUTABLE.zip" > "$EXECUTABLE.zip.sha256")
hdiutil verify "$TMP/$EXECUTABLE.dmg" >/dev/null
unzip -t "$TMP/$EXECUTABLE.zip" >/dev/null

echo "==> 推送 tag 并创建 GitHub Release"
git push origin "$TAG"
TAG_PUSHED=1
gh release create "$TAG" --repo "$REPO" --title "$TAG" --generate-notes \
    "$TMP/$EXECUTABLE.dmg" "$TMP/$EXECUTABLE.zip" "$TMP/$EXECUTABLE.zip.sha256"

echo "✅ 已发布 ${TAG}；已装旧版本将在下轮检查（≤2 小时）提示更新"
