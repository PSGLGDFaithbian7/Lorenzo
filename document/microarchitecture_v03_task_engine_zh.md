# 微架构 V0.3 — Task Engine / 全流水配置式执行草案

> 版本：**V0.3 draft (Task Engine)**。  
> 配套 `microinstruction_isa_v03_task_engine_zh.md`。  
> 目标：从 V0.2 的微码调度式执行，升级为硬件任务调度器驱动的流式执行。设计重点是：
> 多层循环硬件化、流顺序解释硬件化、反量化与 MAC 重叠、drain 与下一轮 compute 解耦，
> 避免“读数停计算、计算停读数”的阶段式运行。

---

## 0. V0.2 问题复盘

V0.2 已经有 K/V/P FIFO、Q ping-pong、LOOP、Lorenzo 累加和 group dequant，因此比
V0.1 强很多。但从架构角度看，它仍然是一个 **microcoded streaming engine**，不是一个
完整的 **task accelerator**。

主要不足：

1. **循环控制停留在指令层。** `LOOP_BEGIN/END` 可以嵌套，但 loop counter 不直接驱动
   group boundary、row boundary 或 drain boundary。
2. **读数窗口由软件启动。** `RECV_START_*` 仍是显式指令，连续 head/context 切换依赖
   微码发下一次 receive。
3. **同一 SA_ENGINE 覆盖 MAC、dequant、drain。** V0.2 `GROUP_DEQ` 可能停住 MAC；
   `DRAIN_A/O` 也占用 SA_ENGINE，导致下一次 compute 不能自然提前。
4. **只有 dequant 参数预取，没有 dequant 结果流水。** 参数 SRAM latency 可隐藏，但
   dequant datapath latency 仍可能成为 group 间 bubble。
5. **Q 以 tile-ready 为粒度。** Q buffer 需要 READY 后 SA_RUN 才开始读，不支持更细的
   line/credit 级边填边算。
6. **无多 outstanding stream window。** Receiver done 与 SA done 可重叠，但同一 stream
   的连续窗口不能由硬件自动排队。

V0.3 的核心策略：将 `RECV/SA_RUN/DRAIN` 拆成硬件流水级，并用 task descriptor 提供所有
循环 shape、固定流顺序契约和累加策略。外部保证按顺序供给正确数据；engine 不做地址生成。

---

## 1. 顶层模块

```text
Host Config
  ├─ ucode RAM / legacy sequencer
  ├─ TDT: Task Descriptor Table
  ├─ PE_VALID_LEN_DESC
  └─ CSR

Control
  ├─ u_useq_legacy
  ├─ u_task_dispatch
  ├─ u_task_engine
  │   ├─ u_task_context_latch
  │   ├─ u_loop_nest_ctrl
  │   ├─ u_boundary_ctrl
  │   ├─ u_task_scoreboard
  │   └─ u_debug_snapshot
  └─ u_error_ctrl

Streaming Datapath
  ├─ u_qp_ingress (QK: Q, PV: P) + Q line buffer / P FIFO
  ├─ u_kv_ingress (QK: K, PV: V) + K/V FIFO
  ├─ u_input_acc_shared (QK: Q_ACC line, PV: P_ACC lane, external-FP8 mulacc)
  ├─ u_deq_param_ingress + deq FIFO
  ├─ u_mac_scheduler
  ├─ u_sa_array[4] (4 x 1x32 output-stationary SA, PE-local partial_acc bank0/bank1)
  ├─ u_dequant_pipeline + dequant token queue
  ├─ u_group_acc bank0/bank1
  ├─ u_drain_scheduler + output_acc(external-FP8 mulacc) + output queue
  └─ u_out_stream (QK: A/softmax, PV: O/optional SRAM_QP)
```

V0.2 legacy datapath 可以复用大部分算术模块。新增的是 task-level control 和解耦队列。

---

## 2. Task Engine 控制面

### 2.1 Task Context Latch

`TASK_START` 后一次性锁存：

