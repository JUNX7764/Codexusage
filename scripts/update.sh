#!/bin/bash
# CodexUsage 就地更新：git pull → 重新构建 → 替换已安装的 .app → 重启
# 由 app 菜单「⬆ 新版本可用，点击更新」唤起 Terminal 代跑；也可手动运行：scripts/update.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexUsage.app"
LABEL="com.local.codex-usage"
MYUID="$(id -u)"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 1/4 拉取最新代码（${SRC}）"
git -C "$SRC" pull --ff-only

echo "==> 2/4 构建"
"$SRC/build.sh"

# 定位已安装副本（~/Applications 优先，/Applications 兜底，与 README 安装说明一致）
INSTALLED=""
for cand in "$HOME/Applications/$APP_NAME" "/Applications/$APP_NAME"; do
    [ -d "$cand" ] && INSTALLED="$cand" && break
done
if [ -z "$INSTALLED" ]; then
    echo "!! 未找到已安装的 ${APP_NAME}（~/Applications 与 /Applications 均无）"
    echo "   新版本已构建在：$SRC/$APP_NAME —— 手动拖入 /Applications 即完成更新"
    open -R "$SRC/$APP_NAME"
    exit 0
fi

echo "==> 3/4 替换 $INSTALLED"
# LaunchAgent 托管时先 bootout：KeepAlive 会在换包中途拉起旧二进制；
# 直接 kickstart 换包会 LaunchServices 拒启，必须 bootout → 换包 → bootstrap
AGENT=0
if launchctl print "gui/$MYUID/$LABEL" >/dev/null 2>&1; then
    AGENT=1
    launchctl bootout "gui/$MYUID/$LABEL" >/dev/null 2>&1 || true
fi
# LaunchServices 可能另持 GUI 实例（与 LaunchAgent 并存），换包前全部杀干净
pkill -x CodexUsage 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
cp -R "$SRC/$APP_NAME" "$INSTALLED"

echo "==> 4/4 重启"
if [ "$AGENT" = 1 ] && [ -f "$AGENT_PLIST" ]; then
    launchctl bootstrap "gui/$MYUID" "$AGENT_PLIST"
else
    open "$INSTALLED"
fi
echo "✅ 更新完成：${INSTALLED}（版本 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo '?')）"
