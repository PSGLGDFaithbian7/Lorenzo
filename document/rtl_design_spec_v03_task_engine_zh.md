# Lorenzo Task Engine V0.3 RTL Design Spec

> 文档目的：为后续 RTL 工程师提供可直接开工的模块级设计规格。  
> 适用版本：基于 `microinstruction_isa_v03_task_engine_zh.md` 与
> `microarchitecture_v03_task_engine_zh.md` 当前版本。  
> 设计定位：**纯流式计算 engine**，无 AGU、无地址生成、无可变精度。外部按规定顺序供给
> Q/K/P/V/反量化参数以及累加因子；内部负责循环推进、缓存、乘加累加、反量化、排出和 backpressure。

---

## 1. 设计总览

### 1.1 固定常量

```text
NUM_SA              = 4
PE_PER_SA           = 32
PE_NUMBER           = 128
GROUP_SIZE          = 32
Q_FORMAT            = FP8
P_FORMAT            = FP8
K_FORMAT            = FP4
V_FORMAT            = FP4
DEQ_PARAM_FORMAT    = 2 x FP16
INPUT_FACTOR_FORMAT = FP8
OUTPUT_FACTOR_FORMAT= FP8
PARTIAL_ACC_FORMAT  = FP16
GROUP_ACC_FORMAT    = FP16
OUTPUT_ACC_FORMAT   = FP16
```

### 1.2 功能范围

支持两类 task：

- `QK`：dim reduction 分组计算，`1x32` SA lane 覆盖 context block
- `PV`：dim 并行 / context_length 分时累加

不支持：

- AGU / 地址生成
- 乱序
- 多 task 并发执行
- 可变精度
- 运行中 descriptor 修改
- 异常恢复 / retry

### 1.3 顶层数据流

```text
TASK_START
  -> Task Context Latch
  -> Loop Nest Controller / Boundary Controller
  -> Ingress Buffers
  -> Shared Input MulAcc
  -> MAC Scheduler / SA Array
  -> Dequant Pipeline / Group Accumulator
  -> Drain Scheduler / Output MulAcc / Output Queue
  -> Softmax Out or O Stream Out
  -> TASK_DONE
```

新增压缩算法乘法不并入 SA PE 的 `scalar * vector` MAC。它们属于两个独立乘加域：

- `input_mulacc`：位于 `lte_input_acc_shared` 内，执行 `Q/P * input_factor + acc`
- `output_mulacc`：位于 `lte_output_acc` 内，执行 `raw_output * output_factor + acc`

资源配置按 SA 标量输入节拍确定，不按 32 个 PE lane 盲目复制：

- QK：每个 active SA 1 个 input mulacc
- PV：每个 active head 1 个 input mulacc，P/P_ACC scalar 广播给该 head 占用的 `SA_per_head` 个 SA
- QK/PV drain：每个 active SA 1 个 output mulacc

上述单元都沿时间轴分时复用，不在一个 SA 内复制 32 份。
`active_sa_count` 表示当前 head tile 实际启用的 SA 数，范围 1..4。

---

## 2. 顶层模块划分

建议 RTL 层级：

```text
lorenzo_task_engine_top
├─ lte_csr
├─ lte_task_dispatch
├─ lte_task_context
├─ lte_loop_nest_ctrl
├─ lte_boundary_ctrl
├─ lte_qp_ingress
├─ lte_kv_ingress
├─ lte_deq_param_ingress
├─ lte_input_acc_shared
├─ lte_mac_scheduler
├─ lte_sa_array (4 x 1x32 output-stationary SA, with partial_acc banks)
├─ lte_dequant_pipe
├─ lte_group_acc_bank
├─ lte_drain_scheduler
├─ lte_output_acc
├─ lte_output_queue
├─ lte_out_stream
└─ lte_error_ctrl
```

---

## 3. 顶层接口定义

### 3.1 时钟复位

```text
input  logic clk
input  logic rst_n
```

同步设计，低有效复位。所有状态寄存器在 `rst_n=0` 时清零。

### 3.2 Host/CSR 接口

最小集合：

```text
input  logic        csr_start
input  logic [3:0]  csr_task_id

output logic        csr_busy
output logic        csr_halted_done
output logic        csr_halted_error
output logic [7:0]  csr_error_code

output logic [15:0] csr_task_busy
output logic [15:0] csr_task_done
output logic [15:0] csr_task_error
```

TDT / PE descriptor 由 host 在启动前写入片内寄存器或 RAM。写口实现方式由 SoC 环境决定，
本 spec 不约束总线协议，只要求最终可读出稳定配置。

### 3.3 Task Descriptor 配置接口

建议使用简化 RAM 形式：

```text
input  logic        tdt_we
input  logic [3:0]  tdt_waddr
input  logic [255:0]tdt_wdata

input  logic        pe_desc_we
input  logic [3:0]  pe_desc_waddr
input  logic [127:0]pe_desc_wdata
```

active task 期间禁止写正在使用的 entry。

### 3.4 数据输入接口

所有输入均为 ready/valid。

#### QP 共享输入

