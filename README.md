# REDMI_Root — Redmi Pad Pro 内核 Root 方案

针对 **Redmi Pad Pro / POCO Pad（dizi，代号 parrot）** 的一键内核 Root 工具。
基于 CVE-2026-43499（futex PI UAF，上游项目
[YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app) 的 select_stack 路由）
完成对该机型的完整适配与真机验证。

- 设备：Redmi Pad Pro (2405CRPFDC) / POCO Pad
- 内核：`5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284`
- 系统：HyperOS 3（Android 16）实测通过
- 效果：临时 Root + KernelSU（越狱模式 / LKM，不解锁 BL、不改 boot 镜像）
- 真机门禁：连续 2 次冷启动全链路通过（记录见 `docs/device-gate-DIZI-01.md`）

> 📖 **零基础学习 / 完整复现教程**（含原理图解与逐行脚本讲解）：
> [docs/tutorial.md](docs/tutorial.md)

## 工作原理（简版）

利用内核 `remove_waiter()` 在 PI-futex 回滚路径操作错误任务的漏洞
（CVE-2026-43499），通过 pselect 栈帧复用伪造 `rt_mutex_waiter`，在 PI 链
调整优先级时触发受控内核写：W1 关闭 SELinux → W2 覆写子进程 cred 为
`init_cred`（uid 0）→ 加载 KernelSU 内核模块。全程纯数据写，不触碰 CFI
保护的控制流。

## 要求

- 上述机型与内核版本（设置 → 关于平板 → 内核版本核对）
- 一台电脑（macOS / Linux），装好 **Android SDK Platform-Tools**（adb）
- 平板开启 **USB 调试**（开发者选项）
- 平板安装 [KernelSU 管理器](https://github.com/tiann/KernelSU/releases) APK
  （Root 脚本会自动从管理器 APK 中提取 ksud 完成模块加载）

## 构建

```bash
# 安装 Android NDK（任一方式），然后：
./build.sh
```

产物：`build/native/ghostlock`。脚本会自动探测常见 NDK 路径，
也可手动指定：`ANDROID_NDK_HOME=/path/to/ndk ./build.sh`。

profile 已预构建（`profiles/*.bin`），随源码附 `.conf` 原文供参考，
一般无需重新生成。

## 使用

```bash
# 平板 USB 连接电脑后：
tools/reroot.sh
```

脚本自动完成全部流程，期间**平板可能自动重启若干次**（漏洞利用的概率性
堆回收所致，单次命中率约 1/3~1/2，脚本会自动重试直到成功），看到
`ROOTED + KernelSU 已激活` 即成。实测通常几分钟到二十几分钟。

Root 为**越狱模式（重启失效）**：重启后重新运行 `reroot.sh` 即可；
KernelSU 的模块与授权配置保存在 `/data/adb`，重 Root 后自动恢复。

## 常见问题

- **运行中平板重启了？** 正常现象（未命中即内核 panic），脚本会自动等设备回来继续。
- **一直失败？** 确认内核版本完全一致；不同 MIUI/HyperOS 版本内核不同则不能用本 profile。
- **想恢复出厂？** 重启即回到无 Root 状态，不刷写任何分区，不留痕迹（除 `/data/adb` 中的 KernelSU 配置，可在管理器中卸载清除）。

## 免责声明

**使用本工具前请务必阅读 [DISCLAIMER.md](DISCLAIMER.md)（法律免责声明 &
使用合规须知）。**

简要提示：本工具仅供安全研究、授权测试与**本人自有设备**使用；运行过程
可能触发设备内核崩溃与自动重启（本方案不刷写分区，风险限于数据损坏级）；
使用本工具即表示同意 DISCLAIMER.md 的全部条款，一切法律后果由使用者
自行承担。

## 致谢与许可

- 上游项目：[YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app)
- 漏洞研究：NebuSec（kernelCTF）与各社区适配者
- 本项目以 Apache License 2.0 发布（见 `LICENSE`），源码包含上游项目的
  修改版本（dizi 适配、5.10 select 路由修复等，详见 `docs/adaptation-plan.md`）。
