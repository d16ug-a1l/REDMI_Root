#!/bin/bash
# dizi 一键重 root：平板 USB 连接 Mac 后运行本脚本即可。
# 自动完成：W1 (SELinux permissive) → W2 (cred root) → KernelSU 模块重载。
# 之前的模块和授权配置会自动恢复。
# 过程中平板可能重启若干次（属正常，USB 会自动重连），看到 ROOTED 即成。
cd "$(dirname "$0")/.." || exit 1

BIN=build/native/ghostlock
PROFILE="profiles/5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284.bin"

wait_device() {
    while true; do
        for s in $(adb devices 2>/dev/null | awk '$2=="offline" || /:/{print $1}'); do
            adb disconnect "$s" >/dev/null 2>&1
        done
        if adb get-state 2>/dev/null | grep -q device; then
            if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
                return 0
            fi
        fi
        sleep 5
    done
}

push_all() {
    adb push "$BIN" /data/local/tmp/ghostlock >/dev/null 2>&1
    adb push "$PROFILE" /data/local/tmp/profile.bin >/dev/null 2>&1
    adb shell chmod 755 /data/local/tmp/ghostlock 2>/dev/null
}

ATTEMPT=0
while true; do
    ATTEMPT=$((ATTEMPT+1))
    wait_device

    # 已 root 则直接结束
    if adb shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
        echo "== KernelSU 已激活，无需操作"
        exit 0
    fi

    ENF=$(adb shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
    if [ "$ENF" != "0" ]; then
        # phase 1: W1 → permissive
        echo "== 第 $ATTEMPT 次: W1 (SELinux) $(date '+%H:%M:%S')"
        push_all
        adb shell "cd /data/local/tmp && ./ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin --stop-after-w1" > /dev/null 2>&1
        ENF=$(adb shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
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
        ENF=$(adb shell "cat /sys/fs/selinux/enforce" 2>/dev/null | tr -d '\r')
        [ "$ENF" != "0" ] && break   # 重启了，回 phase 1
        push_all
        adb shell "cd /data/local/tmp && ./ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin" > /dev/null 2>&1
        if adb shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
            echo "== ROOTED + KernelSU 已激活（第 $ATTEMPT 次第 $i 次尝试）"
            exit 0
        fi
        sleep 2
    done
done