```text
input  logic                    qp_valid
output logic                    qp_ready
input  logic [HP_MAX*8-1:0]     qp_data
```

- QK mode：`qp_data` 表示 Q，每个有效 lane 1 个 FP8 标量
- PV mode：`qp_data` 表示 P，每个有效 lane 1 个 FP8 标量
- QK mode：实际有效 lane 数 = 当前 task 的 active SA 数
- PV mode：实际有效 lane 数 = 当前 head tile 的 head 数，full tile 为 `Hp_parallel`，最后 partial tile 为 `last_head_count`

#### 输入累加因子流

```text
input  logic                    input_factor_valid
output logic                    input_factor_ready
input  logic [HP_MAX*8-1:0]     input_factor_data
```

- 与 `qp_data` 同拍、同 lane 对齐
- QK mode：作为 Q_ACC 乘加因子，有效 lane 数 = active SA 数
- PV mode：作为 P_ACC 乘加因子，有效 lane 数 = 当前 head tile 的 head 数
- 推荐实现保持与 `qp_fire` 锁步消费
- 本 spec 默认 shared input ACC 持续维护状态，因此不得只接收 raw Q/P 而丢弃对应 factor

#### KV 共享输入

```text
input  logic                    kv_valid
output logic                    kv_ready
input  logic [PE_NUMBER*4-1:0]  kv_data
```

- QK mode：`kv_data` 表示 K beat
- PV mode：`kv_data` 表示 V beat
- 1 beat = 128 个 FP4 lane

#### 反量化参数输入

```text
input  logic                    deq_valid
output logic                    deq_ready
input  logic [31:0]             deq_data
```

- `deq_data = {w0_fp16, w1_fp16}`

#### 输出累加因子流

```text
input  logic                    output_factor_valid
output logic                    output_factor_ready
input  logic [NUM_SA*8-1:0]     output_factor_data
```

- 与 `drain_fire` 同拍、按 SA lane 对齐
- QK/PV 共享同一端口，因二者不会同时 drain
- 仅在 `output_lorenzo` 启用时必须消费；未启用时可不拉 `output_factor_ready`

### 3.5 数据输出接口

#### 共享输出接口

```text
output logic                    out_valid
input  logic                    out_ready
output logic [PE_NUMBER*16-1:0] out_data
output logic [PE_NUMBER-1:0]    out_lane_valid
output logic                    out_mode       ; 0=QK/A, 1=PV/O
```

说明：

- QK mode：`out_if` 表示 A/softmax input；可以只使用低 `NUM_SA` 个 FP16 lane 和
  `out_lane_valid[NUM_SA-1:0]`
- PV mode：`out_if` 表示 O stream，最多使用 128 个 FP16 lane
- 工业实现中通常会再 pack；本 spec 先定义逻辑宽接口
- 若系统侧不接受 128xFP16 并行宽，可在 `lte_out_stream` 内局部串化，但不得回改前级算法模块

---

## 4. 关键配置语义

### 4.1 TDT 关键字段

仅列出 RTL 必须使用的字段：

```text
task_mode        : QK / PV
num_heads
context_length
dim              : QK reduction dim
head_dim         : PV dim width per head
group_size       : fixed 32
SA_per_head      : PV must equal head_dim / 32
Hp_parallel      : PV must equal 128 / head_dim
pe_desc_id
q_buffer_policy
output_mode
stream_contract
deq_prefill_hint
flags
```

### 4.2 PV 合法性

```text
head_dim >= 32
head_dim % 32 == 0
PE_NUMBER % head_dim == 0
SA_per_head * 32 == head_dim
Hp_parallel * head_dim == 128
```

合法组合仅有：

| head_dim | SA_per_head | Hp_parallel |
|----------|-------------|-------------|
| 32 | 1 | 4 |
| 64 | 2 | 2 |
| 128 | 4 | 1 |

由于 `head_dim` 最小为 32，不允许一个 SA 被拆给多个 head。

### 4.3 PE descriptor

沿用 compact `valid_len`：

```text
per SA: {mask_mode[1b], valid_len[6b]}
```

在 PV mode 下，正常配置应为所有 active SA `valid_len=32`。  
在 QK mode 下，可允许非满 SA。

---

## 5. 模块规格

## 5.1 `lte_task_dispatch`

### 功能

- 接收 `csr_start + csr_task_id`
- 检查当前是否 busy
- 从 TDT 取出 task 配置
- 触发 `task_launch`
- 输出 `task_done` / `task_error`

### 输入

```text
clk, rst_n
csr_start
csr_task_id[3:0]
tdt_rdata[255:0]
engine_busy
task_done_i
task_error_i
task_error_code_i[7:0]
```

### 输出

```text
tdt_raddr[3:0]
task_launch
task_id_o[3:0]
task_cfg_o[255:0]
csr_busy
csr_halted_done
csr_halted_error
csr_error_code[7:0]
```

### 设计思路

- 单 task 串行执行
- `csr_start` 在 `engine_busy=1` 时拒绝并上报 `TASK_ENGINE_BUSY`
- `task_launch` 只发 1 个周期脉冲

