# 微指令 ISA V0.3 — Task Engine / 配置式流执行草案

> 版本：**V0.3 draft (Task Engine)**。  
> 目标：在 V0.2 的 `RECV/SA_RUN/DRAIN/WAIT/LOOP` 基础上，增加类似 TPU 的
> “简单执行控制 + 运行参数配置”模式。V0.2 指令保留用于 bring-up、debug 和小规模
> 实验；V0.3 的主执行路径是 `TASK_START` 启动一个硬件任务控制器，由任务描述符驱动
> QK/PV 的 head/context/group/inner 多层循环、反量化触发、Lorenzo 乘加累加选择和输出排出。
> 外界负责按约定顺序直接供给数据、累加因子与反量化参数；本加速器是**纯计算/流吞吐 engine**，
> 不包含 AGU，不负责地址生成，不支持可变精度。

---

## 0. 对 V0.2 的结论性评审

### 0.1 三层循环是否已经支持

V0.2 **可以用微码 LOOP 写出三层循环**，因为它有 4 个 loop counter 和 4 深 loop stack。
例如 QK 可以表达：

```text
for head:
  for context:
    SA_RUN_QK count=dim      ; 内部又执行 group_count=count/32 与 inner=0..31
    DRAIN_A
```

PV 也可以表达：

```text
for head:
  SA_RUN_PV count=context_length
  DRAIN_O
```

其中 `SA_RUN_QK/PV` 已经在指令内部支持：

- 32 步一组的 MAC；
- 每组结束触发反量化；
- group accumulator；
- `is_lorenzo` / `lorenzo_full_pe_only` 控制输入累加值选择；
- `DRAIN_A/O` 上的 output accumulator。

但这只是 **指令级循环**，不是完整的 **配置式任务循环**。V0.2 的 LOOP counter 不直接驱动
head/context/group 的自动切换，也不会自动消费“下一组反量化参数”或自动判定何时从
QK context block 切到下一 block、何时从 PV 的一个 head tile 切到下一个 head tile。因此如果希望
一次配置后由硬件自己完成多层循环推进，V0.2 仍然不够。

### 0.2 是否像 TPU 一样是“简单控制 + 运行参数配置”

V0.2 只做到了一半。它的 `SA_RUN_*` 已经比 CPU 指令更粗粒度，但程序仍然像一个
microcoded CPU：

- 微码显式发 `SET_PHASE`、`RECV_START_*`、`SA_RUN_*`、`DRAIN_*`、`WAIT`；
- 软件决定何时进入下一层循环；
- 软件决定何时重新发接收窗口；
- 硬件缺少任务级 loop generator 和 stream contract scheduler；
- 数据源、反量化参数和输出时序没有统一的 task descriptor。

所以 V0.2 适合 RTL 原型和 testbench bring-up，但若目标是 TPU 风格执行，应升级为
**Task Descriptor + Task Engine**。

### 0.3 读数和计算之间是否还有等待区间

V0.2 已经允许 receiver 与 SA engine 并行，K/V/P FIFO 可以让计算边读边做。但它仍有以下
结构性间隙：

- Q 是 SRAM ping-pong，`SA_RUN_QK` 需要选中 READY buffer，不能从半填充 Q buffer 细粒度开始；
- `SA_RUN_*` 的 `GROUP_DEQ` 可能停住 SA engine，V0.2 只预取反量化参数，不保证反量化本身与下一组 MAC 重叠；
- `DRAIN_A/O` 仍挂在 SA_ENGINE，同一 engine busy 时不能同时发下一次 `SA_RUN_*`；
- 同一 receiver 不支持多 outstanding 窗口，连续 context/head 时可能出现重启窗口的气泡；
- `WAIT` 虽可少用，但微码仍负责阶段边界同步。

V0.3 的目标不是消灭物理 backpressure。如果外部带宽不足，计算必然会停。但 V0.3 要消灭
**软件调度造成的 read -> compute -> read 交替气泡**，把它变成硬件流水线内的 credit/ready 问题。