- TDT entry；
- PE valid_len descriptor；
- 运行 flags；
- Host 配置并锁存的循环常量：
  - `qk_dim_group_count = dim/32`
  - `qk_context_block_count = ceil(context_length/32)`
  - `qk_context_tail_mask[31:0]`
  - `pv_context_group_count = ceil(context_length/32)`
  - `pv_last_inner_count`，最后一个 PV context reduction group 的有效 inner 数，1..32
- PV mapping 常量：`PE_NUMBER=128`、`SA_WIDTH=32`、`pv_sa_per_head=head_dim/32`、
  `pv_head_parallel=PE_NUMBER/head_dim`；
- Lorenzo 选择位：`use_input_lorenzo[sa]`、`use_output_lorenzo[sa]`；
- 固定格式选择：`Q/P=FP8`、`K/V=FP4`、`deq_param=FP16`。这些格式硬连线，不可配置。
- `u_input_acc_shared` mode：QK 时生成/写入 Q_ACC line，PV 时维护 P_ACC lane。
- 输入累加器和输出累加器都升级为乘加型：外部同步送入一个 FP8 因子，硬件执行
  `acc_next = acc_prev + product(raw, factor_fp8)`，不再是纯 `acc += raw`。
  架构上对应两个乘加单元域：`input_mulacc` 挂在 shared input ACC 前，
  `output_mulacc` 挂在 drain/output ACC 前。物理 RTL 不按 32 个 PE lane 复制：
  QK input 侧每个 active SA 1 个 input mulacc，PV input 侧按 active head 数启用 input mulacc，
  每个 P/P_ACC scalar 再广播到该 head 占用的 `SA_per_head` 个 SA；
  output 侧固定每个 active SA 1 个 output mulacc，并沿 `drain_lane_ctr=0..31` 分时复用。

锁存后 active task 不再读取 host 可写 descriptor，避免运行时修改造成不确定性。

### 2.2 Loop Nest Controller (`u_loop_nest_ctrl`)

硬件维护以下计数器：

```text
head_ctr        ; PV 以 Hp_parallel (=128/head_dim) 为步长
context_ctr     ; QK 的 context block index；PV 不使用该层
group_ctr       ; QK 的 dim_group index / PV 的 context_group index
inner_ctr       ; QK 固定 0..31 / PV 最后一组可由 pv_last_inner_count 提前结束
drain_lane_ctr  ; 0..31
```

每个 counter 只在对应 token 被下游接受时推进，但实现上不要把它写成多层嵌套 FSM。
推荐做成硬件 loop-carry controller：每一层只包含本层 counter、本层等值比较和一个
1-bit carry/end 输出。跨层组合链只传递 1-bit，不传递宽计数器比较结果。

MAC 发射侧只保留 `inner/group` 两层，因为这是最高频路径：

```text
inner_last_q =
    task_mode == QK ? (inner_ctr == 31) :
    group_last_q   ? (inner_ctr == pv_last_inner_count-1) :
                     (inner_ctr == 31)
group_last_q = (group_ctr == group_max_minus1)

inner_end  = mac_fire & inner_last_q
group_done = inner_end
tile_end   = group_done & group_last_q

if mac_fire:
    inner_ctr <= inner_last_q ? 0 : inner_ctr + 1

if group_done:
    group_ctr <= group_last_q ? 0 : group_ctr + 1

if group_done:
    emit group_done_token(last_group = group_last_q,
                          last_ctx   = context_last_q,
                          last_head  = head_last_q)
```

其中：

```text
QK group_max_minus1 = qk_dim_group_count - 1
PV group_max_minus1 = pv_context_group_count - 1
```

QK 与 PV 的循环层级不同，不能把同一个 `group_ctr` 误解为同一种物理含义：

```text
QK: inner(dim within 32) -> dim_group -> context_block -> head
PV: inner(context step within 32) -> context_group -> head
```

QK 的 context tail 由 `qk_context_tail_mask` 处理。当前 `context_block` 的
`lane_valid_mask` 必须在 MAC/partial_acc 写入阶段就生效，并继续由 `group_done_token`
携带到 dequant/group_acc/drain。最后一个 `context_block` 上携带
`lane_valid_mask = qk_context_tail_mask`，其余 context block 携带 `32'hFFFF_FFFF`。
PV 不需要 lane mask；最后一个 context group 只通过 `inner_last_q` 提前闭合。

