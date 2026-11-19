#!/bin/bash
# Redmi Pad Pro Root 一键构建脚本
set -e
cd "$(dirname "$0")"

# 1. 定位 NDK（自动探测常见安装位置；也可用 ANDROID_NDK_HOME / ANDROID_NDK_ROOT 显式指定）
if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_NDK_ROOT" ]; then
    for c in "$ANDROID_SDK_ROOT/ndk" "$ANDROID_HOME/ndk" \
             "$HOME/Android/Sdk/ndk" "$HOME/android-sdk/ndk" "$HOME/Library/Android/sdk/ndk" \
             /opt/android-sdk/ndk /usr/lib/android-sdk/ndk /usr/lib/android-ndk \
             /opt/homebrew/share/android-commandlinetools/ndk; do
        # 跳过未设置的环境变量拼出来的 "/ndk"
        if [ -n "${c//\/ndk}" ] && [ -d "$c" ]; then
            ANDROID_NDK_HOME="$c/$(ls -1 "$c" | sort -V | tail -1)"
            break
        fi
    done
fi
# 只设了 ANDROID_NDK_ROOT 的用户同样可用
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_NDK_ROOT}"
if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "[!] 找不到 Android NDK。请安装 NDK，或显式指定位置："
    echo "        ANDROID_NDK_HOME=/path/to/android-ndk-rXX ./build.sh"
    echo "    Linux: 从 https://developer.android.com/ndk/downloads 下载并解压到任意目录；"
    echo "           Android Studio 用户默认位于 ~/Android/Sdk/ndk（可自动探测）"
    echo "    macOS: brew install --cask android-commandlinetools 后装 NDK，"
    echo "           或直接 https://developer.android.com/ndk/downloads"
    exit 1
fi
if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm" ]; then
    echo "[!] $ANDROID_NDK_HOME 不像 NDK 根目录（缺少 toolchains/llvm），请检查 ANDROID_NDK_HOME"
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