---

## 1. V0.3 执行模型

V0.3 同时支持两种模式：

| 模式 | 用途 | 控制粒度 |
|------|------|----------|
| Legacy Microcode Mode | V0.2 兼容、debug、局部验证 | `RECV/SA_RUN/DRAIN/WAIT/LOOP` |
| Task Engine Mode | 正常高吞吐执行 | `TASK_START task_id` + task descriptor |

Task Engine Mode 中，一段常规程序可以短到：

```text
TASK_START  task_id=0
TASK_WAIT   task_id=0
HALT
```

所有运行参数由 Host 在启动前写入：

- Task Descriptor Table (TDT)
- PE mask / valid_len descriptor
- 固定流接口配置（由 ISA 约定，而不是独立 descriptor）

任务启动后，硬件自己维护：

- `head_ctr`
- `context_ctr`
- `group_ctr`
- `inner_ctr`
- `drain_lane_ctr`
- FIFO / buffer credit
- Lorenzo input mulacc clear/update
- output mulacc clear/update
- group boundary 和 row boundary 判断

### 1.1 固定数据类型

V0.3 task mode 不支持可变精度。数据类型固定如下：

- `Q`：FP8
- `P`：FP8
- `K`：FP4
- `V`：FP4
- `input_acc_factor`：FP8
- `output_acc_factor`：FP8
- 反量化参数 `{w0,w1}`：FP16
- `partial_acc`：FP16
- `group_acc/final_acc/output_acc`：FP16

ISA 中不再出现 `data_format`、`param_format` 一类可变格式字段。

---

## 2. 新增 Opcode

V0.2 中 `0x11..0x1F` 保留。V0.3 使用其中一部分：

| Code | Mnemonic | 说明 |
|------|----------|------|
| 0x11 | `TASK_START` | 从 TDT 启动一个任务 |
| 0x12 | `TASK_WAIT` | 等待指定 task 完成 |
| 0x13 | `TASK_STOP` | debug/bring-up 用，停止当前 task |
| 0x14 | `TASK_STATUS_SNAPSHOT` | debug 用，把 task counters 快照到 CSR |
| 0x15..0x1F | reserved | 保留 |

### 2.1 `TASK_START`

沿用 48-bit 指令格式：

```text
opcode = 0x11
desc_id[39:36] = task_id        ; TDT index 0..15
count = 0
subcmd[0] = start_mode          ; 0=normal, 1=debug single-step group
flags[0] = wait_on_launch       ; 1=若 task engine busy，则指令停住直到可发射
其他字段必须为 0
```

语义：

```text
if task_engine_busy:
    if wait_on_launch: stall
    else: HALTED_ERROR(TASK_ENGINE_BUSY)
fetch TDT[task_id]
检查 descriptor 合法性
锁存 task context
启动 u_task_engine
PC++
```

### 2.2 `TASK_WAIT`

```text
opcode = 0x12
desc_id[39:36] = task_id
其他字段必须为 0
```

语义：

```text
while task_done[task_id] == 0:
    stall
task_done[task_id] = 0
PC++
```

`TASK_WAIT` 只同步任务完成，不同步每个内部 stage。内部 stage 的同步由 task engine 的
credit/ready 和 token 队列完成。

### 2.3 `TASK_STOP`

仅用于 debug，不是高吞吐路径：

```text
opcode = 0x13
desc_id = task_id
```

语义：请求 task engine 在当前 group boundary 停止，并设置 `task_stopped` CSR。不会做复杂恢复。

---

## 3. Task Descriptor Table (TDT)

TDT 建议为 `16 x 256-bit`。Host 在 `csr_start` 前写入，active task 期间不可修改正在使用的
entry。它是**标准化输入配置格式**，不是通用寻址描述符。字段如下：

