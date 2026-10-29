#!/bin/bash
# 编译并打包 CodexUsage 菜单栏小工具
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/CodexUsage.app"

# 版本注入：tag 即版本（git describe），无 tag 退化短 hash，未提交改动追加 -dirty。
# 打包时写进产物 Info.plist 自定义键（CU*），app 运行时读 Bundle——不能生成第二个 .swift：
# 多文件编译下只有 main.swift 允许 top-level 代码，CodexUsage.swift 的命令行入口依赖 top-level
VERSION_DESCRIBE="$(git -C "$DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
COMMIT="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "== 版本 ${VERSION_DESCRIBE}（commit ${COMMIT}）=="

# 图标：缺失时用脚本生成（macOS 13+ 自带 swift / iconutil）
if [ ! -f "$DIR/AppIcon.icns" ]; then
    echo "== 生成图标 =="
    (cd "$DIR" && swift scripts/icon_gen.swift)
fi

echo "== 编译 Swift 源码 =="
# 必须显式指定部署目标：本机 CLT 默认 target 是 macosx28.0（比当前系统 macOS 27 新），
# 缺省编译出的二进制 minos=28.0 会被 LaunchServices 拒绝（"不能与此版本 macOS 配合使用"）。
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/CodexUsage-bin" "$DIR/CodexUsage.swift"

echo "== 打包 .app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mv "$DIR/CodexUsage-bin" "$APP/Contents/MacOS/CodexUsage"
chmod +x "$APP/Contents/MacOS/CodexUsage"

# 产物版本号取 describe 的数字前缀（v1.0.0 / v1.0.0-3-gx → 1.0.0）；无 tag 时 0.0.0
PLIST_VERSION="0.0.0"
case "$VERSION_DESCRIBE" in
    v[0-9]*)
        PLIST_VERSION="${VERSION_DESCRIBE#v}"
        PLIST_VERSION="${PLIST_VERSION%%-*}"
        ;;
esac
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PLIST_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PLIST_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CUBuildVersion string ${VERSION_DESCRIBE}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CUBuildCommit string ${COMMIT}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CUBuildSourceDir string ${DIR}" "$APP/Contents/Info.plist"

echo "== ad-hoc 签名 =="
codesign --force --sign - "$APP" 2>/dev/null || true

echo "== 完成: ${APP}（版本 ${VERSION_DESCRIBE}）=="
