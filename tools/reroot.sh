#!/bin/bash
# dizi 一键重 root：平板 USB 连接电脑后运行本脚本即可。
# 自动完成：W1 (SELinux permissive) → W2 (cred root) → KernelSU 模块重载。
# 之前的模块和授权配置会自动恢复。
# 过程中平板可能重启若干次（属正常，USB 会自动重连），看到 ROOTED 即成。
cd "$(dirname "$0")/.." || exit 1

BIN=build/native/ghostlock
PROFILE=""   # 首次连上设备后按 uname -r 自动选择（profiles/<内核版本>.bin）

# adb：优先系统的；否则用 ./build.sh 自动下载到 .tools/ 的
ADB="$(command -v adb 2>/dev/null || true)"
if [ -z "$ADB" ] && [ -x ".tools/platform-tools/adb" ]; then
    ADB=".tools/platform-tools/adb"
fi
if [ -z "$ADB" ]; then
    echo "[!] 找不到 adb：请安装 Android platform-tools，或先运行 ./build.sh（Linux 会自动下载）"
    exit 1
fi
echo "[*] adb: $ADB"

# 按设备内核版本选择 profile：profile 与内核构建逐字节绑定（符号偏移/结构体
# 尺寸随构建变化），版本不匹配会导致写入错位甚至 panic。
select_profile() {
    local rel
    rel=$("$ADB" shell uname -r 2>/dev/null | tr -d '\r')
    if [ -n "$rel" ] && [ -f "profiles/$rel.bin" ]; then
        PROFILE="profiles/$rel.bin"
        echo "[*] 内核 $rel → $PROFILE"
        return 0
    fi
    echo "[!] 暂不支持内核 $rel（缺少 profiles/$rel.bin）。已支持的 profile："
    ls profiles/*.bin 2>/dev/null | sed 's/^/    /'
    return 1
}

wait_device() {
    while true; do
        for s in $("$ADB" devices 2>/dev/null | awk '$2=="offline" || /:/{print $1}'); do
            "$ADB" disconnect "$s" >/dev/null 2>&1
        done
        if "$ADB" get-state 2>/dev/null | grep -q device; then
            if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
                return 0
            fi
        fi
        sleep 5
    done
}

push_all() {
    "$ADB" push "$BIN" /data/local/tmp/ghostlock >/dev/null 2>&1
    "$ADB" push "$PROFILE" /data/local/tmp/profile.bin >/dev/null 2>&1
    "$ADB" shell chmod 755 /data/local/tmp/ghostlock 2>/dev/null
}

ATTEMPT=0
while true; do
    ATTEMPT=$((ATTEMPT+1))
    wait_device
    [ -n "$PROFILE" ] || { select_profile || exit 1; }

    # 已 root 则直接结束
    if "$ADB" shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
        echo "== KernelSU 已激活，无需操作"
        exit 0
    fi

    ENF=$("$ADB" shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
    if [ "$ENF" != "0" ]; then
        # phase 1: W1 → permissive
        echo "== 第 $ATTEMPT 次: W1 (SELinux) $(date '+%H:%M:%S')"
        push_all
        "$ADB" shell "cd /data/local/tmp && ./ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin --stop-after-w1" > /dev/null 2>&1
        ENF=$("$ADB" shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
        if [ "$ENF" != "0" ]; then
            echo "   W1 未命中（设备可能重启了，等待重连...）"
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
        push_all
        "$ADB" shell "cd /data/local/tmp && ./ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin" > /dev/null 2>&1
        if "$ADB" shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
            echo "== ROOTED + KernelSU 已激活（第 $ATTEMPT 次第 $i 次尝试）"
            exit 0
        fi
        sleep 2
    done
done