```text
[255:252] desc_type          = 0xD
[251:248] task_mode          0=QK, 1=PV, 2=ATTN_QK_PV_FUSED(保留), 其他非法
[247:240] flags
[239:224] num_heads          总 head 数
[223:208] context_length     QK 的 K 行数 / PV 的 P,V context 长度
[207:192] dim                QK reduction dim，必须为 32 的倍数
[191:176] head_dim           PV 每 head 的 dim 并行宽度；必须 >=32、32 对齐且整除 PE_NUMBER
[175:168] group_size         必须为 32
[167:160] SA_per_head        PV: 必须等于 head_dim / 32
[159:152] Hp_parallel        PV: 必须等于 PE_NUMBER / head_dim
[151:144] pe_desc_id         指向 PE_VALID_LEN_DESC
[143:136] q_buffer_policy    0=line-valid ping-pong, 1=tile-ready ping-pong
[135:128] output_mode        0=QK->softmax, 1=PV->stream_out, 2=PV->SRAM_QP(legacy)
[127:120] stream_contract    0=固定 canonical 顺序
[119:112] deq_prefill_hint   反量化参数 FIFO 建议预填深度
[111:96]  qk_dim_group_count       QK: dim/32，Host 预先算好
[95:80]   qk_context_block_count   QK: ceil(context_length/32)，Host 预先算好
[79:48]   qk_context_tail_mask     QK: 最后一个 context block 的有效 lane，LSB 对应 lane0
[47:32]   pv_context_group_count   PV: ceil(context_length/32)，Host 预先算好
[31:26]   pv_last_inner_count      PV: 最后一个 context group 的有效 inner 数，1..32；整除时写 32
[25:0]    reserved / implementation-defined extension
```

这些 count/mask 字段的目的不是让硬件重新推导形状，而是把 Host 已经编排好的循环边界标准化输入。
硬件在运行期只消费这些锁存后的配置：

- QK：`qk_dim_group_count` 控制 dim 方向的完整 32-cycle reduction group；
  `qk_context_block_count` 控制 32-lane context block 数；只有最后一个 context block 使用
  `qk_context_tail_mask`，其余 block 固定视为 `32'hFFFF_FFFF`。
- PV：`pv_context_group_count` 控制 context reduction group 数；最后一个 group 的 inner 计数
  由 `pv_last_inner_count` 决定，不需要 lane mask。PV 的 lane 始终用于 dim 并行，合法配置下不会出现
  空闲 SA lane。

PV 固定 `PE_NUMBER = 128`。在 PV task 中，硬件要求：

```text
head_dim >= 32
head_dim % 32 == 0
PE_NUMBER % head_dim == 0
SA_per_head * 32 == head_dim
Hp_parallel * head_dim == PE_NUMBER
```

也就是说，PV 阶段总是把 128 个 PE lane 全部用于 `Hp_parallel` 个 head 的 dim 并行。
当 `head_dim=128` 时 `Hp_parallel=1`；`head_dim=64` 时 `Hp_parallel=2`；
`head_dim=32` 时 `Hp_parallel=4`。因为 `head_dim` 最小为 32 且 32 对齐，不会出现
一个 SA 被拆给多个 head 的情况。若模型逻辑维度不是该集合，外部应按固定流契约补齐到合法
`head_dim` 后供数。

### 3.1 TDT flags

```text
flags[0]  q_or_p_input_lorenzo        ; 启用 shared input mulacc：QK 使用 Q_ACC，PV 使用 P_ACC
flags[1]  input_lorenzo_full_pe_only
flags[2]  output_lorenzo              ; DRAIN 路径使用 output mulacc accumulator
flags[3]  output_lorenzo_full_pe_only
flags[4]  qk_emit_to_softmax
flags[5]  pv_write_output
flags[7:6] reserved
```

合法组合：