`context/head` 不放在 `mac_fire` 热路径上。它们由 dequant/group_acc 完成后的 retire
事件推进：

```text
qk_block_retire_fire = deq_token_retire & token.last_group
pv_tile_retire_fire = deq_token_retire & token.last_group

QK:
  if qk_block_retire_fire:
      context_ctr <= context_last_q ? 0 : context_ctr + 1
  if qk_block_retire_fire & context_last_q:
      head_ctr <= head_last_q ? 0 : head_ctr + Hp_parallel

PV:
  if pv_tile_retire_fire:
      head_ctr <= head_last_q ? 0 : head_ctr + Hp_parallel
```

`context_last_q`、`head_last_q` 建议做成 predecode flag：在 `context_ctr/head_ctr`
更新时同步刷新，而不是在 `group_end` 当拍临时串上宽比较。这样 MAC 侧最长链路近似为：

```text
mac_fire -> inner_last_q -> group_done -> group_last_q -> group_done_token.valid
```

显式禁止形成下面这种链路：

```text
inner compare -> group compare -> context compare -> head compare -> large FSM next-state
```

边界事件语义保持为：

```text
QK:
  group_done      = inner_end
  block_done      = qk_block_retire_fire
  row_done        = qk_block_retire_fire      ; 兼容旧命名，语义为一个 32-lane context block 可 drain
  head_tile_done  = qk_block_retire_fire & token.last_ctx
  task_done       = qk_block_retire_fire & token.last_ctx & token.last_head

PV:
  group_done      = inner_end
  head_tile_done  = pv_tile_retire_fire
  task_done       = pv_tile_retire_fire & token.last_head
```

### 2.3 Boundary Controller (`u_boundary_ctrl`)

`u_boundary_ctrl` 产生清零和切换事件：

| 事件 | QK | PV |
|------|----|----|
| `head_tile_start` | 允许 Q head tile 进入 Q line buffer，清 shared input ACC 的 Q_ACC/line state | 清 shared input ACC 的 P_ACC lane |
| `row_start` | 清 `group_acc`，准备一个 32-lane context block；名称保留为 row 兼容旧接口 | 无 |
| `group_start` | 清当前 `partial_acc` bank | 清当前 `partial_acc` bank |
| `group_done` | 发 dequant token | 发 dequant token |
| `row_done` | 发 drain A token，token 携带本 block 的 `lane_valid_mask` | 无 |
| `head_tile_done` | 切换 head tile | 发 drain O token，切换 head tile |

这些事件不由微码触发，而由 loop terminal 条件触发。

---

## 3. 固定流接口与输入缓冲

### 3.1 固定数据格式

Task mode 下格式硬固定：

- `Q`：FP8
- `P`：FP8
- `K`：FP4
- `V`：FP4
- `input_acc_factor`：FP8
- `output_acc_factor`：FP8
- `deq_param = {w0,w1}`：2 x FP16
- `partial_acc`：FP16
- `group_acc/final_acc/output_acc`：FP16

因此本设计不需要 AGU，也不需要 per-stream format decoder 选择逻辑。

### 3.2 外部流接口

外部必须按 ISA 约定的 canonical 顺序供数。推荐端口如下：

| 端口 | 数据 | 说明 |
|------|------|------|
| `qp_in` | `HP_MAX x FP8` | QK 时为 Q，PV 时为 P |
| `kv_in` | 1 个固定 KV beat | QK 时为 K lanes，PV 时为 V lanes |
| `input_factor_in` | `HP_MAX x FP8` | 与 `qp_in` 同拍对齐；QK 有效 lane = `active_sa_count`，PV 有效 lane = 当前 head tile 的 head 数 |
| `deq_in` | `{w0_fp16,w1_fp16}` | 每个逻辑 group 1 组参数 |
| `output_factor_in` | `NUM_SA x FP8` | 与 drain 顺序同拍对齐；供 output_acc 使用 |
| `out_if` | FP16 stream | QK 时为 A/softmax input，PV 时为 O |

所有端口都走 ready/valid。engine 不生成地址，只消费“当前该消费的第几个 token”。