---

## 5.2 `lte_task_context`

### 功能

- 在 `task_launch` 时锁存 TDT entry 与 PE descriptor
- 解析出常量
- 生成 mode 相关控制

### 输入

```text
task_launch
task_cfg_i[255:0]
pe_desc_rdata[127:0]
```

### 输出

```text
task_mode_o
num_heads_o[15:0]
context_length_o[15:0]
dim_o[15:0]
head_dim_o[15:0]
SA_per_head_o[7:0]
Hp_parallel_o[7:0]
flags_o[7:0]
q_buffer_policy_o[7:0]
output_mode_o[7:0]
qk_dim_group_count_o[15:0]
qk_context_block_count_o[15:0]
qk_context_tail_mask_o[31:0]
pv_context_group_count_o[15:0]
pv_last_inner_count_o[5:0]
valid_len_o[NUM_SA][5:0]
full_pe_active_o[NUM_SA]
pv_sa_per_head_o[2:0]
pv_head_parallel_o[2:0]
cfg_error_o
cfg_error_code_o[7:0]
```

### 设计思路

- 组合解析 + 时序锁存
- launch 周期即完成合法性检查
- `qk_dim_group_count/qk_context_block_count/qk_context_tail_mask/pv_context_group_count/pv_last_inner_count`
  直接来自 TDT 的标准化配置字段；RTL 不在热路径内计算除法或求余
- 若配置非法，则不启动 datapath，直接进 error

---

## 5.3 `lte_loop_nest_ctrl`

### 功能

- 维护 task 内所有循环计数器
- 仅在对应 token fire 时推进
- 产生 terminal 条件

### 状态

```text
head_ctr
context_ctr
group_ctr
inner_ctr
drain_lane_ctr
```

### 输入

```text
task_start
task_mode
num_heads
qk_dim_group_count
qk_context_block_count
qk_context_tail_mask[31:0]
pv_context_group_count
pv_last_inner_count[5:0]
head_dim
Hp_parallel
mac_fire
group_done_accept
drain_fire
```

### 输出

```text
head_ctr_o
context_ctr_o
group_ctr_o
inner_ctr_o
drain_lane_ctr_o
is_group_last
is_row_last
is_head_tile_last
is_task_last
```

`is_*_last` 为本模块本地 predecode/status 输出。高频 datapath 后级应优先消费
`deq_token.last_*`，不得把这些输出再与多个 counter 组合成新的跨层 terminal 链。

### 设计思路

- QK:
  - `group_max = qk_dim_group_count`
  - `context_max = qk_context_block_count`
  - 最后一个 context block 使用 `qk_context_tail_mask`
  - `head step = Hp_parallel`
- PV:
  - `group_max = pv_context_group_count`
  - 最后一个 context group 使用 `pv_last_inner_count` 作为 inner 结束条件
  - `head step = Hp_parallel = 128/head_dim`

计数器推进必须由真实 fire 驱动，不能按时钟空转。

### 轻量化实现要求

不要把 head/context/group/inner 写成多层大 FSM。`lte_loop_nest_ctrl` 必须实现为：

- 本层 counter
- 本层 terminal comparator
- 跨层 1-bit carry/end 信号
- token 中携带的 last 标志

宽比较只允许出现在本层本地组合逻辑中，跨层组合链只传 1 bit。

#### MAC-side counter chain

MAC 热路径只包含 `inner_ctr` 和 `group_ctr`：

```text
group_last_q = (group_ctr == group_max_minus1)
inner_last_q =
    task_mode == QK ? (inner_ctr == GROUP_SIZE-1) :
    group_last_q   ? (inner_ctr == pv_last_inner_count-1) :
                     (inner_ctr == GROUP_SIZE-1)

inner_end = mac_fire & inner_last_q
group_end = inner_end
```

counter 更新：

```text
if (mac_fire)
    inner_ctr <= inner_last_q ? 0 : inner_ctr + 1

if (group_end)
    group_ctr <= group_last_q ? 0 : group_ctr + 1
```

其中 `group_max_minus1`：

```text
QK: qk_dim_group_count - 1
PV: pv_context_group_count - 1
```

循环层级必须按 mode 区分：

```text
QK: inner(dim within 32) -> dim_group -> context_block -> head
PV: inner(context step within 32, last group may be shorter) -> context_group -> head
```

QK 的 `inner_ctr` 不处理 context tail，因为 dim group 始终完整；context tail 只体现在最后一个
`context_block` 的 `lane_valid_mask`。该 mask 必须从 MAC 写 partial_acc 开始生效，并随 token
传递到 dequant/group_acc/drain。PV 则相反：lane 始终用于 dim 并行，不使用 lane mask，
只用 `pv_last_inner_count` 控制最后一个 context reduction group 的 MAC 拍数。

#### Token 携带 terminal flags

在 `group_end` 产生 dequant token 时，把本拍已经算出的 terminal flag 一起锁进 token：

```text
deq_token.last_group = group_last_q
deq_token.last_ctx   = context_last_q
deq_token.last_head  = head_last_q
deq_token.lane_valid_mask =
    (task_mode == QK && context_last_q) ? qk_context_tail_mask : 32'hFFFF_FFFF
```