- QK：若 `qk_emit_to_softmax=1`，QK context block 完成后自动 DRAIN_A 到 softmax。
- PV：若 `pv_write_output=1`，PV head 完成后自动 DRAIN_O / 写 O。
- dequant、group accumulation 在 task mode 中默认启用，不再通过 ISA 开关控制。
- QK 与 PV 不会同时运行，因此 QK 的 Q 输入累加和 PV 的 P 输入累加分时复用同一个
  shared input mulacc accumulator。`task_mode` 决定该 accumulator 当前输出 `Q_ACC` 还是 `P_ACC`。

---

## 4. 固定流接口契约

Task mode 不使用 SDT，也不使用地址/stride。所有输入输出都走**三组共享固定端口**，外界按照
约定顺序供数。硬件只维护“现在正在算到哪个 `head/context/group/inner`”。

共享接口定义：

- `qp_if`：QK mode 传 `Q`，PV mode 传 `P`
- `kv_if`：QK mode 传 `K`，PV mode 传 `V`
- `input_factor_if`：QK mode 传 Q_ACC 因子，PV mode 传 P_ACC 因子
- `output_factor_if`：DRAIN 路径传 output_acc 因子
- `out_if`：QK mode 传 `A`（送 softmax），PV mode 传 `O`

因为 QK/PV 不会同时计算，所以这些接口可安全分时复用。factor 流也是标准化输入流，
不是地址描述符；外界必须保证它与对应 raw 数据同拍、同 lane 对齐。

文中 `active_sa_count` 表示当前 task 实际启用的 SA 数（1..4）。

这意味着外界不需要知道内部算到了第几个 group，只需要遵守一个更直接的规则：

- 当且仅当你送出一个新的 `Q`/`P` raw beat 时，同拍送出它对应的 `input factor` beat
- 当且仅当硬件正在 drain 一个新的输出 lane 时，同拍送出该 lane 对应的 `output factor` beat

若硬件还没准备好，它会通过 `ready` 拉低让外界暂停；外界不需要自己推断内部计数器。

### 4.1 QK 输入顺序

对当前 head tile `H .. H+Hp_parallel-1`：

- **QP 共享流**：在 QK mode 下表示 `Q`，按 `d = 0 .. dim-1` 顺序输入并可缓存在
  Q line buffer 中；每拍送 `active_sa_count` 个 FP8 标量，每个 active SA 消费 1 个 Q scalar
- **input factor 流**：与 QP 共享流同拍输入，每拍送 `active_sa_count` 个 FP8 因子；
  每个 active SA 消费 1 个 factor
- **KV 共享流**：在 QK mode 下表示 `K`。SA 是 `1x32 output-stationary`，因此 K 的
  32 个 lane 对应同一个 `context_block` 内的 32 个 context offset。K beat 顺序为
  `context_block -> dim_group -> inner`，每拍送当前 active SA/PE 所需的 FP4 lanes

因此逻辑顺序是：

```text
for head_tile:
  Q stream: d-major
  for context_block in 0 .. qk_context_block_count-1:
    for dim_group in 0 .. qk_dim_group_count-1:
      for inner in 0 .. 31:
        K stream: K(context_block*32 + lane, dim_group*32 + inner)
```

Q 可以提前输入并缓存在 Q ping-pong / line buffer 中；K 是边输边算的主流。
因此 QK 的 input factor 也按同一个 `Q stream: d-major` 顺序提前送入并缓存/锁步消费。
最后一个 `context_block` 可能不足 32 个有效 context，硬件只在该 block 使用
`qk_context_tail_mask` 抑制无效 lane 的 MAC 写入、group_acc、drain 和 output factor 消费；中间 block
固定视为 32 lane 全有效。

### 4.2 PV 输入顺序

对当前 head tile `H .. H+Hp_parallel-1`：

- **QP 共享流**：在 PV mode 下表示 `P`，按 `t = 0 .. context_length-1` 顺序输入，每拍送
  `Hp_parallel` 个 FP8 标量
- **input factor 流**：与 QP 共享流同拍输入，每拍送 `Hp_parallel` 个 FP8 因子：
  `FP(H+0,t), FP(H+1,t), ...`
