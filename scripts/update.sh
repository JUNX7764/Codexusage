#!/bin/bash
# CodexUsage 就地更新：从 GitHub Releases 下载最新发布包 → 替换已安装的 .app → 重启
# 由 app 菜单「⬆ 新版本可用，点击更新」唤起 Terminal 代跑（脚本随包内置在 .app Resources，
# 不依赖 clone 目录）；也可手动运行。发布产物由 scripts/release.sh 制作
set -euo pipefail

REPO="JUNX7764/Codexusage"
ZIP_URL="https://github.com/${REPO}/releases/latest/download/CodexUsage.zip"
APP_NAME="CodexUsage.app"
LABEL="com.local.codex-usage"
MYUID="$(id -u)"
AGENT_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

TMP="$(mktemp -d)"
KEEP_TMP=0
trap '[ "$KEEP_TMP" = 1 ] || rm -rf "$TMP"' EXIT

echo "==> 1/4 下载最新 Release（${ZIP_URL}）"
if ! curl -fsSL --max-time 180 -o "${TMP}/CodexUsage.zip" "$ZIP_URL"; then
    echo "!! 下载失败（可能尚未发布任何 Release）——打开 Releases 页面手动下载"
    open "https://github.com/${REPO}/releases"
    exit 1
fi

echo "==> 2/4 校验发布包"
unzip -q -o "${TMP}/CodexUsage.zip" -d "$TMP"
if [ ! -x "${TMP}/${APP_NAME}/Contents/MacOS/CodexUsage" ]; then
    echo "!! 发布包内容异常（缺可执行文件）"
    exit 1
fi

# 定位已安装副本（~/Applications 优先，/Applications 兜底，与 README 安装说明一致）
INSTALLED=""
for cand in "$HOME/Applications/${APP_NAME}" "/Applications/${APP_NAME}"; do
    [ -d "$cand" ] && INSTALLED="$cand" && break
done
if [ -z "$INSTALLED" ]; then
    echo "!! 未找到已安装的 ${APP_NAME}（~/Applications 与 /Applications 均无）"
    echo "   已下载解压到：${TMP} —— 手动拖入 /Applications 即完成安装"
    KEEP_TMP=1
    open -R "${TMP}/${APP_NAME}"
    exit 0
fi

echo "==> 3/4 替换 $INSTALLED"
# LaunchAgent 托管时先 bootout：KeepAlive 会在换包中途拉起旧二进制；
# 直接 kickstart 换包会 LaunchServices 拒启，必须 bootout → 换包 → bootstrap
AGENT=0
if launchctl print "gui/${MYUID}/${LABEL}" >/dev/null 2>&1; then
    AGENT=1
    launchctl bootout "gui/${MYUID}/${LABEL}" >/dev/null 2>&1 || true
fi
# LaunchServices 可能另持 GUI 实例（与 LaunchAgent 并存），换包前全部杀干净
pkill -x CodexUsage 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
cp -R "${TMP}/${APP_NAME}" "$INSTALLED"

echo "==> 4/4 重启"
if [ "$AGENT" = 1 ] && [ -f "$AGENT_PLIST" ]; then
    launchctl bootstrap "gui/${MYUID}" "$AGENT_PLIST"
else
    open "$INSTALLED"
fi
echo "✅ 更新完成：${INSTALLED}（版本 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo '?')）"