下游 dequant/drain 不再重新做宽比较，只消费 token 里的 1-bit flag。

这里的 `deq_token.valid` 表示“一个物理 group 已结束，可以送去 dequant”。QK group 固定为
32 个 MAC beat；PV 最后一个 context group 可能短于 32 beat。`deq_token.last_group` 进一步表示
“这个 token 同时也是当前 QK context block / PV head tile 的最后一个逻辑 group”。

#### 预译码 last flag

`context_last_q`、`head_last_q` 建议实现为寄存的 predecode flag，而不是在 `group_end`
当拍再串上宽比较。推荐实现如下：

```text
task_start            -> init context_last_q / head_last_q
context_ctr update    -> refresh context_last_q
head_ctr update       -> refresh head_last_q
group_end/token pack  -> only consume context_last_q / head_last_q
```

这样 `group_end -> token pack` 只消费已经准备好的 1-bit 状态，不再回看宽计数器。

#### Retire-side counter chain

`context_ctr/head_ctr` 不放在 MAC 热路径上。它们由 QK context block / PV head tile retire 事件推进：

```text
qk_row_retire_fire     ; QK 最后一组 dequant + group_acc 完成，一个 context block token 被接收
pv_head_retire_fire    ; PV 最后一组 dequant + group_acc 完成，head tile token 被接收
```

QK:

```text
if (qk_row_retire_fire)
    context_ctr <= context_last_q ? 0 : context_ctr + 1

if (qk_row_retire_fire & context_last_q)
    head_ctr <= head_last_q ? 0 : head_ctr + Hp_parallel
```

PV:

```text
if (pv_head_retire_fire)
    head_ctr <= head_last_q ? 0 : head_ctr + Hp_parallel
```

这样 MAC 发射路径最多是：

```text
mac_fire -> inner_last_q -> group_last_q -> deq_token.valid
```

不允许形成：

```text
inner compare -> group compare -> context compare -> head compare -> large FSM next-state
```

---

## 5.4 `lte_boundary_ctrl`

### 功能

- 根据 loop terminal 产生清零/切换事件

### 输出事件

```text
head_tile_start
row_start
group_start
group_done_pulse
row_done_pulse
head_tile_done_pulse
task_done_pulse
```

### 设计思路

- `group_start` 用于清 `partial_acc bank_mac`
- `row_start` 用于 QK 清 `group_acc_compute_bank`，语义上对应一个 32-lane context block 的开始
- `head_tile_start` 用于清 shared input acc 对应 mode 状态

---

## 5.5 `lte_qp_ingress`

### 功能

- 分时接收 Q/P 标量组
- QK mode：`qp_data` 解释为 Q，写 Q line buffer，并送 shared input ACC 生成 Q_ACC
- PV mode：`qp_data` 解释为 P，写 P FIFO，并送 shared input ACC 生成 P_ACC
- 同步接收 `input_factor_data`，作为 input ACC 乘加因子

### 输入

```text
task_mode
qp_valid
qp_data[HP_MAX*8-1:0]
input_factor_valid
input_factor_data[HP_MAX*8-1:0]
q_buffer_policy
head_tile_start
q_push_accept
p_fifo_pop
```

### 输出

```text
qp_ready
input_factor_ready

q_line_wr_en
q_line_wr_idx
q_line_wr_data
q_acc_fire
q_acc_data[HP_MAX*8-1:0]
q_acc_factor[HP_MAX*8-1:0]

p_fifo_valid
p_fifo_rdata[HP_MAX*8-1:0]
p_factor_rdata[HP_MAX*8-1:0]
p_fifo_level
```

### 设计思路

- QK/PV 不并发，`qp_if` 分时复用
- QK mode 下优先支持 line-valid Q buffer
- PV mode 下作为 P FIFO ingress
- `qp_ready` 和 `input_factor_ready` 必须同拍拉高或同拍拉低，保证 raw 与 factor 不错位
- `qp_fire = qp_valid && qp_ready && input_factor_valid && input_factor_ready`
- QK mode 下，`q_acc_fire` 使用 `qp_fire`
- PV mode 下，P FIFO entry 建议打包 `{p_raw, p_factor}`，或使用锁步双 FIFO

---

## 5.6 `lte_kv_ingress`

### 功能

- 分时接收 K/V beat
- QK mode：`kv_data` 解释为 K beat，写 K FIFO
- PV mode：`kv_data` 解释为 V beat，写 V FIFO

### 输入

```text
task_mode
kv_valid
kv_data[PE_NUMBER*4-1:0]
k_fifo_pop
v_fifo_pop
```

### 输出

```text
kv_ready

k_fifo_valid
k_fifo_rdata[PE_NUMBER*4-1:0]
k_fifo_level

v_fifo_valid
v_fifo_rdata[PE_NUMBER*4-1:0]
v_fifo_level
```

### 设计思路

- QK/PV 不并发，`kv_if` 分时复用
- 可实现为两个内部 FIFO，外部共享一个 ingress ready/valid
- `kv_ready` 由当前 mode 对应 FIFO 的 ready 决定