- **KV 共享流**：在 PV mode 下表示 `V`，按 `t = 0 .. context_length-1` 顺序输入，每拍送
  一个固定 V beat。该 beat
  含 `PE_NUMBER=128` 个 FP4 lane，排列为 `Hp_parallel` 个连续 head chunk，每个 chunk
  长度为 `head_dim`

因此逻辑顺序是：

```text
for head_tile:
  for context:
    input P(t) and V(t, lane[0..127])
```

PV lane 映射：

```text
flat_lane = 0 .. 127
hp_id     = flat_lane / head_dim
dim_id    = flat_lane % head_dim
head_id   = H + hp_id
```

因此 PV 是 **dim 并行、context_length 分时累加**：同一个 context token 到来时，所有
128 个 PE lane 同时覆盖 `Hp_parallel` 个 head 的 dim 方向。
因此 PV 的 input factor 顺序与 P 完全一致，不跟 `head_dim` 再展开第二层。

### 4.3 输出顺序

- **共享 `out_if` 在 QK mode 下**：按 `head_tile -> context_block -> drain_lane` 顺序输出
- **共享 `out_if` 在 PV mode 下**：按 `head_tile -> drain_lane` 顺序输出
- **output factor 流**：与 DRAIN 顺序同拍输入。QK/PV 都按 `drain_lane=0..31`
  顺序给每个 active SA 一个 FP8 因子，供 output accumulator 执行乘加。

更具体地说：

- QK：当某个 `context_block` 开始 drain 时，外界按有效 lane 连续送 `output factor`，
  第 `n` 拍对应 `drain_lane=n`；若这是最后一个 partial block，mask 为 0 的 lane 不要求送 factor
- PV：当某个 `head_tile` 开始 drain 时，外界连续送 32 拍 `output factor`，第 `n` 拍对应
  `drain_lane=n`

`output_mode` 仅决定输出落点，不改变内部计算顺序。

### 4.4 Lorenzo 乘加累加语义

输入侧 Lorenzo 不再是纯前缀加法，而是：

```text
input_acc += raw_qp_fp8 * input_acc_factor_fp8
```

输出侧 Lorenzo 不再是纯前缀加法，而是：

```text
output_acc += raw_output_fp16 * output_acc_factor_fp8
```

累加状态仍为 FP16。`flags[0]` / `flags[2]` 只决定下游是否选择 accumulated 结果；
硬件维护累加状态时必须按上述乘加规则更新。若对应 factor 流缺数，硬件通过 ready/valid
反压对应 raw 流或 drain 路径。

---

## 5. 反量化参数输入契约

Task mode 不使用 DDT，也不从片内参数 SRAM 取 `w0/w1`。反量化参数从外部直接输入，格式固定
为两个 FP16：

```text
deq_param = {w0_fp16, w1_fp16}
```

### 5.1 QK 参数顺序

QK 中，每个逻辑 group 都需要一个 `deq_param`，顺序为：

```text
for head_tile:
  for context_block in 0 .. qk_context_block_count-1:
    for dim_group in 0 .. qk_dim_group_count-1:
      input {w0,w1}
```

### 5.2 PV 参数顺序

PV 中，每个逻辑 group 都需要一个 `deq_param`，顺序为：

```text
for head_tile:
  for context_group in 0 .. pv_context_group_count-1:
    input {w0,w1}
```

参数可以提前输入到内部 dequant FIFO。到 `group_done` 时，硬件从 FIFO 头部取出当前 group
对应的 `{w0,w1}`。若 FIFO 为空，则 dequant 流水停顿并向前反压。

---

## 6. PE_VALID_LEN_DESC

保留 V0.2 的 compact valid_len 方案：

```text
per SA: {mask_mode[1b], valid_len[6b]}
valid_len = 0..32
mask_mode=0 表示 LSB 连续 mask
```

Task engine 每个 head tile 根据 `SA_per_head`、`Hp_parallel`、`valid_len` 生成：

