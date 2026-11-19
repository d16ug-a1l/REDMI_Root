# DIZI-02 真机门禁：dizi 5.10.246 select_stack 全链路 — PASS

验证实现：上游 [YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app)
select 路由 + 本项目批次 1/2/2c/2d/2e/3a 修复的移植（ghostlock-app
`feature/dizi-ghostlock-port`：`f4133e0` 移植、`a3f2c26` 覆盖修正、`5776103` 门禁归档）。
profile bin `profiles/5.10.246-android12-9-00012-g730d06ec05ff-ab15159037.bin`
md5 `f3124e6ad6932a82e1bdf448080d9c35`，与真机验证时设备端
`/data/local/tmp/profile.bin` 一致。

## 设备与入口

- 型号 2405CRPFDC（Redmi Pad Pro，dizi，parrot/SM7435）；`uname -r` =
  `5.10.246-android12-9-00012-g730d06ec05ff-ab15159037`；HyperOS 3 OS3.0.308.0.WNSCNXM，
  Android 16；锁屏 vbstate=green。
- 入口：CLI over USB adb，两段式（本项目 `tools/reroot.sh` 协议）：段 1
  `--stop-after-w1` 循环至 permissive → 段 2 新进程完整跑（W1 自动跳过，
  `w2_attempts=1`），CPU 对 0/1。

## 结果

2026-11-19 21:48 全链路 PASS（cycle 2 attempt 8 phase 2 第 1 试 = 总计第 5 次
W2 尝试，与 DIZI-01 标定的 1/3~1/2 命中区间一致；成功序列与 DIZI-01 逐行同构）：

```
[+] SELinux already permissive      # 两段式:W1 在独立进程已落地
[*] child uid = 2000                # victim 基线探针（批次 2e fd 修复后管道正常）
[*] W2 fast repair payload prebuilt # 批次 2c:init_cred+8 修复页预构建
[*] pselect route done calls=1 success=1 clean=1/1
[*] W2b: firing prebuilt init_cred+8 repair
[*] pselect route done calls=1 success=1 clean=1/1
[+] child uid = 0
[+] child is root!
[+] no app seccomp filter (adb/shell flow); skipping W3
[*] [T+14315ms] exploit complete
[+] KernelSU ready
```

事后核对（设备未 panic）：`su -c id` → `uid=0(root) gid=0(root) groups=0(root)
context=u:r:ksu:s0`；`/proc/modules`: `kernelsu 212992 … Live`；`.ghostlock_ksu.log`
记录 `late-load kmi=android12-5.10`、`late-load exit=0`、`KernelSU module loaded`；
SELinux 回 Enforcing（设计行为）。

复验（同日 23:31 重启后）：reroot 循环在开机 **~70 s** 内自动重取 root
（W1 首发命中 + W2 首发命中，boot 后 70.1 s dmesg 出现
`KernelSU: welcome to KernelSU version 32680`；ghostlock 主进程 handoff 存留、
KernelSU LKM 常驻至下一次重启）。

## 日志

- 成功运行日志与事后核验：ghostlock-app
  `specs/dizi-ghostlock-port/analysis/root-success/`（`c2_p2_8_1.log`、
  `evidence_214835.txt`）；门禁记录 `analysis/root-gate-record.md`。

## 说明

- 5.10.246 与 5.10.236 的 select 几何一致（`waiter_shift=-2` +
  `compact_waiter=1`，两段式 `w2_attempts=1`），差异仅在符号偏移与
  `cred.refN_image`（随内核构建变化，来历见 profile 头注释：本构建
  kallsyms + readelf 双源，disasm 定值 mm_struct=960 / cred=168）。
- W1 首次落地的关键：`compact_waiter=1`（5.10.246 上 12 点偏移网格证明其余
  几何全部写崩 panic），另有 profile 不携带任何实验性 `execution` 覆盖
  （`race.route_wait_ms=5000` 实测破坏 W1 竞态时机）。
- 已知设备特性同 DIZI-01：payload 页回收命中率 ~1/3–1/2，未命中即 panic 重启，
  两段式 + in-boot 重试将其转化为可自动恢复的循环；连续 panic 后命中率下降
  （疲劳，冷机 ~50% → 累计 ~170 次后 ~14%），断电静置可恢复。