---

## 5.9 `lte_deq_param_ingress`

### 功能

- 接收 `{w0,w1}` FP16 参数
- 写入 deq FIFO

### 输入

```text
deq_valid
deq_data[31:0]
deq_pop
```

### 输出

```text
deq_ready
deq_fifo_valid
deq_fifo_rdata[31:0]
deq_fifo_level
```

### 设计思路

- 深度建议最少 2，推荐 4
- 参数顺序严格依赖外部契约，不做 tag 检查

---

## 5.10 `lte_input_acc_shared`

### 功能

- QK mode：对 `lte_qp_ingress` 送来的 Q 做 factor-weighted prefix mulacc，生成 Q_ACC line
- PV mode：对 `lte_qp_ingress` 送来的 P 做 factor-weighted prefix mulacc，生成 P_ACC lane
- 输入累加器的更新律统一为：`acc_next = acc_prev + cast_fp16(raw_fp8 * factor_fp8)`

### 输入

```text
task_mode
head_tile_start
q_acc_fire
q_acc_data[HP_MAX*8-1:0]
q_acc_factor[HP_MAX*8-1:0]
p_acc_fire
p_acc_data[HP_MAX*8-1:0]
p_acc_factor[HP_MAX*8-1:0]
Hp_parallel[2:0]
```

### 输出

```text
q_acc_line_wr_en
q_acc_line_wr_idx
q_acc_line_wr_data

p_raw_lane[HP_MAX][15:0]
p_acc_lane[HP_MAX][15:0]
p_lane_valid
```

### 状态

```text
q_acc_state[HP_MAX]   ; QK mode
p_acc_state[HP_MAX]   ; PV mode
```

### 设计思路

- 单实例，mode 互斥
- `head_tile_start` 清对应 mode 状态
- 运算精度使用 FP16
- `q_acc_fire/p_acc_fire` 现在是乘加单元使能，而不是单纯加法器使能
- QK：实例化 `active_sa_count` 个 input mulacc；每个 SA 逐拍接收 1 个 Q scalar 和 1 个 factor
- PV：input mulacc 按 head 粒度维护 P_ACC，full tile 为 `Hp_parallel` 路，最后 partial tile 为 `last_head_count` 路；P/P_ACC scalar 再广播到该 head 占用的 `SA_per_head` 个 SA
- QK mode：

```text
q_mul_term[sa] = q_acc_data[sa] * q_acc_factor[sa]    ; FP8 x FP8
q_acc_state[sa] <= q_acc_state[sa] + cast_fp16(q_mul_term[sa])
```

- PV mode：

```text
p_mul_term[hp_id] = p_acc_data[hp_id] * p_acc_factor[hp_id]    ; FP8 x FP8
p_acc_state[hp_id] <= p_acc_state[hp_id] + cast_fp16(p_mul_term[hp_id])
```

- 若 mul 路径需要打拍，则 `q_acc_fire/p_acc_fire`、lane id、head id 和写回地址必须全程对齐
- QK 中一个 SA 的 32 个 PE 共享同一个 Q scalar，因此不在 SA 内复制 32 个 input mulacc
- PV 中当一个 head 覆盖多个 SA 时，这些 SA 共享同一个 `p_acc_lane[hp_id]`
- `p_raw_lane` 继续输出 raw P 的 FP16 扩展值；`p_acc_lane` 输出乘加后的 FP16 累加值

---

## 5.11 `lte_mac_scheduler`

### 功能

- 决定当前 cycle 是否允许 MAC
- 选择 Q raw/Q_ACC 或 P raw/P_ACC
- 产生对 SA array 的 scalar/vector 输入

### 输入

```text
task_mode
q_line_valid
q_line_raw
q_line_acc
k_fifo_valid
k_fifo_rdata
p_fifo_valid
p_fifo_rdata
p_raw_lane
p_acc_lane
v_fifo_valid
v_fifo_rdata
partial_acc_bank_ready
use_input_lorenzo[NUM_SA]
lane_valid_mask[31:0]
head_dim
Hp_parallel
```

### 输出

```text
mac_fire
k_fifo_pop
p_fifo_pop
v_fifo_pop
sa_scalar[NUM_SA]
sa_vector[NUM_SA][PE_PER_SA]
sa_pe_valid[NUM_SA][PE_PER_SA]
partial_acc_bank_sel
```

### 设计思路

#### QK mode

```text
mac_fire = q_line_valid[cur_d] && k_fifo_valid && partial_acc_bank_ready
```

`sa_pe_valid[sa][pe]` 必须同时受当前 QK `lane_valid_mask[pe]` 约束。最后一个 partial
context block 中，mask 为 0 的 PE lane 不写 partial_acc。

#### PV mode

```text
mac_fire = p_fifo_valid && v_fifo_valid && partial_acc_bank_ready
```

PV lane 映射：

```text
flat_lane = sa_id*32 + pe_id
hp_id     = flat_lane / head_dim
dim_id    = flat_lane % head_dim
```

