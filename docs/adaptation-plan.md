# dizi 5.10 select 路由适配计划（2026-10-08）

> 按 `documentation-standards.md` 计划模板撰写。**全部批次已完成**（2026-10-09）：
> 门禁连续 2 次冷机 PASS（记录 `docs/analysis/device-gates/DIZI-01-20261009-select-stack-pass.md`），
> dizi 已登记 SUPPORTED_DEVICES，KernelSU 越狱模式落地。

## 现状与基线

- 分支基线：`very-not-stable-dev` 上游 `main` @ `67d519b`（克隆后未提交任何 commit）。
- 工作区已含未提交改动（全部经真机/静态验证到达当前状态）：
  - `app/src/main/assets/kernel_profiles/5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284.conf`（新增）
  - `app/src/main/assets/kernel_profiles/index.conf`（+1 登记行）
  - `tools/extract_rs/examples/dump_init_cred.rs`、`derive_select_shift_5x.rs`（新增，主机侧一次性推导工具）
  - `local.properties`（本机 SDK/NDK 路径，不提交）
- 设备：Redmi Pad Pro / POCO Pad（dizi，parrot），`5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284`，
  HyperOS 3 OS3.0.307.0.WNSCNXM，Android 16，补丁 2026-08-01，无 KernelSU/su，vbstate=green。