其中 `active_sa_count` 表示当前 head tile 实际启用的 SA 数（1..4）。QK 中每个 active SA
对应一个 Q/input_factor 标量；PV 中 QP/input_factor 的 lane 数是当前 tile 的 head 数，full tile
为 `Hp_parallel`，最后 partial tile 为 `last_head_count`，而 SA 阵列启用数为
`active_head_count * pv_sa_per_head`。

### 3.2.1 FP8 factor 供数时序

外部不需要猜内部状态机；以 ready/valid 和固定顺序为准：

- `input_factor_in` 只在 `qp_fire` 同拍被消费。外部看到 `qp_ready && input_factor_ready`
  时，送当前 Q/P raw 对应的下一个 FP8 因子。
- QK mode 下，factor 顺序跟 Q stream 完全一致：`head_tile -> d -> active_sa`。
- PV mode 下，factor 顺序跟 P stream 完全一致：`head_tile -> context -> hp_id`。
- `output_factor_in` 只在启用 `output_lorenzo` 且 `drain_fire` 同拍被消费。
- QK output factor 顺序跟 A context block drain 一致：
  `head_tile -> context_block -> drain_lane -> active_sa`。最后一个 partial block 中 mask 为 0 的 lane
  不消费 output factor。
- PV output factor 顺序跟 O drain 一致：`head_tile -> drain_lane -> active_sa`。

若 factor 当拍不给，硬件拉低对应 ready 或不产生 fire，通过 backpressure 暂停，不会错拍采样。

### 3.3 输入缓冲

| 输入/输出 | 缓冲 |
|-----------|------|
| Q/P | Q line buffer + Q_ACC line buffer / P FIFO |
| K/V | K FIFO / V FIFO |
| input_factor | 与 `qp_in` 锁步，默认不单独落 SRAM；实现上可选 1-entry skid buffer |
| deq_param | deq FIFO |
| output_factor | 与 drain 锁步，默认不单独落 SRAM；实现上可选 1-entry skid buffer |
| 输出 | output queue |

这些 FIFO/line buffer 只做顺序缓存，不支持乱序，也不承担寻址。

### 3.4 PV Dim-Parallel Mapping

PV 阶段固定使用全部 `PE_NUMBER=128` 个 PE lane 做 dim 并行，`context_length` 在时间上分时
累加。合法配置必须满足：

```text
head_dim >= 32
head_dim % 32 == 0
PE_NUMBER % head_dim == 0
pv_head_parallel = PE_NUMBER / head_dim
pv_sa_per_head   = head_dim / 32
pv_head_parallel * head_dim == PE_NUMBER
```

典型配置：

| head_dim | pv_sa_per_head | pv_head_parallel | PE 利用 |
|----------|----------------|------------------|---------|
| 128 | 4 | 1 | 128/128 |
| 64  | 2 | 2 | 128/128 |
| 32  | 1 | 4 | 128/128 |

因为 `head_dim` 最小为 32 且 32 对齐，每个 head 至少占用一个完整 SA，不会出现一个 SA
被拆给多个 head 的情况。若模型逻辑维度不是合法值，外部按固定流契约补齐到合法
`head_dim` 后供数。

PV flatten lane 映射：

```text
flat_lane = 0 .. 127
hp_id     = flat_lane / head_dim
dim_id    = flat_lane % head_dim
head_id   = head_ctr + hp_id
sa_id     = flat_lane / 32
pe_id     = flat_lane % 32
```

`kv_in` 在 PV mode 下每拍携带 128 个 FP4 lane，已经按上述顺序排好；硬件只按 counter 解释 lane 位置，
不检查外部是否送错数据。

由于 `head_dim` 总是 32 的整数倍，PV 可以按完整 SA 粒度分配 head：

```text
pv_sa_per_head = head_dim / 32
hp_id_for_sa   = sa_id / pv_sa_per_head
```

因此一个 `1x32` SA 在一个 PV task 中只服务于一个 head 的连续 32 维 dim，不存在把一个 SA
拆分给多个 head 的情况。

### 3.5 Shared Input Accumulator

