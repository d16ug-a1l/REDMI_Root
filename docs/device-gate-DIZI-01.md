# DIZI-01 真机门禁：dizi 5.10.236 select_stack 全链路 — PASS

基线提交 `67d519b`（上游 main）+ 本工作区未提交改动（批次 1/2/2c/2d/2e/3a，清单与验证见
`docs/development/dizi-5.10-select-adaptation-plan.md`）。候选二进制
`build/native/ghostlock` SHA-256
`cde2c59828586fbbecddf0f21a6c9f518028f9d26027fc0ef366f37a996648dc`（md5
`2311977db70f5f2d2266a7e351983cb9`，与设备端一致）。设备端 profile bin md5
`49ff261c8bd37236ff54db9edac1efb6`。

## 设备与入口

- 型号 2405CRPFDC（Redmi Pad Pro / POCO Pad，dizi，parrot/SM7435）；`uname -r` =
  `5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284`；HyperOS 3 OS3.0.307.0.WNSCNXM，
  Android 16，补丁 2026-08-01；锁屏 vbstate=green，无 KernelSU/su 预装。
- 入口：CLI over USB adb，`./ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin`；
  冷启动、单 route（select_stack）、CPU 对 0/1（profile 推荐值）。
- 两段式门禁（批次 2d）：段 1 `--stop-after-w1` 干净退出后段 2 在新进程跑 W2/W3。

## 结果

两次独立冷启动各完成一次完整 PASS（证据：`build/dizi/9p-c5-p2-1.log`、
`build/dizi/9p-c4-p2-1.log` + 驱动日志 `gate-2phase-driver10.log` /
`gate-2phase-driver11.log`）：

```
[+] child uid = 2000            # W2 写入前基线探针：child 存活应答
[*] pselect route done calls=1 success=1 status=0 clean=1/1 step=0 errno=0
[*] W2b: firing prebuilt init_cred+8 repair
[*] pselect route done calls=1 success=1 status=0 clean=1/1 step=0 errno=0
[+] child uid = 0
[+] child is root!
[+] no app seccomp filter (adb/shell flow); skipping W3
[*] [T+13558ms] exploit complete
[+] KernelSU ready
```

事后核对（设备未 panic）：`su -c id` → `uid=0(root) gid=0(root) groups=0(root)
context=u:r:ksu:s0`；SELinux 回 Enforcing；KernelSU 管理器显示「工作中 [越狱模式]」；
`.ghostlock_ksu.log` 记录 `late-load kmi=android12-5.10`、`late-load exit=0`、
`KernelSU module loaded`。

## 日志

- 主机侧：`build/dizi/`（门禁循环驱动日志 `gate-2phase-driver*.log`、各轮运行日志
  `9p-c*-p*-*.log`、A/B 对照 `ab-driver.log`、A/B 运行日志 `ab-*.log`）。
- 设备侧：`/data/local/tmp/.ghostlock_ksu.log`（late-load 记录）、
  `.ghostlock_iomem`（root 后缓存的 /proc/iomem，11227 字节）。

## 变更说明

- 本记录覆盖批次 1（leaf arm / ghost disarm）、批次 2（mm_struct_sz=960）、
  批次 2c（5.x select 的 w2_fast_repair）、批次 2d（两段式运行）、批次 2e（victim 管道
  fd 抬升——修复 select 路由 dup2 强占管道 fd 导致 verify 假失败的上游潜在 bug）、
  批次 3a（skb_reclaim_sends/skb_frag_bias 下沉为 profile 字段 + ProfileMerger
  共享可变修复）的联合真机验证。
- 已知设备特性：payload 页回收命中率约 1/3–1/2，未命中即 panic 重启（KASAN_HW_TAGS +
  PANIC_ON_OOPS 环境），两段式与 in-boot 重试将其转化为可自动恢复的循环。
