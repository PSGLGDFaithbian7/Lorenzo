# Lorenzo Task Engine V0.3 — 乙方(B, 30%) 控制面 RTL 交付

本目录是 **分工计划 §2 乙方(B)** 部分的 RTL 实现：控制面 + 配置/调试。
所有 datapath / FIFO / queue 实例属于甲方(A)，本目录不含任何算术。

> 计算次序基准：`lte_loop_nest_ctrl.sv` 严格沿用经过 review 的
> `document/u_loop_nest_control.sv`，仅做工程化整理与端口暴露，**未改动任何
> 计数/进位/last 判定次序**。

## 1. 文件与分工项对应

| 文件 | 分工项 | 说明 |
|------|--------|------|
| `lte_pkg.sv`            | —  | 共享包：常量、计数器位宽、错误码、token/ctx 结构体 |
| `lte_tdt_decode.sv`     | B5 | TDT 256-bit 解码 + 合法性检查（组合） |
| `lte_task_context.sv`   | B2 | 任务上下文锁存 + per-SA Lorenzo 选择 + active_sa_count |
| `lte_loop_nest_ctrl.sv` | B3 | 循环嵌套控制器（5 计数器 loop-carry，乙方核心） |
| `lte_boundary_ctrl.sv`  | B4 | 边界事件生成 + deq/drain token 打包 |
| `lte_task_dispatch.sv`  | B1 | 任务派发 FSM（busy 检查 / launch / start / done） |
| `lte_error_ctrl.sv`     | B8 | 错误聚合 + sticky halt + error_code |
| `lte_task_scoreboard.sv`| B6 | task 级 bitmap + pipeline level 寄存 |
| `lte_csr.sv`            | B7 | CSR 寄存器堆 + 计数器 debug snapshot |
| `lte_legacy_mux.sv`     | B9 | **[DEPRECATED]** Task / Legacy 控制源 2:1 选择，项目已全面转 V0.3，暂留不用 |
| `lte_task_ctrl_top.sv`  | —  | 控制面集成 wrapper（连 B1~B8，对外露 A 契约） |

## 2. 编译

包必须最先编译。已用 ModelSim `vlog -sv` 全量编译通过（0 error / 0 warning）。

```
vlib work
vlog -sv lte_pkg.sv lte_tdt_decode.sv lte_task_context.sv \
        lte_loop_nest_ctrl.sv lte_boundary_ctrl.sv lte_task_dispatch.sv \
        lte_error_ctrl.sv lte_task_scoreboard.sv lte_csr.sv \
        lte_legacy_mux.sv lte_task_ctrl_top.sv
```

## 3. 关键设计决策

### 3.1 片外预算（最重要约束）
所有需要 **除法 / 取模 / ceil** 的循环常量一律由 Host 片外算好，经 TDT 配置进来，
片上只做 `-1` 与等值比较：

- `qk_dim_group_count = dim/32`
- `qk_context_block_count = ceil(context_length/32)`
- `qk_context_tail_mask[31:0]`
- `pv_context_group_count = ceil(context_length/32)`
- `pv_last_inner_count`（最后一个 PV group 的有效 inner 数 1..32）

`lte_tdt_decode` 里出现的少量乘法/比较（`hp_parallel*head_dim==128` 等）只在
**TASK_START 那一拍**做一次性合法性检查，不在数据热路径上，不违反该约束。

### 3.2 loop-carry，不写大 FSM（微架构 §2.2）
`lte_loop_nest_ctrl` 每层只含 本层 counter + 本层等值比较 + 1-bit carry/end；
跨层组合链只传 1-bit。MAC 热路径只含 `inner/group`，`context/head` 由
`group_done_accept` 推进。`is_*_last` / `context_last_q` / `head_last_q` 做成寄存
predecode flag，token 打包只消费 1-bit。

### 3.3 last → end 的脉冲化
`last` 是计数器到值的电平；`end = last & 真实 fire`。下一层用 `end` 脉冲而非 `last`
电平启动，避免后级未接受时计数器空转（参考 .sv 已验证此次序）。

