#!/bin/bash
# Redmi Pad Pro Root 一键构建脚本
set -e
cd "$(dirname "$0")"

# 1. 定位 NDK
if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_NDK_ROOT" ]; then
    for c in "$HOME/Library/Android/sdk/ndk" "$HOME/Android/Sdk/ndk" /opt/homebrew/share/android-commandlinetools/ndk; do
        if [ -d "$c" ]; then
            ANDROID_NDK_HOME="$c/$(ls -1 "$c" | sort -V | tail -1)"
            break
        fi
    done
fi
if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "[!] 找不到 Android NDK。请安装 NDK 或设置 ANDROID_NDK_HOME"
    echo "    macOS: brew install --cask android-commandlinetools 后装 NDK，"
    echo "    或直接 https://developer.android.com/ndk/downloads"
    exit 1
fi
echo "[*] NDK: $ANDROID_NDK_HOME"
export ANDROID_NDK_HOME

# 2. 构建
make -C src ghostlock
BIN=build/native/ghostlock
if [ -f "$BIN" ]; then
    echo "[+] 构建成功: $BIN"
    echo "[*] 下一步: 平板开 USB 调试连上电脑，运行 tools/reroot.sh"
else
    echo "[!] 构建失败"
    exit 1
fi