仅当 `hp_id < Hp_parallel` 时该 lane 有效。合法 PV mapping 下不再叠加 context tail mask。

由于 `head_dim` 必须是 32 的倍数，PV 可以按 SA 粒度广播 P scalar：

```text
pv_sa_per_head = head_dim / 32
hp_id_for_sa   = sa_id / pv_sa_per_head
dim_base_for_sa= (sa_id % pv_sa_per_head) * 32

sa_scalar[sa_id] = selected_P_lane[hp_id_for_sa]
sa_vector[sa_id][pe_id] = V_lane[sa_id*32 + pe_id]
dim_id = dim_base_for_sa + pe_id
```

因此一个 SA 永远只属于一个 head，不会在一个 `1x32` SA 内拆分多个 head。

---

## 5.12 `lte_sa_array`

### 功能

- 4 个 `1x32 output-stationary` SA
- 每个 SA 内部 32 个 PE，共享同一个 scalar 输入，各 PE 接收独立 vector lane
- 每个 PE 内部保存自己的 output-stationary `partial_acc`
- 执行 `partial_acc_bank[wr_bank] += scalar * vector_lane`

### 输入

```text
mac_fire
sa_scalar[NUM_SA][15:0]
sa_vector[NUM_SA][PE_PER_SA][3:0]
sa_pe_valid[NUM_SA][PE_PER_SA]
wr_bank_sel
group_start_clear
deq_rd_bank_sel
```

### 输出

```text
partial_acc_bank_rdata[2][NUM_SA][PE_PER_SA][15:0]
```

### 设计思路

- `partial_acc` 为 FP16，物理位置在每个 PE 内部
- 每个 PE 至少包含两个 output-stationary accumulator bank
- `wr_bank_sel` 指向当前 MAC 写 bank
- `deq_rd_bank_sel` 指向 dequant 正在读取的完成 bank
- `group_start_clear` 清当前写 bank
- PE 间不交换 partial sum，output stationary 意味着同一个 output lane 的部分和始终停留在同一个 PE
- 对 QK：scalar 为当前 head/dim 的 Q，vector lane 为同一 dim 下 32 个 context lane 的 K
- 对 QK：最后一个 partial context block 中，`sa_pe_valid[sa][pe]` 由 `lane_valid_mask[pe]` 屏蔽无效 lane，
  无效 lane 不写 `partial_acc`
- 对 PV：scalar 为当前 head/context 的 P，vector lane 为同一 context 下 32 个 dim lane 的 V

### `lte_sa_1x32` 子模块建议接口

```text
input  logic                  mac_fire
input  logic [15:0]           scalar_fp16
input  logic [31:0][3:0]      vector_fp4
input  logic [31:0]           pe_valid
input  logic                  wr_bank_sel
input  logic                  clear_wr_bank
input  logic                  rd_bank_sel
output logic [31:0][15:0]     rd_partial_acc
```

实现建议：

- scalar 以广播方式送入 32 个 PE
- `vector_fp4[pe]` 送入对应 PE
- 每个 PE 做本地 MAC 并更新本地 accumulator
- 若 FP4/FP8 到 FP16 的乘法需要 pipeline，必须保证 `mac_fire` 与 accumulator write enable 对齐
- `rd_partial_acc` 供 dequant pipe 读取完成 group 的 stationary 输出

---

## 5.13 `lte_dequant_pipe`

### 功能

- 接收 `deq_token`
- 从 deq FIFO 取 `{w0,w1}`
- 从 `lte_sa_array` 读取完成 bank 的 output-stationary `partial_acc`
- 输出 `dequant_result`

### 输入

```text
deq_token_valid
deq_token
deq_fifo_valid
deq_fifo_rdata
partial_acc_bank_rdata
```

### 输出

```text
deq_token_ready
deq_pop
dequant_result_valid
dequant_result[NUM_SA][PE_PER_SA][15:0]
dequant_result_meta
partial_acc_bank_release
```

### 设计思路

- pipeline 可多拍
- 与下一 group MAC 并行
- 必须保持 group 顺序

---

## 5.14 `lte_group_acc_bank`

### 功能

- 两个 group_acc bank
- 一个 compute bank，一个 drain bank

### 输入

```text
row_start_clear
dequant_result_valid
dequant_result
row_done_swap
```

### 输出

```text
group_acc_compute_bank
group_acc_drain_bank
group_acc_bank_free[1:0]
```

### 设计思路

- QK：每个 row 开始清 compute bank
- PV：每个 head tile 开始清 compute bank

---

## 5.15 `lte_drain_scheduler`

### 功能

- 接收 `drain_token`
- 驱动 `drain_lane_ctr`
- 控制 output_acc 和 output_queue

### 输入

```text
drain_token_valid
drain_token
group_acc_drain_bank
output_queue_ready
output_factor_valid
output_factor_data[NUM_SA*8-1:0]
```

### 输出

```text
drain_token_ready
drain_fire
drain_lane_ctr
output_factor_ready
output_acc_in_valid
output_acc_in_data
output_acc_factor[NUM_SA*8-1:0]
output_acc_lane_valid
```

