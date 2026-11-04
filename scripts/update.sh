#!/bin/bash
# CodexUsage 就地更新：下载并验证 Release，暂存成功后换包；启动失败恢复旧版本。
set -euo pipefail

REPO="JUNX7764/Codexusage"
API_URL="https://api.github.com/repos/${REPO}/releases?per_page=20"
APP_NAME="CodexUsage.app"
EXECUTABLE="CodexUsage"
LABEL="com.local.codex-usage"
MYUID="$(id -u)"
AGENT_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

TMP=""
KEEP_TMP=0
WORK=""
BACKUP=""
INSTALLED=""
AGENT=0
STOPPED=0
SUCCESS=0
NEW_VERSION=""
[ "$#" -eq 2 ] || { echo "!! 需要目标版本和当前应用路径"; exit 1; }
TARGET_TAG="$1"
INSTALLED="$2"
[[ "$TARGET_TAG" =~ ^v?[0-9]+(\.[0-9]+)+$ ]] || { echo "!! 目标版本无效"; exit 1; }
[ -d "$INSTALLED" ] && [ "$(basename "$INSTALLED")" = "$APP_NAME" ] || { echo "!! 应用路径无效"; exit 1; }
INSTALLED="$(cd "$(dirname "$INSTALLED")" && pwd -P)/${APP_NAME}"
BINARY="${INSTALLED}/Contents/MacOS/${EXECUTABLE}"
[ -x "$BINARY" ] || { echo "!! 当前应用缺少可执行文件"; exit 1; }
TMP="$(mktemp -d)"

# 仅匹配实际可执行路径；遇到同名的其他副本时中止，绝不按名称杀进程。
processes() { ps -axo pid=,comm=; }
target_pids() {
    while read -r pid command; do
        case "$command" in "$BINARY") echo "$pid";; esac
    done < <(processes)
}
other_copy_running() {
    while read -r pid command; do
        case "$command" in
          "$BINARY") ;;
          *"/${EXECUTABLE}") return 0;;
        esac
    done < <(processes)
    return 1
}
stop_target() {
    local pid
    while read -r pid; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done < <(target_pids)
}
version_newer() {
    /usr/bin/osascript -l JavaScript - "$1" "$2" <<'JXA'
function run(a) {
  function parts(s) { let m = /^v?(\d+(?:\.\d+)+)(?:-.+)?$/.exec(s); return m ? m[1].split('.').map(Number) : null; }
  let n = parts(a[0]), o = parts(a[1]); if (!n || !o) return 'no';
  for (let i = 0; i < Math.max(n.length, o.length); i++) {
    let x = n[i] || 0, y = o[i] || 0; if (x !== y) return x > y ? 'yes' : 'no';
  }
  return 'no';
}
JXA
}

start_and_wait() {
    if [ "$AGENT" = 1 ]; then
        launchctl bootstrap "gui/${MYUID}" "$AGENT_PLIST"
    else
        open -n "$INSTALLED"
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [ -n "$(target_pids)" ]; then
            sleep 1
            if [ -n "$(target_pids)" ]; then
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
    stop_target
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

echo "==> 1/5 查找并下载最新可安装 Release"
# 不假设 releases/latest 一定带附件：人工建 Release 或上传中断时会留下空 Release。
# 用 macOS 自带 JXA 解析 GitHub JSON，跳过 draft/prerelease 及 ZIP/SHA256 不完整的条目。
if ! curl -fsSL --max-time 60 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: CodexUsage-Updater' \
    -o "${TMP}/releases.json" "$API_URL"; then
    echo "!! Release 信息获取失败，请检查网络后重试"
    exit 1
fi
if ! SELECTION="$(/usr/bin/osascript -l JavaScript - "${TMP}/releases.json" "$EXECUTABLE" "$TARGET_TAG" <<'JXA'
function run(argv) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    if (!text) { return ""; }
    const releases = JSON.parse(text.js);
    if (!Array.isArray(releases)) { return ""; }
    const zipName = argv[1] + ".zip";
    for (const release of releases) {
        if (release.tag_name !== argv[2] || release.draft || release.prerelease || !Array.isArray(release.assets)) { continue; }
        let zip = null;
        let checksum = null;
        for (const asset of release.assets) {
            if (asset.name === zipName) { zip = asset; }
            if (asset.name === zipName + ".sha256") { checksum = asset; }
        }
        if (zip && checksum && typeof release.tag_name === "string") {
            return [zip.browser_download_url, checksum.browser_download_url, release.tag_name].join("\t");
        }
    }
    return "";
}
JXA
)"; then
    echo "!! Release 信息解析失败，已中止"
    exit 1