QK 和 PV 在 task engine 中分时运行，不会同时占用输入累加器。因此只实例化一个
`u_input_acc_shared`：

| Mode | 输入 | 状态/输出 |
|------|------|-----------|
| QK | `qp_in` FP8 lanes + `input_factor_in` FP8 lanes | 生成 Q_ACC，并写入 Q_ACC line buffer |
| PV | `qp_in` FP8 lanes + `input_factor_in` FP8 lanes | 维护 P_ACC lane，同时输出 P raw / P_ACC |

`flags[0]` 只决定 SA MAC 侧是否选用累加值；shared input accumulator 本身按 task mode
持续更新对应状态。`head_tile_start` 是默认清零边界。

输入乘加语义：

```text
input_acc_term = raw_qp * input_factor_fp8
input_acc_next = input_acc_prev + cast_fp16(input_acc_term)
```

其中：

- QK mode：`raw_qp = Q(d, sa_id)`，结果写入 `Q_ACC line`
- PV mode：`raw_qp = P(t, hp_id)`，结果写回 `P_ACC lane`
- `raw_qp` 为 FP8，`input_factor_fp8` 为外部同步输入 FP8，累加状态保持 FP16
- `qp_fire` 必须同时满足 `qp_valid && input_factor_valid && qp_ready && input_factor_ready`
- QK 资源：每个 active SA 1 个 input mulacc。一个 `1x32` SA 每拍只接收一个 scalar，
  因此该 mulacc 随 SA 的 scalar 输入逐拍工作，不按 32 个 PE lane 复制。
- PV 资源：input mulacc 按 head 粒度维护 P_ACC，full tile 为 `Hp_parallel` 路，最后 partial tile
  为 `last_head_count` 路；每个 head 的 P/P_ACC scalar 再广播给该 head 占用的
  `SA_per_head` 个 SA。当最后一批 head 不满时，SA 阵列运行态
  `active_sa_count = last_head_count * SA_per_head`。

### 3.6 Q line buffer 改造

V0.2 的 Q ping-pong 是 tile READY 粒度。V0.3 建议改为：

- 仍保留 2 bank ping-pong；
- 每个 bank 内部有 line valid bitmap 或 credit counter；
- `u_qp_ingress` 在 QK mode 写入第 `d` 个 dim token 后，`q_line_valid[d]=1`；
- MAC 只需要当前 `d` valid 即可，不必等待整个 Q tile READY；
- `u_input_acc_shared` 在 QK mode 下同步写入 Q_ACC 对应 line；
- 若实现想保持简单，可退回 V0.2 的 tile READY，但会保留一个启动 bubble。

推荐状态：

```text
FREE -> FILLING
FILLING and line_valid[d] 可被 MAC 读取
当所有需要 line 被消费后 -> FREE
```

这样 QK 可以真正做到 Q 读入与 K/MAC 细粒度重叠。

---

## 4. MAC Scheduler

`u_mac_scheduler` 接收 loop token 和 stream valid：

```text
QK mac_fire = q_token_valid && k_fifo_valid && partial_acc_bank_ready && sa_ready
PV mac_fire = p_fifo_valid && v_fifo_valid && partial_acc_bank_ready && sa_ready
```

`mac_fire` 后：

- QK：读取 Q raw/acc，消费 K lane；
- PV：P FIFO pop 后先经过 shared input accumulator 更新 P_ACC，再按 `use_input_lorenzo[sa]`
  为每个 `hp_id` 选择 P raw/acc；128 个 PE lane 同时消费对应 `V(head_id, dim_id)`；
- `u_mac_scheduler` 只做 scalar broadcast 和 vector lane routing；真正的
  `partial_acc += scalar * vector` 在 `1x32 output-stationary` SA 的 PE 本地完成；
- loop counter 推进。

这里 `u_input_acc_shared` 的启动逻辑已经从“启动加法更新”变为“启动乘加更新”：

```text
input_mulacc_fire = qp_fire
input_mulacc_term = qp_raw * input_factor_fp8
input_acc_state   = input_acc_state + input_mulacc_term
```

### 4.1 双 partial_acc bank

