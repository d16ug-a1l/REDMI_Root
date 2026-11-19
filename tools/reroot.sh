#!/bin/bash
# dizi 一键重 root：平板 USB 连接电脑后运行本脚本即可。
# 自动完成：W1 (SELinux permissive) → W2 (cred root) → KernelSU 模块重载。
# 之前的模块和授权配置会自动恢复。
# 过程中平板可能重启若干次（属正常，USB 会自动重连），看到 ROOTED 即成。
cd "$(dirname "$0")/.." || exit 1

BIN=build/native/ghostlock
PROFILE=""   # 首次连上设备后按 uname -r 自动选择（profiles/<内核版本>.bin）

# adb 解析优先级：
#   1. REDMI_ROOT_ADB=<路径> 手动指定
#   2. WSL 环境下自动使用 Windows 侧 adb.exe（USB 设备只归 Windows adb 管）
#   3. 系统 PATH 里的 adb
#   4. ./build.sh 自动下载到 .tools/ 的 adb
# 网络 adb（WSL/无 USB 场景可选）：REDMI_ROOT_ADB_IP=<平板IP>[:5555]
ADB=""

wsl_adb() { # adb.exe 包装：本地文件参数转 UNC 路径，剥离 CR
    local a args=() distro="${WSL_DISTRO_NAME:-Ubuntu}"
    for a in "$@"; do
        case "$a" in
            /*)  [ -e "$a" ] && a="\\\\wsl.localhost\\$distro$a" ;;
            ./*) [ -e "$a" ] && a="\\\\wsl.localhost\\$distro$PWD/${a#./}" ;;
        esac
        args+=("$a")
    done
    "$ADB_EXE" "${args[@]}" 2>&1 | tr -d '\r'
}

to_wsl_path() { # 支持 C:\x\adb.exe / C:/x/adb.exe / /mnt/... / ~/... → WSL 路径
    local p="$1" drive rest
    case "$p" in
        '~'*) p="$HOME${p#\~}" ;;
    esac
    case "$p" in
        [A-Za-z]:\\*|[A-Za-z]:/*)
            if command -v wslpath >/dev/null 2>&1; then
                wslpath -u "$p"
            else
                drive="$(printf '%s' "${p:0:1}" | tr 'A-Z' 'a-z')"
                rest="${p:2}"
                printf '/mnt/%s%s' "$drive" "$(printf '%s' "$rest" | tr '\\' '/')"
            fi
            ;;
        *)  printf '%s' "$p" ;;
    esac
}

prompt_windows_adb() { # WSL 下自动探测失败时：询问路径，或引导加入 Windows PATH
    local ans path tries=0
    # 非交互（管道/CI）不询问，避免卡死
    [ -t 0 ] || { echo "[*] 非交互环境，跳过询问"; return 1; }
    echo "[?] 未在常见位置找到 Windows 的 adb.exe，两种方式任选："
    echo "    1. 直接输入 adb.exe 的路径（Windows 风格 C:\\...\\adb.exe 或 WSL 风格 /mnt/c/... 均可）"
    echo "    2. 或把 adb 所在目录加入 Windows 系统 PATH："
    echo "       Win+R 输入 sysdm.cpl → 高级 → 环境变量 → Path → 编辑 → 新建 →"
    echo "       填入 platform-tools 目录 → 确定后【新开】本终端重新运行本脚本"
    while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        printf "    adb.exe 路径（直接回车跳过）: "
        read -r ans
        [ -z "$ans" ] && return 1
        path=$(to_wsl_path "$ans")
        if [ -n "$path" ] && [ -x "$path" ]; then
            mkdir -p .tools && printf '%s\n' "$path" > .tools/win-adb-path
            echo "[*] 已记住该路径（.tools/win-adb-path，删除该文件可重新询问）"
            ADB_EXE="$path"
            ADB=wsl_adb
            return 0
        fi
        echo "    [!] $path 不存在或不可执行，请重试"
    done
    return 1
}

resolve_adb() {
    local c saved
    if [ -n "$REDMI_ROOT_ADB" ]; then
        ADB="$REDMI_ROOT_ADB"
        echo "[*] adb(手动指定): $ADB"
        return 0
    fi
    if grep -qi microsoft /proc/version 2>/dev/null; then
        for c in /mnt/c/platform-tools/adb.exe \
                 /mnt/c/Android/platform-tools/adb.exe \
                 /mnt/c/Users/*/AppData/Local/Android/Sdk/platform-tools/adb.exe \
                 /mnt/c/Users/*/scoop/shims/adb.exe \
                 /mnt/c/ProgramData/chocolatey/bin/adb.exe; do
            if [ -x "$c" ]; then
                ADB_EXE="$c"
                ADB=wsl_adb
                echo "[*] adb(WSL→Windows): $c"
                return 0
            fi
        done
        # 上次询问时记住的路径
        if [ -s .tools/win-adb-path ]; then
            saved="$(head -n1 .tools/win-adb-path)"
            if [ -x "$saved" ]; then
                ADB_EXE="$saved"
                ADB=wsl_adb
                echo "[*] adb(WSL→Windows,已记住): $saved"
                return 0
            fi
        fi
        # adb.exe 在 Windows PATH 里（WSL interop 会把它带进 Linux PATH）
        if command -v adb.exe >/dev/null 2>&1; then
            ADB_EXE="$(command -v adb.exe)"
            ADB=wsl_adb
            echo "[*] adb(WSL→Windows PATH): $ADB_EXE"
            return 0
        fi
        # 交互询问：输入路径或引导加入 Windows PATH
        if prompt_windows_adb; then
            echo "[*] adb(WSL→Windows,手动): $ADB_EXE"
            return 0
        fi
        echo "[*] 跳过 Windows adb，回退 Linux adb（WSL 下 USB 设备不可见，仅适合网络 adb）"
    fi
    if command -v adb >/dev/null 2>&1; then
        ADB="$(command -v adb)"
        echo "[*] adb: $ADB"
        return 0
    fi
    if [ -x ".tools/platform-tools/adb" ]; then
        ADB=".tools/platform-tools/adb"
        echo "[*] adb: .tools/platform-tools/adb"
        return 0
    fi
    echo "[!] 找不到 adb：安装 platform-tools、先运行 ./build.sh，或设 REDMI_ROOT_ADB=<adb路径>"
    return 1
}
resolve_adb || exit 1

# 按设备内核版本选择 profile：profile 与内核构建逐字节绑定（符号偏移/结构体
# 尺寸随构建变化），版本不匹配会导致写入错位甚至 panic。
select_profile() {
    local rel
    rel=$("$ADB" shell uname -r 2>/dev/null | tr -d '\r')
    if [ -z "$rel" ]; then
        echo "[*] 暂时读不到内核版本（adb 抖动），稍后重试"
        return 2
    fi
    if [ -f "profiles/$rel.bin" ]; then
        PROFILE="profiles/$rel.bin"
        echo "[*] 内核 $rel → $PROFILE"
        return 0
    fi
    echo "[!] 暂不支持内核 $rel（缺少 profiles/$rel.bin）。已支持的 profile："
    ls profiles/*.bin 2>/dev/null | sed 's/^/    /'
    # 多设备时 adb 可能连到别的机器 —— 提示用 ANDROID_SERIAL 指定平板
    if [ "$("$ADB" devices 2>/dev/null | awk 'NR>1 && NF>=2 && $2=="device"' | wc -l)" -gt 1 ]; then
        echo "[!] 检测到多台设备，当前连到的不受支持。已连接设备："
        "$ADB" devices -l 2>/dev/null | awk 'NR>1 && NF>=5 {print "    "$1"  "$NF}'
        echo "    用 ANDROID_SERIAL=<平板序列号> $0 指定目标"
    fi
    return 1
}

wait_device() {
    local serial state line="" last="" n=0 booted=0
    while true; do
        # 网络 adb：重启后 adbd 需要重连，每轮自动 connect
        if [ -n "$REDMI_ROOT_ADB_IP" ]; then
            "$ADB" connect "$REDMI_ROOT_ADB_IP" >/dev/null 2>&1
        fi
        # 只清理 offline 会话（connected 状态的网络 adb 不能断，否则被自己踢掉）
        while read -r serial state; do
            [ "$state" = "offline" ] && "$ADB" disconnect "$serial" >/dev/null 2>&1
        done < <("$ADB" devices 2>/dev/null | awk 'NR>1 && NF>=2 {print $1, $2}')
        state="$("$ADB" devices 2>/dev/null | awk 'NR>1 && NF>=2 {print $2; exit}')"
        case "$state" in
            device)
                if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
                    booted=$((booted + 1))
                    # 连续两次确认（与验证流程一致），防止对半开机的系统发射 exploit
                    [ "$booted" -ge 2 ] && return 0
                    line="开机已完成，二次确认中…"
                else
                    booted=0
                    line="设备已连接，等待开机完成…"
                fi
                ;;
            unauthorized)
                line="平板已连接但未授权：请在平板上的 USB 调试指纹弹窗点允许"
                ;;
            offline|recovery|sideload)
                line="设备状态: $state，等待恢复…"
                ;;
            *)
                line="未检测到 adb 设备：请用 USB 连接平板并开启 USB 调试"
                if grep -qi microsoft /proc/version 2>/dev/null && [ $((n % 12)) -eq 0 ]; then
                    line="$line
    （检测到 WSL 环境）USB 设备默认归 Windows 侧，三种解决方案：
      a. 在 Windows 侧安装 platform-tools（本脚本会自动改用其 adb.exe）
      b. 网络 adb：平板连同一 Wi-Fi 后 REDMI_ROOT_ADB_IP=<平板IP> $0
      c. usbipd-win 把 USB 直通进 WSL"
                fi
                ;;
        esac
        if [ "$line" != "$last" ]; then
            echo "[*] $line"
            last="$line"
        fi
        n=$((n + 1))
        sleep 5
    done
}

push_all() { # 部署 + md5 校验：adb push 可能静默失败（adb 半死时跑的是设备上旧文件）
    local l1 l2 r1 r2
    "$ADB" push "$BIN" /data/local/tmp/ghostlock >/dev/null 2>&1
    "$ADB" push "$PROFILE" /data/local/tmp/profile.bin >/dev/null 2>&1
    "$ADB" shell chmod 755 /data/local/tmp/ghostlock 2>/dev/null
    l1=$(md5sum "$BIN" 2>/dev/null | cut -d' ' -f1)
    l2=$(md5sum "$PROFILE" 2>/dev/null | cut -d' ' -f1)
    r1=$("$ADB" shell md5sum /data/local/tmp/ghostlock 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    r2=$("$ADB" shell md5sum /data/local/tmp/profile.bin 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    [ -n "$r1" ] && [ "$l1" = "$r1" ] && [ -n "$r2" ] && [ "$l2" = "$r2" ]
}

ATTEMPT=0
while true; do
    ATTEMPT=$((ATTEMPT+1))
    wait_device
    if [ -z "$PROFILE" ]; then
        select_profile
        rc=$?
        [ "$rc" -eq 2 ] && { sleep 3; continue; }   # 瞬态读不到，稍后重试
        [ "$rc" -eq 0 ] || exit 1                    # 真正不支持的内核
    fi

    # 已 root 则直接结束
    if "$ADB" shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
        echo "== KernelSU 已激活，无需操作"
        "$ADB" shell "su -c id" 2>/dev/null | tr -d '\r'
        exit 0
    fi

    ENF=$("$ADB" shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
    if [ "$ENF" != "0" ]; then
        # phase 1: W1 → permissive
        echo "== 第 $ATTEMPT 次: W1 (SELinux) $(date '+%H:%M:%S')"
        push_all || { echo "   [-] 部署校验失败，3 秒后重试"; sleep 3; continue; }
        "$ADB" shell "cd /data/local/tmp && ./ghostlock --load-prebuilt-profile profile.bin --stop-after-w1 > reroot_w1.log 2>&1" > /dev/null 2>&1
        ENF=$("$ADB" shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
        if [ "$ENF" != "0" ]; then
            echo "   W1 未命中（设备日志 /data/local/tmp/reroot_w1.log；设备可能重启了，等待重连...）"
            sleep 3
            continue
        fi
        echo "   W1 成功 (permissive)"
    fi

    # phase 2: W2 → root → KernelSU 重载（permissive boot 内反复试）
    for i in $(seq 1 25); do
        wait_device
        ENF=$("$ADB" shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
        [ "$ENF" != "0" ] && break   # 重启了，回 phase 1
        push_all || { sleep 2; continue; }
        "$ADB" shell "cd /data/local/tmp && ./ghostlock --load-prebuilt-profile profile.bin > reroot_w2.log 2>&1" > /dev/null 2>&1
        if "$ADB" shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
            echo "== ROOTED + KernelSU 已激活（第 $ATTEMPT 次第 $i 次尝试）"
            "$ADB" shell "su -c id" 2>/dev/null | tr -d '\r'
            exit 0
        fi
        sleep 2
    done
done