```text
full_pe_active[sa] = (valid_len[sa] == 32)
use_input_lorenzo[sa] =
    flags.input_lorenzo && (!flags.input_lorenzo_full_pe_only || full_pe_active[sa])
use_output_lorenzo[sa] =
    flags.output_lorenzo && (!flags.output_lorenzo_full_pe_only || full_pe_active[sa])
```

PV task mode 下，`head_dim` 按 32 对齐且 `Hp_parallel * head_dim == PE_NUMBER`，所以
所有被 PV 使用的 SA 都应是 full PE (`valid_len=32`)。`valid_len` 主要保留给 QK、legacy
模式或外部补齐场景下的调试检查。

---

## 7. Task 内部循环语义

### 7.1 QK Task

```text
for h in 0 .. num_heads-1 step Hp_parallel:
  prefetch/load Q for active head tile
  for cb in 0 .. qk_context_block_count-1:
    context_mask = (cb == qk_context_block_count-1) ? qk_context_tail_mask : 32'hFFFF_FFFF
    clear group_acc for active SAs and valid context lanes
    for g in 0 .. qk_dim_group_count-1:
      clear partial_acc
      for i in 0 .. 31:
        d = g*32 + i
        consume Q(h,d), input_acc_factor(h,d) and K(h, cb*32+lane, d)
        Q_ACC(h,d) += Q(h,d) * input_acc_factor(h,d)
        for each lane where context_mask[lane] == 1:
          partial_acc[lane] += Q_selected * K[lane]
      dequant(partial_acc, w0/w1(h,cb,g))
      group_acc[valid lanes] += dequant_result[valid lanes]
    final_acc = group_acc
    if qk_emit_to_softmax:
      drain A context block to softmax, consuming output_acc_factor(h,cb,drain_lane) for valid lanes
```

硬件判断：

- `i==31`：关闭当前 group，发起 dequant；
- `g==qk_dim_group_count-1`：当前 context block 完成，进入 DRAIN_A；
- `cb==qk_context_block_count-1`：当前 head tile 的 QK 完成；
- `context_mask` 只在最后一个 context block 可能不是全 1，其余 block 必须按全 32 lane 处理；
- `h + Hp_parallel >= num_heads`：task 完成。

### 7.2 PV Task

```text
for h in 0 .. num_heads-1 step Hp_parallel:
  clear shared input accumulator in PV mode
  clear group_acc for active SAs
  for g in 0 .. pv_context_group_count-1:
    inner_limit = (g == pv_context_group_count-1) ? pv_last_inner_count : 32
    clear partial_acc
    for i in 0 .. inner_limit-1:
      t = g*32 + i
      consume P(H+hp_id,t), input_acc_factor(H+hp_id,t) and V(H+hp_id,t,dim_id)
      update P raw/acc lanes with P_ACC += P * input_acc_factor
      partial_acc += P_selected * V
    dequant(partial_acc, w0/w1(h,g))
    group_acc += dequant_result
  final_acc = group_acc
  if pv_write_output:
    drain O vector to output stream/SRAM, consuming output_acc_factor(h,drain_lane) if output mulacc enabled
```

硬件判断：

- `i==inner_limit-1`：关闭当前 context reduction group，发起 dequant；
- `g==pv_context_group_count-1`：PV head tile 完成，进入 DRAIN_O；
- PV 不使用 lane mask 处理 context tail；tail 只改变最后一个 context group 的 inner 计数长度；
- `h + Hp_parallel >= num_heads`：task 完成。

---

## 8. 流水线契约

Task Engine Mode 下，软件不再在读数和计算之间插 `WAIT`。内部采用 token/credit：

```text
LoopGen -> Ingress Buffers + Input Factor -> Shared Input MulAcc -> SA MAC
        -> Dequant Queue -> Group Accumulator -> Drain + Output Factor -> Output MulAcc/Output
```

每级都有 valid/ready。循环计数器只在 token 被下一级接受时推进。若外部带宽不足或 softmax
不 ready，backpressure 会传播；这不是 ISA 级等待，也不要求软件发下一条 `RECV_START`。