为隐藏 dequant latency，V0.3 建议每个 PE 至少两个 output-stationary partial_acc bank：

```text
bank_mac  : 当前 group 的 MAC 写入
bank_deq  : 上一 group 的 dequant 读取
```

group boundary：

```text
emit deq_token(bank_mac, head, context_block, group,
               last_group, last_ctx, last_head, lane_valid_mask)
swap bank_mac/bank_deq if free
```

若 dequant pipeline 未释放 `bank_deq`，MAC scheduler 才会停顿。这种停顿来自真实算力不足，
不是软件阶段切换。

---

## 5. Dequant Pipeline 与 Group Accumulator

### 5.1 Dequant Token Queue

每个 group_done 产生：

```text
deq_token = {
  mode,
  head_tile_id,
  context_block_id, ; QK 使用
  group_id,
  partial_acc_bank_id,
  group_acc_bank_id,
  last_group,      ; QK 当前 context block / PV 当前 head tile 的最后一个逻辑 group
  last_ctx,        ; QK 当前 head tile 的最后一个 context block，PV 可置 0
  last_head,       ; 当前 task 的最后一个 head tile
  lane_valid_mask  ; QK 最后一个 context block 使用 tail mask，PV 固定全 1
}
```

token queue 深度建议 2-4。外部可把参数提前送入 `deq FIFO`；到 `group_done` 时，dequant
流水按顺序取出 token 和 FIFO 头部的 `{w0,w1}`。
`last_*` 字段由 `u_loop_nest_ctrl` 的预译码 flag 锁入，后级只消费 1-bit token meta，
不再访问 `context_ctr/head_ctr` 做边界宽比较。

### 5.2 Dequant Pipeline

```text
partial_acc_bank -> u_dequant -> dequant_result -> group_acc_bank
```

要求：

- dequant 可以多拍；
- dequant 与下一 group MAC 并行；
- dequant 必须从 `deq FIFO` 顺序消费一个 `{w0,w1}`；
- `group_acc += dequant_result` 完成后释放 partial_acc bank；
- 对同一个 QK context block / PV head tile 的 group_acc 按 group_id 顺序累加。

### 5.3 双 group_acc bank

为让 DRAIN 与下一 QK context block / PV head tile 的 MAC 解耦，建议 group_acc 也双 bank：

```text
group_acc_compute_bank : 当前 QK context block / PV head tile 累加
group_acc_drain_bank   : 已完成，等待 drain
```

QK context block done 或 PV head_tile_done 时：

```text
emit drain_token(group_acc_compute_bank, metadata)
swap compute/drain bank if drain bank free
```

如果 output queue 或 drain bank 满，才反压 dequant/MAC。

---

## 6. Drain Scheduler 与 Output Queue

V0.2 的 `DRAIN_A/O` 占用 SA_ENGINE。V0.3 把 drain 独立成 `u_drain_scheduler`。

### 6.1 Drain Token

```text
drain_token = {
  mode,             ; QK -> softmax, PV -> O writer
  head_tile_id,
  context_block_id, ; QK context block id
  group_acc_bank_id,
  lane_valid_mask,  ; QK tail block mask；PV 固定全 1
  valid_len[sa],
  use_output_lorenzo[sa],
  output_mode
}
```

### 6.2 Output Accumulator

更新后的输出累加器语义：

- FP16；
- 沿 PE lane (`drain_lane_ctr=0..31`) 做 factor-weighted 前缀乘加；
- 每个 drain token 开始时清零；
- `use_output_lorenzo[sa]` 决定输出 raw 还是 accumulated；
- 每个 SA 在每个 drain step 同步接收一个外部 `output_factor_fp8[sa]`。
- output 资源：每个 active SA 1 个 output mulacc，沿 `drain_lane_ctr=0..31` 逐拍分时复用；
  不按 PE lane 复制 32 份。

输出乘加语义：

```text
output_acc_term = raw_output_fp16 * output_factor_fp8
output_acc_next = output_acc_prev + cast_fp16(output_acc_term)
```

因此原先 `output_acc += raw_output` 的启动逻辑，更新为：

```text
output_mulacc_fire = drain_fire & output_factor_valid
output_acc_state   = output_acc_state + raw_output * output_factor_fp8
```