## 4. 甲乙方接口契约（分工计划 §4）

`lte_task_ctrl_top` 的端口即契约边界：

**乙 → 甲（控制 → 数据通路）**
- 配置：`task_ctx / task_mode / active_sa_count / use_input_lorenzo / use_output_lorenzo / valid_len`
- 启动：`task_start`
- 边界事件：`head_tile_start / row_start / group_start / group_done_pulse / row_done_pulse / head_tile_done_pulse / task_done_pulse`
- token：`deq_token_meta(+valid)`、`drain_token_meta(+valid, +drain_use_output_lorenzo, +drain_valid_len)`
- 计数器：`head/context/group/inner/drain_lane_ctr`（供 PV lane 映射 / debug）

**甲 → 乙（数据通路 → 控制）**
- `mac_fire / group_done_accept / drain_fire / engine_task_done`
- pipeline level：`partial_acc_bank_free / group_acc_bank_free / *_queue_level / stream_credit_*`

> token 中的 `partial_acc_bank_id / group_acc_bank_id` 属于甲方双 bank 逻辑，
> 由甲方在出队时补齐，故未放入 `*_meta_t` 结构体（结构体只含控制面字段）。

## 5. 执行模型：V0.3 vs V0.2（legacy 已废弃）

> 两版算的是同一个东西（同样的 SA 阵列 / dequant / Lorenzo 乘加），区别只在
> **谁来调度**：V0.2 用软件微码手动指挥每一步，V0.3 用硬件 task engine 自动跑。

| 维度 | V0.2 microcode（**已废弃**） | V0.3 Task Engine（**当前设计**） |
|------|------------------------------|----------------------------------|
| 循环切换 | 软件发 `LOOP_BEGIN/END`、显式进下一层 | 硬件计数器终止条件自动推进（本目录 B3/B4） |
| 读数窗口 | 软件发 `RECV_START_*` + `WAIT` | 外部按固定顺序持续喂数，ingress FIFO/line buffer 自动缓存 |
| 反量化/排出 | `SA_RUN_*` 内 `GROUP_DEQ`、`DRAIN_A/O` 占用 SA engine | dequant/drain 独立流水，与下一组 MAC 重叠 |
| 阶段同步 | 处处插 `WAIT SA_ENGINE` | 内部 token/credit/ready，软件只末尾 `TASK_WAIT` |
| 程序形态 | 几十条微指令逐步指挥 | `TASK_START` + `TASK_WAIT` 两条 |

**V0.2 用法（仅作对照，不再维护）：**
```text
for head:
  for context:
    RECV_START_K
    WAIT  K_RECV
    SA_RUN_QK count=dim
    WAIT  SA_ENGINE
    DRAIN_A
    WAIT  SA_ENGINE
```

**V0.3 用法（你/同事现在唯一要做的）：**
```text
; 启动前 host 一次性写好 TDT[id] + PE descriptor（见 §6）
TASK_START  task_id=0
TASK_WAIT   task_id=0
HALT
```
按下 `TASK_START` 后，循环推进 / 边界事件 / dequant / drain 全部由硬件完成，
软件不再插任何中间 `WAIT`。

**模式如何切换 / 为什么 mux 废弃：** `lte_legacy_mux`（B9）原本是 2:1 选择器，决定
共享 datapath 听 V0.3 还是 V0.2 的控制。现全面转 V0.3，该 mux 恒为 task 侧 = 无用，
故顶层 `lte_task_ctrl_top` 不实例化它，控制核直接驱动 datapath。

## 6. TDT 字段速查表（V0.3 启动唯一要填的输入）

TDT = `16 × 256-bit`，host 在 `TASK_START` 前写好；active task 期间不可改正在用的 entry。

