#!/bin/bash
# Redmi Pad Pro Root 一键构建脚本。
# Linux 空机可直接运行：自动探测/下载 NDK 与 platform-tools，
# make 缺失时使用 NDK 自带的，无需手动安装任何组件。
set -e
cd "$(dirname "$0")"

NDK_VERSION=r28b   # = 28.1.13356706，与本仓库真机验证过的构建一致
NDK_ZIP_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
PT_ZIP_URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"

fetch() { # fetch <url> <输出文件>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$2" "$1"
    else
        echo "[!] 需要 curl 或 wget 下载组件（如 sudo apt install curl）"
        return 1
    fi
}

extract_zip() { # extract_zip <zip> <目标目录>
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$1" -d "$2"
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$1" -C "$2"
    elif command -v python3 >/dev/null 2>&1; then
        # python 的 zipfile 不保留可执行位，解压后统一补上
        python3 -m zipfile -e "$1" "$2"
        find "$2" -type d -exec chmod 755 {} +
        find "$2" -type f -exec chmod 755 {} +
    else
        echo "[!] 需要 unzip / bsdtar / python3 之一解压（如 sudo apt install unzip）"
        return 1
    fi
}

# ---------- 1. 定位 / 下载 NDK ----------
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

if { [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; } && [ "$(uname -s)" = "Linux" ]; then
    # 一键模式：自动下载官方 NDK（约 700 MB，仅首次；解压后约 3 GB，装入 .ndk/）
    if [ -d ".ndk/android-ndk-${NDK_VERSION}" ]; then
        ANDROID_NDK_HOME=".ndk/android-ndk-${NDK_VERSION}"
    else
        echo "[*] 未找到 NDK，开始自动下载 ${NDK_VERSION}（约 700 MB，仅首次运行需要）"
        avail=$(df -Pk . | awk 'NR==2{print $4}')
        if [ "${avail:-0}" -lt 3200000 ]; then
            echo "[!] 磁盘剩余空间不足 3 GB，无法自动安装 NDK；请手动指定 ANDROID_NDK_HOME"
            exit 1
        fi
        mkdir -p .ndk
        fetch "$NDK_ZIP_URL" ".ndk/ndk.zip"
        extract_zip ".ndk/ndk.zip" .ndk
        rm -f .ndk/ndk.zip
        echo "[+] NDK ${NDK_VERSION} 安装完成: .ndk/android-ndk-${NDK_VERSION}"
        ANDROID_NDK_HOME=".ndk/android-ndk-${NDK_VERSION}"
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "[!] 找不到 Android NDK。请安装 NDK，或显式指定位置："
    echo "        ANDROID_NDK_HOME=/path/to/android-ndk-rXX ./build.sh"
    echo "    Linux: 重跑 ./build.sh 可自动下载；或从 https://developer.android.com/ndk/downloads 手动安装"
    echo "    macOS: brew install --cask android-commandlinetools 后装 NDK，"
    echo "           或直接 https://developer.android.com/ndk/downloads"
    exit 1
fi
if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm" ]; then
    echo "[!] $ANDROID_NDK_HOME 不像 NDK 根目录（缺少 toolchains/llvm），请检查 ANDROID_NDK_HOME"
    exit 1
fi
# 相对路径转绝对路径，避免 make 子进程解析歧义
case "$ANDROID_NDK_HOME" in
    /*) ;;
    *) ANDROID_NDK_HOME="$(cd "$ANDROID_NDK_HOME" && pwd)" ;;
esac
echo "[*] NDK: $ANDROID_NDK_HOME"
export ANDROID_NDK_HOME

# ---------- 2. make（系统没有时用 NDK 自带的） ----------
if ! command -v make >/dev/null 2>&1; then
    case "$(uname -s)" in
        Darwin) NDK_PREBUILT=darwin-x86_64 ;;
        *)      NDK_PREBUILT=linux-x86_64 ;;
    esac
    if [ -x "$ANDROID_NDK_HOME/prebuilt/$NDK_PREBUILT/bin/make" ]; then
        export PATH="$ANDROID_NDK_HOME/prebuilt/$NDK_PREBUILT/bin:$PATH"
        echo "[*] 系统未安装 make，使用 NDK 自带: prebuilt/$NDK_PREBUILT/bin/make"
    else
        echo "[!] 需要 make（如 sudo apt install make），且该 NDK 未自带"
        exit 1
    fi
fi

# ---------- 3. 构建 ----------
make -C src ghostlock
BIN=build/native/ghostlock
if [ ! -f "$BIN" ]; then
    echo "[!] 构建失败"
    exit 1
fi
echo "[+] 构建成功: $BIN"

# ---------- 4. adb（tools/reroot.sh 需要；没有则自动下载 platform-tools） ----------
if [ -z "$(command -v adb || true)" ] && [ ! -x ".tools/platform-tools/adb" ] && [ "$(uname -s)" = "Linux" ]; then
    echo "[*] 未检测到 adb，自动下载 platform-tools 到 .tools/（约 10 MB）"
    mkdir -p .tools
    fetch "$PT_ZIP_URL" ".tools/pt.zip"
    extract_zip ".tools/pt.zip" .tools
    rm -f .tools/pt.zip
fi
if command -v adb >/dev/null 2>&1; then
    echo "[*] adb: $(command -v adb)"
elif [ -x ".tools/platform-tools/adb" ]; then
    echo "[*] adb: .tools/platform-tools/adb（tools/reroot.sh 会自动使用）"
else
    echo "[!] 未找到 adb：reroot 前请安装 platform-tools（Linux 重跑 ./build.sh 可自动下载）"
fi
echo "[*] 下一步: 平板开 USB 调试连上电脑，运行 tools/reroot.sh"