若 `output_lorenzo=0`，output factor 流可不消费，drain path 旁路 raw output；若
`output_lorenzo=1` 且 factor 未到，`drain_fire` 不成立并向上游反压。

### 6.3 Output Queue

drain 结果先进入 output queue，再送 softmax 或 O stream writer：

```text
group_acc_drain_bank -> output_acc -> output_queue -> softmax/O
```

这样下一 row/head 的 MAC 不需要等 softmax/O writer 完全接收完上一 row/head。
只有 output queue 满时，才通过 drain bank 反压上游。

---

## 7. QK Task 流水示例

理想 steady state：

```text
Cycle window N:
  MAC       : row t, group g+1
  Dequant   : row t, group g
  Drain     : row t-1
  Stream In : row t, group g+2 的 K/deq params；下一 head tile 的 Q line
```

抽象时序：

```text
Q/K read:    [g0 data][g1 data][g2 data][g3 data]...
MAC:             [g0 MAC][g1 MAC][g2 MAC][g3 MAC]...
Dequant:                 [g0 DQ][g1 DQ][g2 DQ]...
Drain row:                                  [row t drain]
Next row MAC:                              [row t+1 g0 MAC]...
```

不再需要：

```text
RECV_START_K
WAIT K_RECV
SA_RUN_QK
WAIT SA_ENGINE
DRAIN_A
WAIT SA_ENGINE
```

而是 task engine 内部根据 FIFO credit 维持 steady state。

---

## 8. PV Task 流水示例

steady state：

```text
P/V read:    [ctx g0][ctx g1][ctx g2]...
P acc:       shared input ACC in PV mode updates raw/acc lanes on p_fire with external FP8 factor
MAC:             [g0 MAC][g1 MAC][g2 MAC]...
Dequant:                 [g0 DQ][g1 DQ]...
Drain O:                              [head tile drain + output factor]
O write:                                    [stream out]
```

shared input accumulator 在 PV mode 下的 P_ACC 清零边界：

- 默认：每个 `head_tile_start` 清零；
- 若后续需要跨 tile 累加，可在 TDT extension 中增加 reset boundary 字段。

---

## 9. Backpressure 规则

V0.3 不承诺“无停顿”，而承诺“无软件阶段气泡”。停顿只来自真实资源不足：

| 资源不足 | 行为 |
|----------|------|
| 外部 Q/K/P/V 供数不足 | ingress FIFO/line invalid，MAC scheduler 停 |
| 外部 input_factor 供数不足 | `qp_fire` 不成立，input mulacc 停，并反压 `qp_in` |
| 外部 deq 参数供给不足 | deq FIFO 为空，dequant 流水停，并逐级反压 |
| 外部 output_factor 供数不足 | `drain_fire` 不成立，output mulacc 停，并通过 drain bank 反压上游 |
| dequant pipeline 慢 | partial_acc bank 无法释放，MAC scheduler 停 |
| output queue 满 | drain bank 无法释放，上游逐级反压 |
| softmax/O writer 不 ready | output queue 占用上升，最终反压 |
| Q line 未到 | 仅当前 dim token 停，不等待整个 tile |

所有停顿都通过 valid/ready/credit 传播，不需要微码插入中间 WAIT。

---

## 10. Scoreboard

V0.3 保留 V0.2 engine scoreboard 给 legacy mode，同时新增 task scoreboard：

```text
task_busy[15:0]
task_done[15:0]
task_error[15:0]
task_error_code[15:0][7:0]
```

内部 pipeline scoreboard：

```text
stream_credit_q/k/p/v
deq_fifo_level
partial_acc_bank_free[2]
group_acc_bank_free[2]
deq_token_queue_level
drain_token_queue_level
output_queue_level
```

`TASK_WAIT` 只看 `task_done/error`。内部 scoreboard 不暴露给微码，但可通过 CSR debug 读取。

---

## 11. CSR 扩展

建议新增：

