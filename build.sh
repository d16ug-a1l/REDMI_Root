#!/bin/bash
# Redmi Pad Pro Root 一键构建脚本。
# Linux 空机可直接运行：自动探测/下载 NDK 与 platform-tools，
# make 缺失时使用 NDK 自带的，无需手动安装任何组件。
set -e
cd "$(dirname "$0")"

NDK_VERSION=r28b   # = 28.1.13356706，与本仓库真机验证过的构建一致
NDK_DIR=".ndk/android-ndk-${NDK_VERSION}"
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
PT_ZIP="platform-tools-latest-linux.zip"
# 下载源自动测速选择（国内网络下腾讯镜像通常远快于官方源）。
# 可用 REDMI_ROOT_MIRROR=<基址> 强制指定，例如：
#   REDMI_ROOT_MIRROR=https://mirrors.cloud.tencent.com/AndroidSDK ./build.sh
MIRROR_RANKED=()   # 按 "名称|基址" 依速度降序存放，首次下载时填充

# ---- 组件函数 ----

fetch() { # fetch <url> <输出文件> —— 带进度条的下载
    local url="$1" out="$2" total="" pid size mb tmb pct filled i bar spin n
    local BAR_W=28
    spin='-\|/'
    n=0
    # 预取 Content-Length 用于百分比（拿不到则退化为转圈+已下载量）
    if command -v curl >/dev/null 2>&1; then
        total=$(curl -sIL "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    elif command -v wget >/dev/null 2>&1; then
        total=$(wget -q --spider --server-response "$url" 2>&1 | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$url" &
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$out" "$url" &
    else
        echo "[!] 需要 curl 或 wget 下载组件（如 sudo apt install curl）"
        return 1
    fi
    pid=$!
    # 进度条：终端里单行刷新；管道/日志里每 5 秒一行
    while kill -0 "$pid" 2>/dev/null; do
        if [ -f "$out" ]; then size=$(wc -c < "$out"); else size=0; fi
        size=$((size + 0))
        if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
            mb=$((size / 1048576)); tmb=$((total / 1048576)); pct=$((size * 100 / total))
            filled=$((pct * BAR_W / 100))
            bar=""
            for ((i = 0; i < BAR_W; i++)); do
                if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
            done
            if [ -t 2 ]; then
                printf '\r    下载中 [%s] %3d%% (%d/%d MB)   ' "$bar" "$pct" "$mb" "$tmb" >&2
            else
                echo "    下载中 [$bar] $pct% ($mb/$tmb MB)"
            fi
        else
            mb=$((size / 1048576))
            if [ -t 2 ]; then
                printf '\r    下载中 %s %3d MB   ' "${spin:n % 4:1}" "$mb" >&2
            else
                echo "    下载中 $mb MB"
            fi
        fi
        n=$((n + 1))
        sleep 5
    done
    if wait "$pid"; then
        # 终帧：补满 100%，避免进度条停在 9x%
        if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
            mb=$((total / 1048576))
            bar=""
            for ((i = 0; i < BAR_W; i++)); do bar+="█"; done
            printf '\r    下载中 [%s] 100%% (%d/%d MB)   \n' "$bar" "$mb" "$mb" >&2
        fi
        return 0
    fi
    return 1
}

resolve_mirror() { # resolve_mirror <zip 文件名> —— 各源采样 1MB 实测下载速度并排序
    local file="$1" name base speed line probe
    local avail=()
    if [ -n "$REDMI_ROOT_MIRROR" ]; then
        set -- "手动指定|$REDMI_ROOT_MIRROR"
    else
        set -- "官方|https://dl.google.com/android/repository" \
               "腾讯镜像|https://mirrors.cloud.tencent.com/AndroidSDK"
    fi
    echo "[*] 下载源测速（每源采样 1 MB，最长 10 秒）："
    for line in "$@"; do
        name="${line%%|*}"; base="${line#*|}"
        # 注意：--max-time 超时退出时 curl 仍会输出实测速度（慢速源按平均速度参与排序），
        # 只有完全连不上 / 404 时 speed_download 才为 0。
        probe=$(curl -fsSL -r 0-1048575 --max-time 10 --max-filesize 3145728 \
                    -o /dev/null -w '%{speed_download}' "$base/$file" 2>/dev/null) || true
        speed=$(awk -v s="${probe:-0}" 'BEGIN{printf "%d", s + 0.5}')
        if [ "$speed" -gt 0 ]; then
            awk "BEGIN{printf \"    %s: %.1f MB/s\n\", \"$name\", $speed/1048576}"
            avail+=("$speed|$name|$base")
        else
            echo "    $name: 不可用"
        fi
    done
    if [ "${#avail[@]}" -eq 0 ]; then
        echo "[!] 所有下载源均不可用：检查网络，或设 REDMI_ROOT_MIRROR=<基址> 手动指定"
        return 1
    fi
    MIRROR_RANKED=()
    while IFS='|' read -r _ name base; do
        MIRROR_RANKED+=("$name|$base")
    done < <(printf '%s\n' "${avail[@]}" | sort -t'|' -k1,1rn)
    echo "[*] 使用最快源: ${MIRROR_RANKED[0]%%|*}"
}

fetch_component() { # fetch_component <zip 文件名> <本地输出路径> —— 测速选源后下载，失败自动换源
    local zip="$1" out="$2" c
    if [ "${#MIRROR_RANKED[@]}" -eq 0 ]; then
        resolve_mirror "$zip" || return 1
    fi
    for c in "${MIRROR_RANKED[@]}"; do
        if fetch "${c#*|}/$zip" "$out"; then
            return 0
        fi
        echo "[!] 从 ${c%%|*} 下载失败，尝试下一个源"
    done
    MIRROR_RANKED=()   # 全部失败：下次下载重新测速
    return 1
}

extract_zip() { # extract_zip <zip> <目标目录>
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$1" -d "$2"
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$1" -C "$2"
    elif command -v python3 >/dev/null 2>&1; then
        # python 的 zipfile -e 不支持符号链接与权限位（NDK 的 clang++ 等
        # 全是符号链接，解丢后工具链直接报废），这里手动还原。
        python3 - "$1" "$2" <<'PYEOF'
import os, sys, stat, zipfile
zf = zipfile.ZipFile(sys.argv[1])
dest = sys.argv[2]
for info in zf.infolist():
    path = os.path.join(dest, *info.filename.split('/'))
    mode = info.external_attr >> 16
    if stat.S_ISLNK(mode):
        target = zf.read(info).decode()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.lexists(path):
            os.remove(path)
        os.symlink(target, path)
    elif info.is_dir():
        os.makedirs(path, exist_ok=True)
    else:
        zf.extract(info, dest)
        perm = mode & 0o777
        if perm:
            os.chmod(path, perm)
PYEOF
    else
        echo "[!] 需要 unzip / bsdtar / python3 之一解压（如 sudo apt install unzip）"
        return 1
    fi
}

_detect_ndk() { # 探测环境变量与常见安装位置 → ANDROID_NDK_HOME（可为空）
    local env_home="${ANDROID_NDK_HOME:-}" env_root="${ANDROID_NDK_ROOT:-}" c
    ANDROID_NDK_HOME=""
    if [ -n "$env_home" ]; then
        ANDROID_NDK_HOME="$env_home"
    elif [ -n "$env_root" ]; then
        ANDROID_NDK_HOME="$env_root"
    else
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
}

_download_ndk() { # Linux 且本机没有 → 自动下载解压到 .ndk/
    [ "$(uname -s)" = "Linux" ] || return 1
    if [ -d "$NDK_DIR" ]; then
        ANDROID_NDK_HOME="$NDK_DIR"
        return 0
    fi
    echo "[*] 未找到 NDK，开始自动下载 ${NDK_VERSION}（约 700 MB，仅首次运行需要）"
    local avail
    avail=$(df -Pk . | awk 'NR==2{print $4}')
    if [ "${avail:-0}" -lt 3200000 ]; then
        echo "[!] 磁盘剩余空间不足 3 GB，无法自动安装 NDK；请手动指定 ANDROID_NDK_HOME"
        exit 1
    fi
    mkdir -p .ndk
    fetch_component "$NDK_ZIP" ".ndk/ndk.zip"
    extract_zip ".ndk/ndk.zip" .ndk
    rm -f .ndk/ndk.zip
    echo "[+] NDK ${NDK_VERSION} 安装完成: $NDK_DIR"
    ANDROID_NDK_HOME="$NDK_DIR"
}

_validate_ndk() { # 目录 / 工具链 / 符号链接完整性校验
    local cxx
    if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
        echo "[!] 找不到 Android NDK。请安装 NDK，或显式指定位置："
        echo "        ANDROID_NDK_HOME=/path/to/android-ndk-rXX ./build.sh"
        echo "    Linux: 重跑 ./build.sh 可自动下载；或从 https://developer.android.com/ndk/downloads 手动安装"
        echo "    macOS: brew install --cask android-commandlinetools 后装 NDK，"
        echo "           或直接 https://developer.android.com/ndk/downloads"
        return 1
    fi
    if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm" ]; then
        echo "[!] $ANDROID_NDK_HOME 不像 NDK 根目录（缺少 toolchains/llvm），请检查 ANDROID_NDK_HOME"
        return 1
    fi
    if [ "$(uname -s)" = "Linux" ]; then
        cxx="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
        # 损坏特征：本应是指向 clang 的符号链接，却成了内容为 "clang" 的文本文件
        #（python zipfile 解压丢失符号链接的典型后果）
        if [ -f "$cxx" ] && [ ! -L "$cxx" ] && ! head -c 4 "$cxx" 2>/dev/null | LC_ALL=C grep -q ELF; then
            echo "[!] 工具链损坏：$cxx 不是 ELF 也不是符号链接"
            return 1
        fi
    fi
    return 0
}

ensure_ndk() { # 定位/下载/校验 NDK；自动安装的若损坏则删除重装一次
    local i
    for i in 1 2; do
        _detect_ndk
        if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
            _download_ndk || true
        fi
        if _validate_ndk; then
            # 相对路径转绝对路径，避免 make 子进程解析歧义
            case "$ANDROID_NDK_HOME" in
                /*) ;;
                *) ANDROID_NDK_HOME="$(cd "$ANDROID_NDK_HOME" && pwd)" ;;
            esac
            echo "[*] NDK: $ANDROID_NDK_HOME"
            export ANDROID_NDK_HOME
            return 0
        fi
        # 校验失败：自动安装的删除重试一次；用户手动指定的直接报错退出
        # （此时可能是相对路径 .ndk/…，也可能已绝对化，两种都匹配）
        case "$ANDROID_NDK_HOME" in
            .ndk|.ndk/*|"$PWD"/.ndk|"$PWD"/.ndk/*)
                echo "[*] 删除损坏的 $ANDROID_NDK_HOME 并重新下载"
                rm -rf "$ANDROID_NDK_HOME"
                ANDROID_NDK_HOME=""
                ;;
            *)
                echo "[!] 请修复该 NDK 或重新指定 ANDROID_NDK_HOME 后重试"
                return 1
                ;;
        esac
    done
    return 1
}

# ---- 主流程 ----

# ---------- 1. 定位 / 下载 / 校验 NDK ----------
ensure_ndk || exit 1

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
    fetch_component "$PT_ZIP" ".tools/pt.zip"
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