| bit 区间 | 字段 | QK 填什么 | PV 填什么 |
|----------|------|-----------|-----------|
| [255:252] | `desc_type` | `0xD`（固定，否则报 `ILLEGAL_TASK_DESC`） | 同左 |
| [251:248] | `task_mode` | `0` | `1` |
| [247:240] | `flags` | 见下方 flags 表 | 见下方 flags 表 |
| [239:224] | `num_heads` | 总 head 数 | 同左 |
| [223:208] | `context_length` | K 行数 | P,V context 长度 |
| [207:192] | `dim` | QK reduction dim，**必须 32 倍数** | 不用（填 0） |
| [191:176] | `head_dim` | 不用 | PV 每 head dim，∈{32,64,128} |
| [175:168] | `group_size` | `32`（固定） | `32` |
| [167:160] | `SA_per_head` | 不用 | `head_dim/32`（1/2/4） |
| [159:152] | `Hp_parallel` | 不用 | `128/head_dim`（4/2/1） |
| [151:144] | `pe_desc_id` | 指向 PE_VALID_LEN_DESC | 同左 |
| [143:136] | `q_buffer_policy` | `0`=line-valid（推荐）/`1`=tile-ready | 同左 |
| [135:128] | `output_mode` | `0`=→softmax | `1`=→stream / `2`=→SRAM_QP(legacy) |
| [127:120] | `stream_contract` | `0`（canonical，固定） | `0` |
| [119:112] | `deq_prefill_hint` | deq FIFO 预填深度建议 | 同左 |
| [111:96] | `qk_dim_group_count` | **host 算好** `dim/32` | 不用（填 0） |
| [95:80] | `qk_context_block_count` | **host 算好** `ceil(context_length/32)` | 不用 |
| [79:48] | `qk_context_tail_mask` | **host 算好** 最后一个 block 的有效 lane，LSB=lane0；整除时填 `0xFFFFFFFF` | 不用 |
| [47:32] | `pv_context_group_count` | 不用 | **host 算好** `ceil(context_length/32)` |
| [31:26] | `pv_last_inner_count` | 不用 | **host 算好** 最后一组有效 inner 数 1..32；整除写 `32` |
| [25:18] | `last_head_count` | 最后一批 head 数，1..Hp_parallel，且不超过 `num_heads` | 同左 |
| [17:0] | reserved | 0 | 0 |

> ⚠️ 标 **host 算好** 的字段含除法/取模/ceil，**必须片外算好配置进来**，片上不算。

**flags[7:0]（ISA §3.1）：**
| bit | 名称 | 含义 |
|-----|------|------|
| [0] | `q_or_p_input_lorenzo` | 启用输入侧 Lorenzo 乘加（QK→Q_ACC / PV→P_ACC） |
| [1] | `input_lorenzo_full_pe_only` | 仅 valid_len=32 的 SA 用输入累加值 |
| [2] | `output_lorenzo` | 启用 drain 路径 output 乘加累加 |
| [3] | `output_lorenzo_full_pe_only` | 仅满 PE 的 SA 用输出累加值 |
| [4] | `qk_emit_to_softmax` | QK context block 完成自动 DRAIN_A→softmax |
| [5] | `pv_write_output` | PV head 完成自动 DRAIN_O→写 O |
| [7:6] | reserved | 0 |

**PE descriptor（128-bit，per-SA `{mask_mode[1b], valid_len[6b]}`，本实现按 8-bit/SA 对齐）：**
- `valid_len ∈ 0..32`，=32 即 full PE；`task_ctx.active_sa_count` 表示 full head tile 的 SA 数，top-level `active_sa_count` 表示当前 head tile 的 runtime SA 数。
- PV 合法配置下所有 active SA 都应 `valid_len=32`；非满 SA 主要留给 QK。

**两个填表实例：**
```text
QK, dim=128, context_length=96, num_heads=8（全 head 串行,Hp_parallel=1）:
  task_mode=0, dim=128, context_length=96, group_size=32,
  qk_dim_group_count=4            ; 128/32
  qk_context_block_count=3        ; ceil(96/32)
  qk_context_tail_mask=0xFFFFFFFF ; 96 是 32 整数倍 → 全 1
  flags: [0]=1(Q_ACC) [4]=1(→softmax)

PV, head_dim=64, context_length=33, num_heads=4:
  task_mode=1, head_dim=64, SA_per_head=2, Hp_parallel=2, context_length=33,
  pv_context_group_count=2        ; ceil(33/32)
  pv_last_inner_count=1           ; 33 = 32 + 1 → 最后一组只 1 个 inner
  flags: [0]=1(P_ACC) [5]=1(写 O)
```