### 设计思路

- QK：输出 4 路 SA channel
- PV：输出 128 lane 逻辑向量，允许后级 pack
- QK 最后一个 partial context block 必须根据 `drain_token.lane_valid_mask` 跳过无效 lane，
  对应 lane 不产生 `drain_fire`，也不消费 `output_factor`
- 若 `output_lorenzo` 使能，则 `drain_fire` 还必须满足 `output_factor_valid`
- `output_factor_ready` 应与 `drain_fire` 对齐，保证 raw output 与 factor 同步被消费
- 每个 active SA 只需要 1 个 output mulacc；它沿 `drain_lane_ctr=0..31` 分时复用

---

## 5.16 `lte_output_acc`

### 功能

- 沿 `drain_lane_ctr=0..31` 做 factor-weighted prefix mulacc
- 更新律：`output_acc_next = output_acc_prev + cast_fp16(raw_output_fp16 * output_factor_fp8)`

### 输入

```text
drain_start
drain_fire
use_output_lorenzo[NUM_SA]
raw_output[NUM_SA][15:0]
output_factor[NUM_SA][7:0]
```

### 输出

```text
downstream_output[NUM_SA][15:0]
```

### 设计思路

- 每次 drain token 开始清零
- 若 `use_output_lorenzo=0`，旁路 raw
- `drain_fire` 现在是 output mulacc 单元使能
- 推荐每个 SA 1 个 output mulacc datapath，以保持每拍一个 `drain_lane_ctr`
- 乘加语义：

```text
mul_term[sa]     = raw_output[sa] * output_factor[sa]      ; FP16 x FP8
output_acc[sa]   = output_acc[sa] + cast_fp16(mul_term[sa])
downstream[sa]   = use_output_lorenzo[sa] ? output_acc[sa] : raw_output[sa]
```

- 若乘法器或加法器需要打拍，必须保持 `drain_lane_ctr`、`raw_output`、`output_factor` 和
  `use_output_lorenzo` 全程对齐
- 不在一个 SA 内按 32 个 PE lane 复制 output mulacc；drain 本身就是逐 lane 顺序过程

---

## 5.17 `lte_output_queue`

### 功能

- 缓冲 drain 输出
- 解耦 compute/drain 与外部 sink

### 输入

```text
push_valid
push_data
pop_ready
```

### 输出

```text
push_ready
pop_valid
pop_data
level
```

### 设计思路

- 深度建议 2~8
- 满时反压 drain scheduler

---

## 5.18 `lte_out_stream`

### 功能

- 分时输出 QK/PV 结果
- QK mode：`out_if` 表示 A/softmax input
- PV mode：`out_if` 表示 O stream
- 可选地在本模块内实现 pack/串化

### 输入

```text
task_mode
output_mode
output_queue_pop_valid
output_queue_pop_data
out_ready
```

### 输出

```text
output_queue_pop_ready
out_valid
out_data[PE_NUMBER*16-1:0]
out_lane_valid[PE_NUMBER-1:0]
out_mode
```

### 设计要求

- QK/PV 不并发，`out_if` 分时复用
- QK 可只使用低 `NUM_SA` 个 FP16 lane
- PV 可使用 128 个 FP16 lane，或在本模块局部 pack/串化
- 串化若实现，不得影响上游 group/drain 语义
- pack 规则需单独补一份接口协议文档

---

## 5.19 `lte_error_ctrl`

### 功能

- 汇总所有配置错误和运行错误
- 锁存 `task_error` 与 `error_code`

### 必须支持的错误码

```text
ILLEGAL_TASK_DESC
ILLEGAL_TASK_MODE
TASK_ENGINE_BUSY
ILLEGAL_GROUP_SIZE
ILLEGAL_DIM
ILLEGAL_CONTEXT        ; context_length/count/mask/last_inner_count 配置非法或自洽检查失败
ILLEGAL_PV_MAP
ILLEGAL_STREAM_CONTRACT
```

---

## 6. 模块间关键握手

### 6.1 `mac_fire`

`mac_fire` 是 loop 推进的唯一准入条件之一。只有当：

- 对应输入 valid
- 当前 partial_acc write bank 可写
- SA array 可接受

时才允许拉高。

### 6.1.1 `input_mulacc_fire`

`input_mulacc_fire` 与 `qp_fire` 锁步：

```text
input_mulacc_fire = qp_valid & qp_ready & input_factor_valid & input_factor_ready
```

该事件同时消费 Q/P raw 和 input factor，并更新 Q_ACC/P_ACC。若 input factor 不 ready，
必须反压 `qp_if`，不得只接收 raw 后等待 factor。

### 6.2 `group_done_token`

在 `inner_end` 时产生，即 QK 为 `inner_ctr==31 && mac_fire`，PV 最后一个 context group 可由
`pv_last_inner_count` 提前结束。  
它表示：

- 当前 group 的 partial_acc 已完整
- 可进入 dequant queue
- 可切 bank
- 携带 `last_group/last_ctx/last_head/lane_valid_mask`，供 dequant、group_acc、drain 和 task_done 侧直接消费
- 下游不得重新根据 `context_ctr/head_ctr` 做宽比较来判断边界