- profile 静态证据链（已完成，可信）：
  - 漏洞原语存在：`remove_waiter@0x1ecc18` 未修补（官方 OTA boot.img 静态判定）。
  - 全部结构体偏移取自同构建 GKI vmlinux（ci.android.com build 14313284，kernel/common fb24cf99ad97）
    的 DWARF，并在设备 boot.img 上交叉验证：`init_task.comm="swapper"`、`init_cred` caps 段
    （0x30..0x40 = 0x1ffffffffff×3）、`init_task.tasks` 自链指针逐字节吻合。
  - select 栈几何用两侧 syscall 链帧深**字节级证明**：futex 链（0x90+0x70+0x1a0，waiter 在
    futex_wait_requeue_pi sp+0x90，交叉验证 [sp,#0x90]/[sp,#0xc0] 两处真实写）与 pselect 链
    （0xa0+0x1c0，stack_fds 在 core_sys_select sp+0x50，nfds=320 栈路径阈值成立）都得
    S0-0x210 → delta=0 → `waiter_shift=-2`。
- 门禁失败证据（三次冷机、同一构建、同一执行点 `pselect pre-select attempt=1/4` panic，
  满足同构建复现 + 冷机复跑，排除 KERNEL-PANIC-01）：
  - run1：NULL deref @ 0xc39，`rt_mutex_adjust_prio_chain+0x3f0` = `rt_mutex_top_waiter` 的
    BUG_ON 前置读取；`fake_lock->waiters.rb_leftmost` 读出 **0xc01**。
  - run2：NULL deref @ 0x8，`rb_insert_color+0x48` = `__rb_insert` 读 `gparent->rb_right`、
    gparent==NULL（树中存在"红色无父"节点）。
  - run3：同点 panic（签名未取回，设备离线超时）。
- **根因判定（指令级分析，证据见下）**：两次 panic 同源于 **payload 页堆回收未命中**——
  walk 解析的 fake_lock 页仍是回收前的旧 mm_struct 内容（0xc01 = dizi 5.10 `mm_struct.vmacache_seqnum@+0x10`，
  量级与本轮 spray 的数千次 dup_mm 吻合；同轮 KernelSnitch 泄漏前 3 次失败也旁证堆回收临界）。
  **5.10 rtmutex walk 本身无害**：在"盖章正确 + 页正确"前提下，walk 可全程走完并在 [7] 的
  tree_entry erase 触发写原语（run2 的 `*target = fake_right` 实际已打出，随后才因页垃圾崩溃）。
- 已排除的假设：waiter_shift 错误（帧深核算精确）；5.10 walk 语义不兼容（逐指令核对无害）。

### 5.10 特有差异清单（已在指令级核对，作为后续设计事实）

1. `rt_mutex_waiter` 布局：tree_entry@0 / pi_tree_entry@0x18 / task@0x30 / lock@0x38 / **prio@0x40** /
   deadline@0x48，size 0x50；**无 wake_state、无 ww_ctx**（5.15：wake_state@0x40、prio@0x44）。
   现 compact 编码按 5.15 布局写 +0x44=140，5.10 内核实际从 +0x40 读到 0/3。
   影响面：[7] 后重插入落在 fake_w0 右侧而非 leftmost，[11] 的 pi-erase refire（冗余写）不发生；
   主写不受影响。单 waiter 场景下 waiter_equal 门禁（不等即 requeue）与 [9] wake 分支均不受影响。
2. `route_needs_ghost_disarm()` 仅对 multicast 为真（route_policy.hpp:271-276）；5.10 的
   CMP_REQUEUE 错误路径清的是 `current->pi_blocked_on`（main 线程），waiter 线程的
   `pi_blocked_on` 必成悬空 ghost——select 路由在 5.10 上不做 disarm，W2/W3 复用 race 时是隐患。
3. select 编码器 leaf arm 偏离 `encode_compact_waiter` 契约（见改动清单批次 1）。

## 目标与约束

**目标**：dizi 5.10.236 select_stack 路由真机门禁通过（W1/W2 写验证，CLI shell 域跳过 W3；
app 内 Shizuku 路径同），profile 标记前完成全部验证门槛。

**非目标**：
- 不恢复 multicast/tcp 路由（multicast 已证几何不可行：waiter_off=336 > 固定 264 字节窗口；
  tcp 被 uapi 结构尺寸结构性封死）。
- 不做 5.10 通用支持（仅本 release）。
- 不改 walk/rtmutex 相关假设（已证无害）。
- 不追求 [11] refire 恢复（冗余写，功能不缺；如需恢复另立 L 级项）。
- W3（seccomp）不在本计划内验证（shell/Shizuku 路径天然跳过）。

**约束**：profile(GLK1) 是唯一配置权威；新增字段双侧同步并由对拍测试锁定；攻击路径改动
必须 cmp_disasm 8 函数 + 真机门禁 + 门禁记录；未过门禁不得标 supported。

## 改动清单

### 批次 1（S 级上限，正确性修复，先做）

| 文件 | 改动 | 理由 |
|---|---|---|
| `src/core/route/select_stack_route.cpp` | compact 分支 words[]：leaf（fake_right==0）时 tree/pi 两组三字段改盖 `{fake_parent, 0, 0}`（对齐 `encode_compact_waiter` 契约与 payload_builder.h:71-72 注释）；非 leaf 不变 | 现实现对 leaf 盖 `{0,0,target}` → erase 走 root arm 把 rb_root 写成 target → 下次 insert 从 selinux 数据区遍历 → rb_insert_color 型 panic。W1/W2 当前 preserve_child=1 不触发，W3 会踩；属真实正确性 bug |
| `src/core/tests/`（现有 select/编码器固定向量测试） | 加 leaf 固定向量（pc=left=... 对齐 payload_builder 既有向量语义） | 机制防错，固定回归 |
| `src/core/route/route_policy.hpp` | 评估并把 `route_needs_ghost_disarm()` 覆盖到 5.10 的 select（按 compact_waiter+kernel_major==5 判定或新 policy 声明，取最小表达） | 5.10 ghost 必然残留（差异清单 #2）；W2/W3 复用 race 时防二次 walk 踩复用栈帧 |

### 批次 2（M–L 级，根因修复，需先取证据）

| 文件 | 改动 | 理由 |
|---|---|---|
| `src/core/memory/heap_context.*` / `util.cpp::prepare_kernel_page` 一带 | 先加**回收命中自检/诊断**（盖章前校验页内容 oracle，失败即 ROUTE_RETRYABLE 而不是放行进 walk）；再按诊断数据校准 dizi 的 skb 回收几何（现 SKB_DATA_DELTA/SKB_FRAG_BIAS 为编译期常量，constants.hpp:14,24） | 两次 panic 的共同根因；先加 oracle 把"回收未命中"从随机 panic 变成可观测、可安全重试的失败 |
| （可能）profile heap 节新字段 | 若校准结论是因机而异的 delta/bias，下沉为 profile 字段（双侧同步 + 对拍测试） | 配置唯一权威；不硬编码 per-device 值 |

### 批次 2c（M 级，W2 修复机制补齐）

| 文件 | 改动 | 理由 |
|---|---|---|
| `src/core/route/route_policy.hpp` | `SelectPolicy` 声明 `w2_fast_repair = true` + Android-only noinline 钩子声明 | 40 轮门禁实测：W1 命中 15/40（37%），W2 0/15 全 panic。5.x cred 写的 erase 第二写会把 cred 指针写进真实 init_cred+8（损坏 init_cred.gid），multicast 有 prebuild/activate 修复而 select 缺失，5.x+select 的 W2 从未被上游验证过 |
| `src/core/route/select_stack_route.cpp` | 定义 `SelectPolicy::w2_fast_repair_prebuild/activate`，语义与 multicast 版相同（stash 预喷 repair 页 → 主写后激活触发 `init_cred_alias+8` 清零），**运行时按 `kernel_major==5` 自门控**，6.x 保持中性 no-op | 保护已由开发者验证的 6.x select 路径；修复机制对 5.10/5.15 同类必需 |
| `src/core/tests/route_policy_test.cpp` | SelectPolicy 能力断言同步 | 能力清单对拍 |

### 批次 2d（M 级，两段式运行——借鉴 ghostlock-oneplus 的进程隔离设计）

| 文件 | 改动 | 理由 |
|---|---|---|
| `src/core/session/runtime_config.h` | `RuntimeConfig` 新增 `stop_after_w1`（默认 false，init() 不清） | 门禁实测：W1 命中后同进程继续 W2 时堆已被几千次 fork/spray 搅脏，W2 回收命中率趋近 0（15/15 panic）。ghostlock-oneplus 的 bootstrap 模式同样把 W1 放在独立进程跑完即退出（其 main.c:753 注释明确此动机） |
| `src/core/main.cpp` | 解析 `--stop-after-w1`，写入 runtime config | CLI 进程行为开关，与 `--force-attack` 同类 |
| `src/core/session/backend/cve_2026_43499_backend.cpp` | `run()` 在 w1 返回 Continue 后查开关，`true` 则 `pr_success` + 返回 `StageResult::Done`（映射 DiagnosticStop，exit 0） | 段 1：循环跑 `--stop-after-w1` 直到 W1 成功干净退出；段 2：再跑普通模式，`check_selinux_off()` 命中既有 "SELinux already permissive" 分支跳过 W1，在干净堆里直接做 W2（此时 W2 命中率 ≈ 冷机 W1 的 37%，配合批次 2c 的 fast_repair） |

### 批次 3（验证与收尾）

- dizi 真机门禁（冷机、固定 CPU 对、单 route、无 KernelSU），连续 2 次 PASS 才算通过；
- 门禁记录归档（本文 §进度 关联，格式见门禁模板）；
- 通过后更新 `docs/kernel_profiles/SUPPORTED_DEVICES*.md`（双语）登记 dizi；未通过不标。

## 数据流/控制流差异

- 批次 1 leaf 改动只改变 leaf 写时盖章的三个 u64（pc/left 的来源字段），wire/profile 格式不变；
  非 leaf 路径字节不变（用 cmp_disasm + 固定向量证明）。
- 批次 1 ghost-disarm 改动在 route 收尾路径增加一次 futex slow-path disarm（复用 multicast 既有语义），
  不改攻击窗口内任何行为。
- 批次 2 的 oracle 是 prepare 阶段的只读校验（攻击窗口外），失败语义 = 安全重试，不产生新内核写。
- 不变量：5.15/6.x 已验证设备的全部既有行为不变（所有改动对非 dizi profile 字节级无感，
  由 cmp_disasm + host 固定向量 + RouteCatalogAgreementTest 对拍证明）。

## 兼容性与回滚

- 全部改动向后兼容：无 wire 格式版本变更（v2 不变），leaf 修复只影响错误分支。
- 回滚 = revert 对应批次 commit；profile conf 与 index.conf 登记行随批次 3 门禁结果决定去留
  （未过门禁则 conf 保留但不进 SUPPORTED_DEVICES）。

## 验证矩阵

| 批次 | 命令/动作 | 预期 |
|---|---|---|
| 1 | `make -C src native-host-tests` | 全过（含新 leaf 固定向量） |
| 1 | `make -C src lint-tidy` | 0 findings |
| 1 | NDK 构建 | 零警告 |
| 1 | `python3 tools/cmp_disasm.py <baseline> build/native/ghostlock` | 8 函数 IDENTICAL 或具名注解差异（leaf 分支） |
| 1 | dizi 门禁 ×2 冷机 | 不再有 rb_insert/root-arm 型 panic；W1 仍按批次 2 前的回收命中率表现 |
| 2 | 同上门禁 + 诊断日志 | 回收未命中 = 可观测重试（不再 panic）；按日志校准后 W1 verify 通过 |
| 3 | dizi 冷机 ×2 连续 | W1/W2 写验证通过、无 panic → 方可标 supported |
| 全部 | `./gradlew :app:testDebugUnitTest` | 全过（含双侧对拍） |

KERNEL-PANIC-01 纪律适用：任何新 panic 必须同构建复现 + 冷机复跑 + 栈证据才允许归因；
每次门禁后取回 RebootChart 记录归档。

## 明确保留

- `kernelsnitch/` 上游代码、`LegacyProfileConverter.kt` 的 v1 转换：不动。
- rtmutex walk 相关假设、`waiter_shift=-2` 几何：已字节级核对，不动。
- multicast/tcp 路由代码与 5.15/6.x 全部既有 profile：不动。
- `route_needs_ghost_disarm` 的 multicast 既有行为：不动（批次 1 只扩展覆盖）。
- 不引入新的配置格式版本；不为 dizi 硬编码任何值进 native（校准值走 profile）。

## 进度

- [x] 设计文档（本文）
- [x] 批次 1：select leaf arm + ghost-disarm + host 测试 + cmp_disasm
  - 改动：`select_stack_route.cpp`（leaf 盖 `{fake_parent,0,0}`）、`route_policy.hpp`
    （ghost disarm 扩展到 kernel_major==5）、`route_policy_test.cpp`（5.x/6.x 断言）
  - 验证：`native-host-tests` 20/20 ok；NDK 构建零警告；`lint-tidy` exit 0；
    cmp_disasm：5 函数 IDENTICAL、2 函数基线/当前均 MISSING、waiter_thread +3 指令
    已复核（major==5 的 cmp/b.eq/cbz，其余纯地址重编号；`do_pselect_fake_lock_route`
    纯重编号、`select_stack_build_fdsets` 差异=leaf csel 三态选择+块重排）
  - 备注：`:app:testDebugUnitTest` 的 `ProfileMigrationEquivalenceTest` 失败为
    **上游 HEAD 既有问题**（fixture 55 条 vs 当前 6.x builtin 57 条，缺
    6.1.25-maybe-dirty 与 6.6.89-ab13771415；与本批改动无关，不属本计划范围）；
    其余 79 项通过
- [x] 批次 1：dizi 门禁 ×2（观察是否消除 root-arm 崩溃型；回收未命中 panic 预期仍在）
  - run4（批次 1 构建）：**无 panic**，15 次 W1 尝试干净失败退出（exit=1）；
    ghost-disarm 在 select 路由生效（日志 `mcast ghost disarm ret=-1 errno=110`）；
    暴露出批次 2 根因的完整图景：KernelSnitch 泄漏成功率 ~3%（60 次成 2 次）
- [x] 批次 2（根因定位）：**mm_struct slab 步进错误**。dizi SLUB 为 64B cacheline：
  DWARF sizeof(mm_struct)=952 → 实测 /proc/slabinfo objsize=960 objperslab=34；
  profile 沿用 5.15 机的 1024 → 扫描/回收错位。两次成功泄漏均落在 960/1024 重合槽位
  （k∈{0,15,30}）实锤。修复：profile `mm_struct_sz = 960`（纯配置）。
  依据采集：本机 shell 直读 /proc/slabinfo 与 /proc/config.gz（无需 root）。
- [ ] 批次 2：门禁验证 run5（960）：**泄漏 attempt=1 即成功**（+2.2s），但 walk 阶段
  panic（exit=255，pre-select attempt=1/4）——页应已正确回收，panic 指向路由语义；
  RebootChart 签名待取回分析
- [x] 批次 3：门禁 ×2 连续 PASS、门禁记录、SUPPORTED_DEVICES 登记（仅当通过）
- [x] **批次 2e 门禁通过（2026-10-09 00:44）**：fd 抬升修复后首个 permissive boot 的
  段 2 第 1 次尝试即 W2 成功（`child uid = 0` / `child is root!`），root 脚本以
  uid=0 完整执行（policy fixup rc=0；iomem 缓存 11227 字节落盘，供精确校准）。
- [x] **KernelSU 落地（2026-10-09 01:2x，`.ghostlock_ksu.log` 证据）**：安装管理器后
  重跑，`late-load kmi=android12-5.10 exit=0` → `KernelSU module loaded`；终验
  `adb shell su -c id` → `uid=0(root) context=u:r:ksu:s0`，管理器显示
  「工作中 [越狱模式]」。**dizi 5.10.236 select 路线全通。**
- [x] **批次 3b/3c 完成（2026-10-09 03:0x-03:3x）**：连续 2 次冷启动全链路 PASS
  （v10 cycle 5 / v11 cycle 4，均 `KernelSU ready`）；门禁记录
  `docs/analysis/device-gates/DIZI-01-20261009-select-stack-pass.md`；
  SUPPORTED_DEVICES 双语登记；conf 摘除 "unverified" 标注。
- [x] A/B 对照：pre3a vs 3a 构建 W1 命中率一致（各 1/3），批次 3a 无回归。
- [x] iomem 校准核对：root 后 `/proc/iomem` 实测 System RAM 起始于 0x808f4000，
  DRAM base=0x80000000 与 profile 默认一致，`kernel_phys_load=0xa8000000` 落在
  RAM 映射内——**全部 profile 几何值经真机数据复核，无需修正**。

### 批次 2 实施记录（2026-10-08 下午）

- run6（sends=16）：panic（签名 rb_insert_color+0x48 同 run2）。
- **几何突破**：dizi 5.10 的 unix sendmsg 分配路径（af_unix.c + skbuff.c 源码核实）=
  4KB 头（kmalloc）+ order-3 整页 frag（数据在页偏移 0）→ 流字节 4096 对应目标块开头；
  沿用 5.15 的 bias=0 会把 payload 放错 0x180。试验：`SKB_FRAG_BIAS 0→0x180`。
- run8（bias=0x180 + sends=16 + 诊断日志）：**W1 成功**（attempt 4 route done
  status=0 → "SELinux permissive" → "Write 1 complete"，写验证通过），**实证
  shift=-2 几何、bias=0x180 对齐、5.10 walk 三者全部正确**。W2 attempt 4 panic
  （签名 rb_insert_color+0x48，回收未命中类）。
- run9（sndbuf 4MB + sends=128 灌满）：panic——order-3 frag 分配失败回退小页后
  buddy 拆分目标块，映射错位；过压无效。
- run10（回到 run8 配置）：W1 首次 walk panic——run8 的 W1 成功含概率成分。
- **结论**：单次 walk 回收命中率约 1/3–1/2，未命中即 panic（页内容为旧 mm/错位
  frag/野指针，无读原语可事前检测）；无 root 无法读 pstore/buddyinfo/slab 内部，
  校准只能靠门禁迭代。剩余工作 = 回收确定性校准（heap feng shui），成本是
  每轮一次 panic + 手动 USB 重插。
- run11/12（oracle / drain+oracle）：panic 依旧，oracle 零触发——drain 掏空
  order-3 freelist 反而迫使回收 frag 回退到小页拆分目标块（mapping 破碎），已回退
  drain。证据现指向：块多数时候被 frag 覆盖但**内容映射错位**（order 回退）或
  未覆盖（stale mm）；oracle 只在"块留在 slab"时有效，触发率低。
- run13（作者原版编排 sends=4 + bias=0x180 + oracle）：仍 panic。当前工作区回到
  run8 验证过的配置（sends=16、bias=0x180、960）+ oracle + reclaim 诊断日志。
- **命中率核算**：6 次走到 walk 的尝试中 W1 命中 1 次（run8）。run8 证明几何、
  对齐、5.10 walk 全部正确；剩余纯粹是回收命中率的概率问题。

### 离线分析记录（2026-10-08 晚，真机暂停期间）

1. **panic 签名归类**（6 份 bugreport 的 RebootChart，含 40 轮循环的 108 次崩溃）：
   全部为同族——`rt_mutex_adjust_pi+0x174` 下 `rb_insert_color+0x48` /
   `rt_mutex_adjust_prio_chain+0x3f0` / `+0x548`。**零 cred 相关签名**：
   cred 状态不一致导致内核侧崩溃的假设不成立。
2. **W2 cred 写副作用精确推导**（encode_compact_waiter + 5.10 rbtree/rtmutex 语义）：
   主写 `*(child_task+1920) = init_cred_alias`（pc 低 2 位为 0，写值精确，无毒指针）；
   副写 `*(init_cred+8) = child_task+1920`（由 fast_repair 清零修复）。无其他越界写。
   **纸面结论：写入若落在正确 child 上，getuid 必返回 0**——child 沉默只剩
   "写入时 child 已死/地址失效" 或 "child_task 指错" 两种可能，由 comm 探针裁决。
3. **内核配置**（从 boot.img 提取 IKCONFIG，181KB）：
   - `CONFIG_DEBUG_CREDENTIALS` 未设（无 cred 魔数校验地雷）
   - `CONFIG_PANIC_ON_OOPS=y`（任何 oops 即重启——所有失败的物理成本来源）
   - `CONFIG_CFI_CLANG=y`（证实 ghostlock-oneplus 的 fops 劫持路线在 dizi 不可行，
     数据写路线是唯一选择）
   - `CONFIG_KASAN_HW_TAGS=y` + `CONFIG_KFENCE=y`（回收未命中族 panic 的可能放大器）
   - 无 `RANDOMIZE_KSTACK_OFFSET`（5.13 才引入，5.10 栈几何确定——stamping 可靠的原因）
   - `SLAB_FREELIST_RANDOM/HARDENED`、`SHUFFLE_PAGE_ALLOCATOR`、`INIT_ON_ALLOC` 均开启
4. **probe 模式 v1 教训**：SELinux enforcing 下 perf_event_open 被禁
   （15 轮零 panic 全败于 "perf leak did not reproduce"）；probe 已改为 W1 之后执行，
   同 boot 内 W1 成功一次后续探针全部跳过 W1。

### 批次 3a（M 级，校准值下沉 profile + 上游合并器修复——2026-10-09）

- **动机**：dizi 校准值（`skb_reclaim_sends=16`、`skb_frag_bias=0x180`）原为编译期常量，
  直接落地会回退 6.x/5.15 已验证设备（上游值 4/0）。按"profile 唯一权威"下沉为
  profile 字段（absent = 编译期默认）。
- **触点**：native `model.h`（KernelMisc+访问器）/`binary.cpp`（kKernel +2 OPT）/
  `constants.hpp`（恢复 4/0）/`util.cpp`（消费点改读 profile）；Kotlin
  `NativeProfile.kt`（声明/序列化/HOCON 解析/反序列化/构造共 6 处）/
  `AndroidProfileConfigController.kt`（字段清单）/`FieldLabels.kt`+双语 strings；
  dizi conf `kernelsnitch { skb_reclaim_sends=16, skb_frag_bias=384 }`。
- **附带发现并修复上游 bug**：`ProfileMerger.resolveMerged` 把共享的
  `tuningExecution` 按引用放进 defaults，`deepMergeValues` 原地改 base →
  任何携带 execution 覆盖块的 profile（dizi 是第一个）会把覆盖值**污染进导出循环后续
  所有 profile**（5.15.189 的 w2_attempts 被写成 1，被 ExporterAgreementTest 抓获）。
  修复：放入前 `copyValue()` 深拷贝。
- **验证**：host tests 20/20；lint exit 0；cmp_disasm 8 函数全部 LAYOUT-SHIFT
  （仅注解位移，无指令形状变化）；`exportKernelProfiles` 后实测 5.15.189
  w2_attempts=15、dizi w2_attempts=1/skb 字段=384/16；`:profile-core:test` 全过；
  `:app:testDebugUnitTest` 仅剩上游既有 ProfileMigrationEquivalenceTest 失败。
- **A/B 对照（3a 无回归实证）**：pre3a 构建（两次 root 成功的代码态）与 3a 构建
  同机交替各 3 次 W1：pre3a 1/3、3a 1/3，命中率一致——冷机门禁初段的 0/6 为
  概率波动，非代码回归。

### 批次 2e（S 级，W2 verify EBADF 根因修复——2026-10-09）

- **根因**（门禁取证 + 代码审查闭环）：select 路由 `open_selected_fds()` 对 fd_set 置位
  的每个 fd 号做 `dup2` 强占；非 leaf 写入把 `pi_left=target`（内核指针）盖进 fd_set，
  指针低字节 bit 6/7 置位时挤掉 victim 管道 fd 6/7 → child 读 EOF 退出(exit 1) →
  verify EBADF。comm 探针（leaf，pi_left=0）不受影响——与全部观测一致。
  此为上**游潜在 bug**（6.x 已验证设备未踩到纯属地址运气）。
- **修复**：`spawn_child` 建管后把六个管道 fd 用 `fcntl(F_DUPFD, PSELECT_ROUTE_NFDS+128)`
  抬到盖章窗口之上（同款先例：`reserve_standard_io`）。
- 附带：`verify_w2_stage`/`verify_leaf_dir_stage` 增加 child 存活与 fd 取证日志
  （waitpid 状态码 + fd 号），`w2()` spawn 后打印管道 fd。

### 批次 2c/2d 实施记录（2026-10-08 晚）

- **方案 A 40 轮结论**：W1 15/40（37%）；W2 在 15 次机会中 0 成功（首次 walk 必 panic）。
- **批次 2c**：w2_fast_repair 移植到 select（`kernel_major==5` 自门控）。验证：host 20/20、
  lint 0 findings、cmp_disasm 5 IDENTICAL + do_one_write 1 处锚符号注解差异（已复核，
  指令流逐条相同）。
- **批次 2d**：`--stop-after-w1` 两段式（借鉴 ghostlock-oneplus 的 W1 进程隔离）。
  cmp_disasm 同上结论。
- **两段式门禁 13+ cycle 数据**：段 1 W1 成功率 ~50% 且干净退出零 panic；段 2 每次
  走到 W2，主写与 repair 两发路由均 `success=1 status=0`（写入确实落下、repair 机制
  正常），但 **verify 全部静默失败**（无 `child uid` 行，child 不应答"C"探针）。
  c10 一轮连续 3 次 attempt 无 panic → 段 2 堆干净，问题从"回收命中"转为
  "写入后 child 不应答"（嫌疑：perf 泄漏 child_task 错误 / cred 偏移偏差 / child 被
  旁路杀死）。
- 已加 verify_w2_stage child 存活诊断（waitpid WNOHANG 状态码），待下一轮段 2 数据。
- dizi profile 覆写 `execution.stages.w2_attempts = 1`：失败的段 2 干净退出，
  外层循环直接重跑段 2（SELinux 仍 permissive），避免在脏堆上空转 15 次直到 panic。