## 7. 待集成 / 联调注意

- `lte_legacy_mux` 的 `legacy_*` 一侧需接 V0.2 `u_loop_ctrl/u_cmd_dispatch`（本次未交付）。
  `CTRL_W` 按集成时实际打包的控制总线宽度设定；模式仅在 `engine_busy=0` 时可切。
- `engine_task_done` 应由甲方/顶层在 drain/output 排空后给出，本控制核据此结束 RUN。
- TDT/PE descriptor 读口假设同步读、延迟 1 拍（IDLE 给地址、FETCH 取数据）。
- `wait_consume/wait_task_id` 由微码 `TASK_WAIT` 侧驱动以清 sticky done。

---

## 9. 甲乙方接口详解（供甲方对接用）

> 以下所有信号均位于 `lte_task_ctrl_top` 端口。甲方只需关注本节，不需要读控制核的内部实现。

---

### 9.1 信号总览

#### 乙方 → 甲方（控制 → 数据通路）

| 信号 | 方向 | 宽度 | 类别 | 说明 |
|------|------|------|------|------|
| `task_ctx` | B→A | struct | 配置 | 整个 task 的运行常量，`task_start` 后保持稳定直到下一个 task |
| `task_mode` | B→A | 2 | 配置 | `0=QK` / `1=PV`，来自 task_ctx |
| `active_sa_count` | B→A | 8 | 配置/运行态 | 当前 head tile 实际启用的 SA 数（1..4） |
| `valid_len[sa]` | B→A | 6/SA | 配置 | per-SA 有效 PE 数（0..32），静态，来自 PE descriptor |
| `use_input_lorenzo` | B→A | 1 | 动态 | 当前 block/group 是否启用输入侧 Lorenzo 乘加，随 block/group 变化 |
| `use_output_lorenzo` | B→A | 1 | 动态 | 当前 block/group 是否启用输出侧 Lorenzo 乘加 |
| `task_start` | B→A | 1 | 脉冲 | task 启动，1 拍，`task_ctx` 在此拍后才稳定可用 |
| `head_tile_start` | B→A | 1 | 脉冲 | 清 shared input ACC；QK 允许新 Q head tile 进入 Q buffer |
| `row_start` | B→A | 1 | 脉冲 | QK only：清 group_acc compute bank（新 context block 开始） |
| `group_start` | B→A | 1 | 脉冲 | 清 partial_acc MAC write bank（新逻辑 group 开始） |
| `group_done_pulse` | B→A | 1 | 脉冲 | partial_acc 完整，可送 dequant；同拍 `deq_token_valid` 有效 |
| `row_done_pulse` | B→A | 1 | 脉冲 | QK only：context block 完成，可 drain A；同拍 `drain_token_valid` 有效 |
| `head_tile_done_pulse` | B→A | 1 | 脉冲 | head tile 完成；PV 同拍 `drain_token_valid` 有效；QK 仅切换 head tile |
| `task_done_pulse` | B→A | 1 | 脉冲 | 整个 task MAC+dequant 循环完毕（drain 可能还未排空） |
| `deq_token_valid` | B→A | 1 | token | group_done 同拍有效，与 `group_done_pulse` 等价 |
| `deq_token_meta` | B→A | struct | token | dequant token 控制面字段（见 §9.3） |
| `drain_token_valid` | B→A | 1 | token | drain 可以开始时有效（QK=row_done，PV=head_tile_done） |
| `drain_token_meta` | B→A | struct | token | drain token 控制面字段（见 §9.3） |
| `head_ctr` | B→A | 6 | 计数 | 当前处理的 head 起始 id |
| `context_ctr` | B→A | 10 | 计数 | 当前 context block（QK）或不使用（PV） |
| `group_ctr` | B→A | 10 | 计数 | 当前 dim_group（QK）或 context_group（PV） |
| `inner_ctr` | B→A | 5 | 计数 | group 内步长（0..31） |
| `drain_lane_ctr` | B→A | 5 | 计数 | drain lane 计数（0..31），由 `drain_fire` 驱动 |