### 6.3 `drain_token`

在：

- QK: `row_done`，语义为一个 32-lane context block 完成
- PV: `head_tile_done`

时产生。  
group_acc bank 只有在对应 drain token 被接收后，才能转入 drain 态。

### 6.4 `output_mulacc_fire`

当 `output_lorenzo=1` 时：

```text
output_mulacc_fire = drain_fire & output_factor_valid & output_factor_ready
```

`drain_fire` 只能在 raw output、output factor、output queue 都可接收时成立。若
`output_lorenzo=0`，output factor 可不消费，drain path 直接旁路 raw output。

---

## 7. 建议状态机

## 7.1 顶层 engine FSM

```text
IDLE
  -> LOAD_CTX
  -> RUN
  -> DRAIN_PENDING
  -> DONE
  -> ERROR
```

说明：

- 实际运行时 dequant / drain 可与 RUN 并发，因此 `RUN` 内部不应再细分成互斥串行态
- `DRAIN_PENDING` 只表示没有新的 MAC token，但 drain/output 还未清空
- 该 FSM 只描述 task 生命周期，不编码 `inner/group/context/head` 循环状态
- 明确禁止派生 `RUN_INNER/RUN_GROUP/RUN_CONTEXT/RUN_HEAD` 之类的嵌套执行态；循环推进必须由
  `lte_loop_nest_ctrl` 的 counter/carry/token retire 完成

## 7.2 Ingress FIFO

标准同步 FIFO，无复杂状态机。

## 7.3 Q line buffer

```text
FREE
FILLING
ACTIVE
FREE
```

---

## 8. 时序与实现建议

### 8.1 SA 阵列

- `scalar * vector + partial_acc` 可能成为关键路径
- 必要时可在 SA 内部打一拍
- 若打一拍，`mac_fire` 和 `inner_ctr` 推进必须与最终接收拍对齐

### 8.2 Dequant

- 允许多拍 pipeline
- token meta 必须跟数据同延迟对齐

### 8.3 Output path

- `output_acc += raw * output_factor` 是 loop-carried dependency
- 若 1 cycle 乘加时序困难，可在 output mulacc 内部 pipeline 或在 drain path 放宽 II，但不得改变顺序
- pipeline 后必须保证 `drain_lane_ctr/raw_output/output_factor/use_output_lorenzo` 元数据对齐

---

## 9. 验证建议

### 9.1 模块级

- `lte_task_context`：配置合法性枚举
- `lte_input_acc_shared`：QK/PV mode、clear boundary、raw/factor 对齐、raw/acc 输出
- `lte_mac_scheduler`：QK/PV lane mapping
- `lte_dequant_pipe`：token 与 `{w0,w1}` 对齐
- `lte_drain_scheduler`：QK context block / PV head tile 完成边界、tail mask、output factor 对齐
- `lte_output_acc`：FP16xFP8 mulacc、旁路模式、drain_lane 对齐

### 9.2 系统级 directed cases

1. QK, `dim=128`, `Hp_parallel=1`
2. QK, `context_length=33`，检查最后一个 context block 的 `lane_valid_mask`
3. PV, `context_length=33`，检查最后一个 context group 只跑 `pv_last_inner_count=1`
4. PV, `head_dim=128`, `Hp_parallel=1`
5. PV, `head_dim=64`, `Hp_parallel=2`
6. PV, `head_dim=32`, `Hp_parallel=4`
7. Q line buffer line-valid 启动
8. deq FIFO 短缺 backpressure
9. output queue 满 backpressure
10. input factor 短缺 backpressure
11. output factor 短缺 backpressure
12. factor valid 与 raw valid 错位注入，检查 ready/valid 是否阻止错配采样

---

## 10. 交付建议

建议工程拆分顺序：

1. `lte_task_context` / `lte_loop_nest_ctrl` / `lte_boundary_ctrl`
2. `lte_qp_ingress` / `lte_kv_ingress` / `lte_deq_param_ingress`
3. `lte_input_acc_shared`
4. `lte_mac_scheduler`
5. `lte_sa_array` 内含 `1x32 output-stationary SA` 与 PE-local partial_acc banks
6. `lte_dequant_pipe`
7. `lte_group_acc_bank`
8. `lte_drain_scheduler` + `lte_output_acc` + `lte_output_queue`
9. `lte_out_stream`
10. `lte_task_dispatch` / `lte_error_ctrl` / `lte_csr`

这样可以先打通不含真实算术的控制框架，再逐块替换成最终 datapath。

---

## 11. 本文档的使用方式

后续 RTL 工程师看到本文档后，应可以立即开始：

- 建 `top + 子模块` 骨架
- 按本 spec 定端口
- 按本 spec 写状态机、FIFO、bank 切换、counter 和 handshake
- 再逐步填充算术细节

若后续需要，我建议下一步直接补两份配套文档：

1. `signal_dictionary_v03_task_engine_zh.md`
2. `rtl_testplan_v03_task_engine_zh.md`