| CSR | 说明 |
|-----|------|
| `csr_task_busy` | 当前 task busy bitmap |
| `csr_task_done` | task done sticky bitmap |
| `csr_task_error` | task error bitmap |
| `csr_task_error_code` | 最近错误码 |
| `csr_head_ctr` | debug snapshot |
| `csr_context_ctr` | debug snapshot |
| `csr_group_ctr` | debug snapshot |
| `csr_inner_ctr` | debug snapshot |
| `csr_stream_level_q/k/p/v` | FIFO/line buffer level |
| `csr_deq_fifo_level` | deq 参数 FIFO level |
| `csr_deq_queue_level` | dequant token queue level |
| `csr_output_queue_level` | output queue level |

---

## 12. 与 V0.2 模块的复用关系

| V0.2 模块 | V0.3 状态 |
|-----------|-----------|
| `u_sa_1x32[0:3]` | 复用 |
| `partial_acc` | 扩展为双 bank |
| `u_dequant` | 复用，外接 pipeline/token queue |
| `u_group_acc` | 扩展为双 bank |
| `u_output_acc` | 复用，由 drain scheduler 驱动 |
| K/V/P FIFO | 复用或加深 |
| Q ping-pong | 改为 line-valid ping-pong |
| `u_loop_ctrl` | legacy mode 保留；task mode 使用 `u_loop_nest_ctrl` |
| `u_cmd_dispatch` | legacy mode 保留；task mode 增加 `u_task_dispatch` |
| CDT Type A/C | 可保留给 legacy；task mode 使用 TDT + 外部 deq 参数流 |

---

## 13. RTL 实现建议

### 13.1 最小 V0.3

如果面积敏感，可先实现最小版本：

- TDT；
- task loop controller；
- deq FIFO；
- Q line-valid ping-pong；
- dequant token queue 深度 1；
- partial_acc 双 bank；
- drain 独立 engine；
- output queue 深度 2。

这已经能解决 V0.2 最主要的阶段气泡：dequant 与下一组 MAC、drain 与下一 row/head MAC 可以重叠。

### 13.2 高吞吐 V0.3

进一步优化：

- dequant pipeline 多 token；
- partial_acc/group_acc 3 bank；
- K/V/P FIFO 加深；
- Q prefetch 提前一个 head tile；
- output queue 4-8 entry；
- softmax/PV fused task graph。

---

## 14. 回答三个原始问题

### 问题 1：当前 ISA/microarch 能否一次编码配置 QK/PV 的多层循环

V0.2 能用 LOOP 和 `SA_RUN_* count` 表达多层循环，但不能称为“一次配置、硬件自动跑完整三层循环”。
它缺少 task descriptor、固定流契约下的自动边界判断和硬件 loop nest scheduler。

V0.3 可以：`TASK_START` 后，由 TDT 的 `num_heads/context_length/dim` 和外部固定流顺序
共同驱动完整循环。外部负责喂对数据，内部负责知道当前算到哪个 head/context/group/inner。

### 问题 2：是否已达到 TPU 式“简单控制 + 运行参数配置”

V0.2 没有完全达到。它是粗粒度微指令，不是 task-level 配置 ISA。

V0.3 的改进是：

- 新增 `TASK_START/TASK_WAIT`；
- 新增 TDT；
- loop/dequant/drain 边界由硬件判断；
- 微码只负责启动任务和最终等待。

### 问题 3：读数和计算之间是否仍有等待区间，如何彻底流水化

V0.2 有重叠，但仍可能在 Q READY、GROUP_DEQ、DRAIN、连续 receive window 之间产生气泡。

V0.3 的改进是：

- ingress FIFO/line buffer 持续接收；
- deq FIFO 按 group 持续喂入；
- Q line-valid 而非整 tile READY；
- partial_acc 双 bank，使 MAC 与 dequant 重叠；
- group_acc 双 bank + drain scheduler，使 drain 与下一 row/head MAC 重叠；
- output queue 解耦 softmax/O writer；
- loop counter 按 token fire 自动推进；
- 软件只在 task 末尾 `TASK_WAIT`。

最终效果是：只要外部供数、dequant、output sink 的吞吐足够，SA 可以保持连续 MAC；
任何停顿都来自真实资源 backpressure，而不是 ISA 调度造成的读算交替。