fi
if [ -z "$SELECTION" ]; then
    echo "!! 没有找到 ZIP 和 SHA256 齐全的 Release，已中止"
    exit 1
fi
IFS=$'\t' read -r ZIP_URL SHA256_URL RELEASE_TAG <<< "$SELECTION"
case "$ZIP_URL" in
    "https://github.com/${REPO}/releases/download/${TARGET_TAG}/${EXECUTABLE}.zip") ;;
    *) echo "!! Release 返回了非预期的 ZIP 地址，已中止"; exit 1 ;;
esac
case "$SHA256_URL" in
    "https://github.com/${REPO}/releases/download/${TARGET_TAG}/${EXECUTABLE}.zip.sha256") ;;
    *) echo "!! Release 返回了非预期的 SHA256 地址，已中止"; exit 1 ;;
esac
echo "==> 下载 ${RELEASE_TAG}（${ZIP_URL}）"
DOWNLOAD_PROGRESS=--silent
if [ -n "${UPDATE_PROGRESS_FILE:-}" ]; then
    DOWNLOAD_PROGRESS=--progress-bar
fi
if ! curl -fL "$DOWNLOAD_PROGRESS" --max-time 180 -o "${TMP}/CodexUsage.zip" "$ZIP_URL" 2>"${UPDATE_PROGRESS_FILE:-/dev/null}"; then
    echo "!! 发布包下载失败，请稍后重试"
    exit 1
fi

echo "==> 2/5 校验发布包"
# SHA256 校验：release.sh 随包上传 CodexUsage.zip.sha256，缺失或不匹配即中止
if ! curl -fsSL --max-time 60 -o "${TMP}/CodexUsage.zip.sha256" "$SHA256_URL"; then
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
[ "$NEW_VERSION" = "$TARGET_TAG" ] || { echo "!! 发布包构建版本与目标不符"; exit 1; }
for bundle in "$NEW_APP" "$INSTALLED"; do
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" || { echo "!! 应用缺少身份标识"; exit 1; }
    [ "$BUNDLE_ID" = "$LABEL" ] || { echo "!! 应用身份标识不符"; exit 1; }
done
OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CUBuildVersion' "${INSTALLED}/Contents/Info.plist")" || { echo "!! 当前应用缺少构建版本"; exit 1; }
[ "$(version_newer "$NEW_VERSION" "$OLD_VERSION")" = yes ] || { echo "!! 目标版本必须高于当前应用"; exit 1; }
codesign --verify --deep --strict "$NEW_APP"
"$NEW_BINARY" --self-test

if other_copy_running; then
    echo "!! 检测到另一应用副本正在运行，已中止"
    exit 1
fi
if JOB_INFO="$(launchctl print "gui/${MYUID}/${LABEL}" 2>/dev/null)"; then
    LOADED_BINARY="$(printf '%s\n' "$JOB_INFO" | awk '/^[[:space:]]*program = / { sub(/^[[:space:]]*program = /, ""); print; exit }')"
    [ "$LOADED_BINARY" = "$BINARY" ] || { echo "!! 已加载的 LaunchAgent 指向另一副本或无法确认，已中止"; exit 1; }
    [ -f "$AGENT_PLIST" ] || { echo "!! LaunchAgent plist 不存在"; exit 1; }
    AGENT_BINARY="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT_PLIST" 2>/dev/null || true)"
    [ "$AGENT_BINARY" = "$BINARY" ] || { echo "!! LaunchAgent 指向另一副本，已中止"; exit 1; }
    AGENT=1
fi

echo "==> 3/5 在安装位置旁暂存新版本"
WORK="$(mktemp -d "$(dirname "$INSTALLED")/.${APP_NAME}.update.XXXXXX")"
STAGE="${WORK}/new/${APP_NAME}"
BACKUP="${WORK}/old/${APP_NAME}"
mkdir -p "$(dirname "$STAGE")" "$(dirname "$BACKUP")"
cp -R "$NEW_APP" "$STAGE"
[ -x "${STAGE}/Contents/MacOS/${EXECUTABLE}" ]

echo "==> 4/5 停止 ${LABEL} 并切换版本"
if [ "$AGENT" = 1 ]; then
    launchctl bootout "gui/${MYUID}/${LABEL}"
fi
STOPPED=1
stop_target
sleep 1
if [ -n "$(target_pids)" ]; then
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