#### 甲方 → 乙方（数据通路 → 控制）

| 信号 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `mac_fire` | A→B | 1 | MAC 实际发射一拍。驱动 `inner_ctr` / `group_ctr` 推进 |
| `group_done_accept` | A→B | 1 | dequant 队列可以接受新 group-done token。**必须在 group 最后一个 inner beat 同拍为高**，否则该 beat 被憋住不发射 |
| `drain_fire` | A→B | 1 | drain 实际输出一拍，驱动 `drain_lane_ctr` 推进 |
| `engine_task_done` | A→B | 1 | 整个 task 完成（含 drain/output 排空）。控制核据此从 RUN 回到 IDLE |
| `partial_acc_bank_free` | A→B | 4 | per-SA partial_acc bank 空闲状态（scoreboard 采集） |
| `group_acc_bank_free` | A→B | 2 | group_acc 双 bank 空闲状态 |
| `deq_fifo_level` | A→B | 4 | dequant 参数 FIFO 当前深度 |
| `deq_token_queue_level` | A→B | 4 | dequant token 队列深度 |
| `drain_token_queue_level` | A→B | 4 | drain token 队列深度 |
| `output_queue_level` | A→B | 4 | output queue 深度 |
| `stream_credit_q/k/p/v` | A→B | 4×4 | ingress FIFO/line buffer 的 credit（scoreboard/CSR debug 用） |

---

### 9.2 关键时序

#### 9.2.1 task 启动序列

```
              task_launch  task_start
                   │           │
clk  ─┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──
      │  │  │  │  │  │  │  │  │  │
state │IDLE│FETCH│LAUNCH│START│    RUN ...
                         ↑     ↑
                    TDT 已锁存  loop_nest 计数器清零
                    task_ctx 稳定  boundary_ctrl 开始产生事件
```

- `task_launch` 在 LAUNCH 态单拍高：`lte_task_context` 在此拍锁存所有配置，`task_ctx` / `valid_len` / `flag_*_lz` 从**下一拍**起稳定。
- `task_start` 在 START 态单拍高：`loop_nest` 计数器在此拍清零；`group_start` / `head_tile_start` 在**同拍**随 `task_start` 拉高（初始边界事件），甲方在此拍执行首次 partial_acc 清零和 input ACC 清零。
- `task_ctx` 在 `task_start` 之前已稳定一拍，甲方可安全采样。

#### 9.2.2 QK MAC 热路径——group 边界

以 dim=64（dim_group_count=2）为例，1 个 context_block 内 2 个 group：

```
         group 0 (inner 0..31)           group 1 (inner 0..31)
                                   │
clk  ──┬─┬─┬─ ... ─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─ ... ─┬─┬─┬──
       │ │ │       │ │ │ │ │ │ │ │ │ │ │       │ │ │
mac_fire 1 1  ...  1 1 1 1 1 1 1 1 0 1 1  ...  1 1 1
inner_ctr 0 1 ...  29 30 31 0        29 30 31
group_ctr 0  0  .............  0     1  1  ........  1
                             │       │
               inner_last=1  │       │
               group_done_accept 必须=1 ──┘   (同拍)
               group_done_pulse=1
               deq_token_valid=1
               group_start=1 (次拍)  ──────────┘
               group_ctr 翻 1
```

**关键约束**：
- `inner_ctr == 31` 时（即 `is_inner_last=1`），该拍的 `mac_fire` 必须等到 `group_done_accept=1` 才真正发射（控制核内部：`mac_step_fire = mac_fire & (!inner_last | group_done_accept)`）。
- 若甲方 dequant token 队列满（`group_done_accept=0`），控制核**憋住**该 inner beat，`mac_fire` 不被消费，loop 不推进——这是唯一一种控制核 stall MAC 的机制。

