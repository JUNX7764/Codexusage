#!/bin/bash
# CodexUsage 就地更新：下载并验证 Release，暂存成功后换包；启动失败恢复旧版本。
set -euo pipefail

REPO="JUNX7764/Codexusage"
ZIP_URL="https://github.com/${REPO}/releases/latest/download/CodexUsage.zip"
APP_NAME="CodexUsage.app"
EXECUTABLE="CodexUsage"
LABEL="com.local.codex-usage"
MYUID="$(id -u)"
AGENT_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

TMP="$(mktemp -d)"
KEEP_TMP=0
WORK=""
BACKUP=""
INSTALLED=""
AGENT=0
STOPPED=0
SUCCESS=0
NEW_VERSION=""

start_and_wait() {
    if [ "$AGENT" = 1 ]; then
        launchctl bootstrap "gui/${MYUID}" "$AGENT_PLIST"
    else
        open "$INSTALLED"
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
            sleep 1
            if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 1
    done
    echo "!! ${EXECUTABLE} 启动后未稳定驻留"
    return 1
}

rollback() {
    echo "==> 更新失败，恢复旧版本"
    set +e
    if [ "$AGENT" = 1 ]; then
        launchctl bootout "gui/${MYUID}/${LABEL}" >/dev/null 2>&1
    fi
    pkill -x "$EXECUTABLE" 2>/dev/null
    sleep 1
    if [ -d "$BACKUP" ]; then
        if [ -d "$INSTALLED" ]; then
            rm -rf "$INSTALLED"
        fi
        mv "$BACKUP" "$INSTALLED" || {
            echo "!! 旧包恢复失败，备份保留在：${BACKUP}"
            return 1
        }
    fi
    start_and_wait
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "$STOPPED" = 1 ] && [ "$SUCCESS" = 0 ]; then
        rollback || rc=$?
    fi
    if [ "$KEEP_TMP" = 0 ]; then
        rm -rf "$TMP"
    fi
    if [ -n "$WORK" ]; then
        if [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then
            echo "!! 更新备份保留在：${BACKUP}"
        else
            rm -rf "$WORK"
        fi
    fi
    exit "$rc"
}
trap on_exit EXIT

echo "==> 1/5 下载最新 Release（${ZIP_URL}）"
if ! curl -fsSL --max-time 180 -o "${TMP}/CodexUsage.zip" "$ZIP_URL"; then
    echo "!! 下载失败——打开 Releases 页面手动下载"
    open "https://github.com/${REPO}/releases"
    exit 1
fi

echo "==> 2/5 校验发布包"
# SHA256 校验：release.sh 随包上传 CodexUsage.zip.sha256，缺失或不匹配即中止
if ! curl -fsSL --max-time 60 -o "${TMP}/CodexUsage.zip.sha256" "${ZIP_URL}.sha256"; then
    echo "!! 校验文件下载失败（Release 缺少 SHA256 或网络异常），已中止"
    exit 1
fi
if ! (cd "$TMP" && shasum -a 256 -c CodexUsage.zip.sha256); then
    echo "!! 发布包 SHA256 校验失败，已中止"
    exit 1
fi
unzip -q -o "${TMP}/CodexUsage.zip" -d "$TMP"
NEW_APP="${TMP}/${APP_NAME}"
NEW_BINARY="${NEW_APP}/Contents/MacOS/${EXECUTABLE}"
if [ ! -x "$NEW_BINARY" ]; then
    echo "!! 发布包内容异常（缺可执行文件）"
    exit 1
fi
if ! NEW_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CUBuildVersion' "${NEW_APP}/Contents/Info.plist")"; then
    echo "!! 发布包缺少构建版本"
    exit 1
fi
codesign --verify --deep --strict "$NEW_APP"
"$NEW_BINARY" --self-test

# 定位已安装副本（~/Applications 优先，/Applications 兜底）
for cand in "$HOME/Applications/${APP_NAME}" "/Applications/${APP_NAME}"; do
    if [ -d "$cand" ]; then
        INSTALLED="$cand"
        break
    fi
done
if [ -z "$INSTALLED" ]; then
    echo "!! 未找到已安装的 ${APP_NAME}"
    echo "   已下载解压到：${TMP} —— 手动拖入 /Applications 即完成安装"
    KEEP_TMP=1
    open -R "$NEW_APP"
    exit 0
fi

if launchctl print "gui/${MYUID}/${LABEL}" >/dev/null 2>&1; then
    AGENT=1
    if [ ! -f "$AGENT_PLIST" ]; then
        echo "!! LaunchAgent 已加载但 plist 不存在：${AGENT_PLIST}"
        exit 1
    fi
fi

echo "==> 3/5 在安装位置旁暂存新版本"
WORK="$(mktemp -d "$(dirname "$INSTALLED")/.${APP_NAME}.update.XXXXXX")"
STAGE="${WORK}/new/${APP_NAME}"
BACKUP="${WORK}/old/${APP_NAME}"
mkdir -p "$(dirname "$STAGE")" "$(dirname "$BACKUP")"
cp -R "$NEW_APP" "$STAGE"
[ -x "${STAGE}/Contents/MacOS/${EXECUTABLE}" ]

echo "==> 4/5 停止 ${LABEL} 并切换版本"
STOPPED=1
if [ "$AGENT" = 1 ]; then
    launchctl bootout "gui/${MYUID}/${LABEL}"
fi
pkill -x "$EXECUTABLE" 2>/dev/null || true
sleep 1
if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
    echo "!! 旧进程仍未退出，取消换包"
    exit 1
fi
mv "$INSTALLED" "$BACKUP"
mv "$STAGE" "$INSTALLED"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CUBuildVersion' "${INSTALLED}/Contents/Info.plist")" != "$NEW_VERSION" ]; then
    echo "!! 安装后的版本校验失败"
    exit 1
fi

echo "==> 5/5 启动并检查新版本"
start_and_wait
rm -rf "$BACKUP"
BACKUP=""
rm -rf "$WORK"
WORK=""
SUCCESS=1
echo "✅ 更新完成：${INSTALLED}（版本 ${NEW_VERSION}）"
