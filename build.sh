#!/bin/bash
# 编译并打包 CodexUsage 菜单栏小工具
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/CodexUsage.app"

echo "== 编译 Swift 源码 =="
# 必须显式指定部署目标：本机 CLT 默认 target 是 macosx28.0（比当前系统 macOS 27 新），
# 缺省编译出的二进制 minos=28.0 会被 LaunchServices 拒绝（"不能与此版本 macOS 配合使用"）。
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/CodexUsage-bin" "$DIR/CodexUsage.swift"

echo "== 打包 .app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
mv "$DIR/CodexUsage-bin" "$APP/Contents/MacOS/CodexUsage"
chmod +x "$APP/Contents/MacOS/CodexUsage"

echo "== ad-hoc 签名 =="
codesign --force --sign - "$APP" 2>/dev/null || true

echo "== 完成: $APP =="