#### 9.2.3 group_done → dequant token

```
clk  ───┬───┬───┬───┬───┬───┬───┬───
        │   │   │   │   │   │   │
mac_fire    ↑                        ; inner=31 且 accept=1
group_done_pulse  ↑                  ; 同拍
deq_token_valid   ↑                  ; 同拍（可直接推入甲方 deq token 队列）
deq_token_meta    ░░░░░░░             ; 同拍有效（含 last_group/last_ctx/last_head/lane_valid_mask）
group_start           ↑              ; 次拍：甲方清 partial_acc bank
group_ctr         0→1               ; 同拍更新（可见于 group_ctr_o）
```

- `deq_token_valid` 与 `group_done_pulse` 完全等价，甲方可选择其一。
- token meta 在 `deq_token_valid=1` 的那一拍有效，无需寄存（控制核内部已是组合输出）；若甲方队列需要 skid buffer，在队列入口寄一拍即可。

#### 9.2.4 row_done → drain token（QK context block 完成）

```
        最后一个 group (group_last=1) 被接受
        │
group_done_pulse=1, group_done_last_group=1
row_done_pulse=1           ; 同拍
head_tile_done_pulse=1 (若同时也是最后 context block)
drain_token_valid=1        ; 同拍（推入甲方 drain token 队列）
drain_token_meta           ; 同拍有效（含 lane_valid_mask / output_mode）
row_start=1                ; 下一个 context block 开始时（group_done_fire & ~task_done）
```

- QK 的 `row_done_pulse` 与 `head_tile_done_pulse` 在最后一个 context block 同拍；非最后 block 只有 `row_done_pulse`。
- PV 只有 `head_tile_done_pulse`（每个 head tile 完成），无 `row_done_pulse`。

#### 9.2.5 动态 `use_input_lorenzo` / `use_output_lorenzo`

两个信号是**组合输出**，在整个 context_block（QK）或 context_group（PV）内稳定，仅在 block/group 边界跳变：

```
        context block 0 (tail_mask=全1) │ context block N (tail_mask≠全1)
                                         │
use_input_lorenzo ──────────── 1 ────────┤─── 0 ───────────────────────
use_output_lorenzo ─────────── 1 ────────┤─── 0 ───────────────────────
```

- **甲方 MAC scheduler**：在每次 `mac_fire` 时看 `use_input_lorenzo` 决定送 Q_raw 还是 Q_ACC（P_raw 还是 P_ACC）。
- **甲方 drain scheduler**：在 drain 开始时看 `use_output_lorenzo` 决定 output_acc 是否使能；该值在整个 drain 过程中不变（drain 期间只跨 lane，不跨 block）。
- 两个信号对所有 active SA 相同（block/group 级判断，非 SA 级）。

---

### 9.3 Token 结构详解

#### `deq_token_meta_t`（group_done 时有效）

```
字段              宽度   说明
──────────────────────────────────────────────────────────
mode              1      0=QK / 1=PV
head_tile_id      6      = head_ctr，当前 head tile 起始 id
context_block_id  10     = context_ctr（QK 有效；PV 填 0）
group_id          10     = group_ctr（QK=dim_group，PV=context_group）
last_group        1      该 token 是当前 block/tile 的最后一个逻辑 group
last_ctx          1      QK: 该 context block 是当前 head tile 的最后一个
last_head         1      该 head tile 是整个 task 的最后一个
lane_valid_mask   32     QK 最后一个 context block 用 tail_mask；其余 / PV 全 1
```

**关键用途**：
- 甲方 dequant pipeline 从 token 里读 `last_*` flag 判断边界，**不得再回访 `context_ctr/head_ctr`** 做宽比较（spec 约束）。
- `lane_valid_mask` 随 token 传播到 dequant → group_acc → drain，保证无效 lane 不写入 group_acc 也不参与 drain。

#### `drain_token_meta_t`（row_done / head_tile_done 时有效）