关键规则：

- Q/K/V/P ingress FIFO 或 Q line buffer 可提前缓存若干 token；
- input factor 与 Q/P raw 锁步消费，缺数时反压 Q/P ingress；
- dequant 参数至少提前一组预取；
- MAC group 与上一组 dequant 应允许重叠；
- output factor 与 DRAIN raw output 锁步消费，缺数时反压 drain；
- DRAIN row/vector 与下一 row/head 的 MAC 应允许重叠；
- 当 output queue 满时，才允许反压 compute；
- `TASK_WAIT` 只等待最终 task_done。

---

## 9. 错误条件

新增错误码：

| 条件 | 错误 |
|------|------|
| TDT desc_type 非 0xD | ILLEGAL_TASK_DESC |
| task_mode 非法 | ILLEGAL_TASK_MODE |
| task engine busy 且 `wait_on_launch=0` | TASK_ENGINE_BUSY |
| group_size 非 32 | ILLEGAL_GROUP_SIZE |
| QK dim 不是 32 的倍数 | ILLEGAL_DIM |
| context_length 为 0、配置的 context group/block count 为 0、`qk_context_tail_mask==0`、或 `pv_last_inner_count` 不在 1..32 | ILLEGAL_CONTEXT |
| 若实现选择做一致性检查：Host 配置的 `qk_context_block_count/qk_context_tail_mask/pv_context_group_count/pv_last_inner_count` 与 `context_length` 不匹配 | ILLEGAL_CONTEXT |
| PV 映射不满足 `head_dim>=32`, `head_dim%32==0`, `Hp_parallel*head_dim==128`, 或 `SA_per_head*32==head_dim` | ILLEGAL_PV_MAP |
| stream_contract 非法 | ILLEGAL_STREAM_CONTRACT |
| output/softmax backpressure 超过实现允许的 debug threshold | TASK_BACKPRESSURE_DEBUG |

默认仍不需要复杂 retry、ECC 或异常恢复。

---

## 10. 推荐微码例程

### 10.1 QK 单任务

```text
; Host 预先写 TDT[0], PE desc
TASK_START  desc_id=0
TASK_WAIT   desc_id=0
HALT
```

### 10.2 PV 单任务

```text
; Host 预先写 TDT[1], PE desc
TASK_START  desc_id=1
TASK_WAIT   desc_id=1
HALT
```

### 10.3 QK 后接 PV

```text
TASK_START  desc_id=0      ; QK task，输出到 softmax/P stream
TASK_WAIT   desc_id=0
TASK_START  desc_id=1      ; PV task，消费 P/V，输出 O
TASK_WAIT   desc_id=1
HALT
```

后续 V0.4 可增加 fused attention task，使 QK/softmax/PV 之间也由同一个 task graph
控制，减少 task boundary。

---

## 11. 与 V0.2 的迁移关系

| V0.2 机制 | V0.3 替代 |
|-----------|-----------|
| `LOOP_BEGIN/END` 管 head/context | TDT shape + `u_loop_nest_ctrl` |
| `RECV_START_* count` | 固定外部流接口 + ingress FIFO/line buffer |
| `SA_RUN_QK count=dim` | QK task 内部 `dim/group/inner` counters |
| `SA_RUN_PV count=context_length` | PV task 内部 `context/group/inner` counters |
| `DRAIN_A/O` 显式指令 | row/vector 完成后自动 drain |
| `WAIT SA_ENGINE` | 内部 credit/ready；外部只 `TASK_WAIT` |
| `desc_id+1` 找 dequant desc | 外部 `deq_param` 流按固定顺序输入 |
| 软件决定何时切换循环 | 硬件根据 counter terminal 条件切换 |

结论：V0.3 保留 V0.2 的算子语义，但把调度责任从微码迁移到 task engine。这更符合
“简单执行控制 + 运行参数配置”的加速器 ISA 目标。