```
字段              宽度   说明
──────────────────────────────────────────────────────────
mode              1      0=QK（→softmax）/ 1=PV（→O stream）
head_tile_id      6      当前 head tile id
context_block_id  10     QK: 当前 context block id（确定 group_acc bank 位置）
lane_valid_mask   32     QK tail block 的有效 lane；PV 全 1
output_mode       8      来自 TDT output_mode 字段（drain 落点）
```

> **注意**：token 里没有 `partial_acc_bank_id` / `group_acc_bank_id`——这两个字段属于甲方双 bank 管理逻辑，请在 deq/drain token 队列出队时由甲方侧补齐后再传递给后级。

---

### 9.4 边界事件与清零映射

| 事件 | 触发条件 | 甲方应执行的动作 |
|------|----------|------------------|
| `task_start` | TASK_START 启动后 | 无需单独响应；`group_start` + `head_tile_start` 同拍已触发 |
| `head_tile_start` | 每个新 head tile 开始 | 清 shared input ACC（QK: Q_ACC line；PV: P_ACC lane） |
| `row_start` | QK: 每个新 context block 开始 | 清 group_acc compute bank |
| `group_start` | 每个新逻辑 group 开始 | 清 partial_acc MAC write bank |
| `group_done_pulse` | group 最后一个 inner 被发射 | 推入 deq_token 到 dequant queue；swap partial_acc bank（若 deq bank 空闲） |
| `row_done_pulse` | QK: context block 的最后一个 group 被接受 | 推入 drain_token 到 drain queue |
| `head_tile_done_pulse` | 每个 head tile 完成 | PV: 推入 drain_token；QK/PV: 切换 head tile 上下文 |
| `task_done_pulse` | 最后一个 head tile 完成 | MAC 循环已结束；甲方继续把队列里剩余的 deq/drain token 排空，完成后拉 `engine_task_done` |

> `row_start` / `head_tile_start` / `group_start` 在 `task_start` 那一拍**同时**触发（初始清零），无需特殊处理。

---

### 9.5 `engine_task_done` 握手

这是控制核从 RUN 返回 IDLE 的唯一条件，**由甲方负责给出**：

```
task_done_pulse ─────────┐
                         │  MAC 循环结束
                         ↓
甲方：等待 deq_token_queue 排空
      等待 drain_token_queue 排空
      等待 output_queue 排空（最后一笔结果送出 out_if）
                         ↓
engine_task_done ────────┐  （1 拍脉冲）
                         ↓
控制核状态：RUN → IDLE，engine_busy 清零，task_done[id] 置 1
```

- 若甲方提前拉高 `engine_task_done`（队列未清空），后续 token 会丢失。
- 若甲方不拉 `engine_task_done`，控制核永远卡在 RUN，下一个 `TASK_START` 会被 busy 拒绝。

---

### 9.6 计数器使用说明

| 计数器 | 有效范围 | 典型用途 |
|--------|----------|----------|
| `head_ctr` | 0..num_heads-1，步长 hp_parallel | PV lane 映射：`head_id = head_ctr + hp_id` |
| `context_ctr` | 0..qk_context_block_count-1 | QK: 定位当前 context block（debug / drain addr） |
| `group_ctr` | 0..group_max-1 | QK=dim_group index；PV=context_group index |
| `inner_ctr` | 0..31（PV 最后 group 可短） | 用于 `d = group_ctr*32 + inner_ctr` |
| `drain_lane_ctr` | 0..31，由 drain_fire 驱动 | output_acc 逐 lane 分时复用的地址 |

计数器在 `task_start` 那一拍清零，仅在对应 fire 脉冲时推进，不会空转。

---

## 8. 单元验证建议（对应 spec §9 / 分工计划 Verification Plan）

- `lte_loop_nest_ctrl`：counter rollover、carry 传播、QK tail mask、PV `pv_last_inner_count`
  提前闭合、禁止长组合链（SVA 断言）。
- `lte_tdt_decode`：9 种错误码全枚举。
- `lte_task_dispatch`：busy 拒绝 / wait_on_launch 挂起 / 合法启动三条路径。
- `lte_boundary_ctrl`：6 类事件相位、token last 字段、QK/PV 模式差异。
