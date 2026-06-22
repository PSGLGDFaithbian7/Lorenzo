# Lorenzo Task Engine V0.3 — 使用说明

> 乙方（B，30%）控制面 RTL 交付文档。  
> 覆盖 B1~B9 全部分工项，包含 RTL、Testbench 与 VCS+Verdi 仿真环境。

---

## 1. 目录结构

```
D:/Lorenzo/
├── document/               原始规格文档与参考实现
│   ├── microarchitecture_v03_task_engine_zh.md
│   ├── microinstruction_isa_v03_task_engine_zh.md
│   ├── rtl_design_spec_v03_task_engine_zh.md
│   ├── v03_task_engine_分工计划_7_3.md
│   └── u_loop_nest_control.sv   ← 计算次序基准参考
│
├── rtl/                    乙方 RTL（11 个文件，全部编译通过）
│   ├── lte_pkg.sv          共享包：常量、错误码、token/ctx 结构体
│   ├── lte_tdt_decode.sv   B5: TDT 解码 + 合法性检查
│   ├── lte_task_context.sv B2: 任务上下文锁存
│   ├── lte_loop_nest_ctrl.sv B3: 循环嵌套控制器（核心）
│   ├── lte_boundary_ctrl.sv  B4: 边界事件 + token 打包
│   ├── lte_task_dispatch.sv  B1: 任务派发 FSM
│   ├── lte_error_ctrl.sv     B8: 错误控制器
│   ├── lte_task_scoreboard.sv B6: 记分板
│   ├── lte_csr.sv            B7: CSR + debug snapshot
│   ├── lte_legacy_mux.sv     B9: [DEPRECATED] legacy 兼容 mux
│   └── lte_task_ctrl_top.sv  控制面集成 wrapper
│
├── tb/                     定向 Testbench（9 个文件）
│   ├── tb_lte_tdt_decode.sv
│   ├── tb_lte_task_context.sv
│   ├── tb_lte_loop_nest_ctrl.sv
│   ├── tb_lte_boundary_ctrl.sv
│   ├── tb_lte_task_dispatch.sv
│   ├── tb_lte_error_ctrl.sv
│   ├── tb_lte_task_scoreboard.sv
│   ├── tb_lte_csr.sv
│   └── tb_lte_task_ctrl_top.sv
│
└── sim/                    仿真环境
    ├── Makefile            VCS + Verdi 仿真脚本
    └── dump_ctrl.sv        FSDB 自动 dump（不改 TB 文件）
```

---

## 2. 环境依赖

| 工具 | 用途 | 最低版本建议 |
|------|------|-------------|
| VCS | SystemVerilog 编译仿真 | 2020.03+ |
| Verdi | 波形调试 | 同 VCS 版本 |
| bash / gmake | 构建脚本 | — |

如果工具不在 `$PATH`，在 `sim/Makefile` 顶部修改：

```makefile
VCS   ?= /your/path/to/vcs
VERDI ?= /your/path/to/verdi
```

---

## 3. 快速开始

```bash
cd D:/Lorenzo/sim
```

**一键跑集成测试（所有场景）并开波形：**

```bash
make run
```

**只跑某个子模块 TB：**

```bash
make run TB=tb_lte_loop_nest_ctrl
```

**分步操作：**

```bash
make comp TB=tb_lte_loop_nest_ctrl   # 编译，生成 simv_tb_lte_loop_nest_ctrl
make sim  TB=tb_lte_loop_nest_ctrl   # 仿真，生成 sim.fsdb + sim_*.log
make wave                            # 打开 Verdi 查看波形
```

**查看全部可用 TB：**

```bash
make help
```

---

## 4. 仿真输出说明

仿真结束后在 `sim/` 目录产生：

| 文件 | 内容 |
|------|------|
| `simv_<TB>` | 可执行仿真文件 |
| `sim.fsdb` | Verdi 波形文件（所有层次信号） |
| `comp.log` | 编译日志，检查 warning |
| `sim_<TB>.log` | 仿真输出，含 `[PASS]`/`[FAIL]` 结果 |

**快速判断结果：**

```bash
grep RESULT sim_tb_lte_task_ctrl_top.log
# [RESULT] tb_lte_task_ctrl_top: ALL PASS
```

**定位失败：**

```bash
grep FAIL sim_tb_lte_task_ctrl_top.log
# [FAIL][TC2_QK_TAIL] t=12345 blk0_mask: got=00000001 exp=ffffffff
```
每条 FAIL 都包含 **TC 名称 + 信号名 + 时间戳 + 实际值 vs 期望值**，直接在 Verdi 里跳到对应时间点即可。

---

## 5. Verdi 波形调试

打开波形后的建议操作：

1. **加载层次**：在 `Instance` 窗口展开 `tb_lte_task_ctrl_top → dut`，找到目标信号。
2. **跳到时间点**：日志里打出的 `t=12345`，在 Verdi 时间轴输入 `12345ns` 直接跳转。
3. **关键信号组**：建议把以下信号保存为 signal group（`.rc` 文件）方便复用：

```
# 控制核关键信号
task_start_o  engine_busy
head_ctr  context_ctr  group_ctr  inner_ctr
group_done_pulse  row_done_pulse  head_tile_done_pulse  task_done_pulse
deq_token_valid  deq_token_meta.last_group  deq_token_meta.last_ctx
mac_fire  group_done_accept  drain_fire
use_input_lorenzo  use_output_lorenzo
```

4. **FSDB 全层次**：`dump_ctrl.sv` 用 `$fsdbDumpvars(0,"")` 全层次 dump，所有内部信号可见。若波形文件过大，可改为只 dump 指定层次：

```sv
// 在 dump_ctrl.sv 里改为:
$fsdbDumpvars(2, "tb_lte_task_ctrl_top.dut");
```

---

## 6. 测试场景覆盖

### 子模块 TB

| TB 文件 | 核心验证点 |
|---------|----------|
| `tb_lte_tdt_decode` | 15 TC：合法 QK/PV(3种 head_dim) + 全部9种错误码 |
| `tb_lte_task_context` | launch 锁存、无 launch 不更新、valid_len 切片、flag bits |
| `tb_lte_loop_nest_ctrl` | inner/group/context/head 计数进位、tail mask、PV 短 inner、backpressure 憋住 |
| `tb_lte_boundary_ctrl` | 6类事件相位、QK/PV对比、token字段、`use_input_lorenzo` 动态切换 |
| `tb_lte_task_dispatch` | 正常启动、busy 拒绝、`wait_on_launch` 挂起、非法配置 |
| `tb_lte_error_ctrl` | cfg/bp 两路聚合、sticky、`csr_err_clear`、优先级 |
| `tb_lte_task_scoreboard` | busy/done/error bitmap、`wait_consume`、pipeline level 寄存 |
| `tb_lte_csr` | 读值正确性、snapshot 冻结、计数器变化不影响已拍快照 |

### 集成 TB（`tb_lte_task_ctrl_top`）

| TC | 场景 | 验证重点 |
|----|------|---------|
| TC1 | QK dim=64, ctx=64, heads=1 | group/row/head 事件计数、last flags |
| TC2 | QK dim=32, ctx=33（尾部不足） | 最后 block `lane_valid_mask`=0x1 |
| TC3 | PV head_dim=128, ctx=64 | PV 无 row_done、`head_tile_done` 时序 |
| TC4 | PV head_dim=64, ctx=33, pli=1, heads=2 | 最后 group 只1拍 inner 闭合 |
| TC5 | 非法 desc_type | `halted_error`=1，engine_busy=0 |
| TC6 | QK dim=32, heads=4（多 head 串行） | head_ctr 逐步递增，4次 row_done |

---

## 7. 甲乙方对接要点（快速索引）

> 完整接口时序见 `rtl/README.md §9`

**甲方必须做：**

1. `group_done_accept` — 在 dequant token 队列有空位时拉高；若在 `inner_ctr==31`（is_inner_last=1）那拍未拉高，控制核**自动憋住** MAC，直到拉高为止。
2. `engine_task_done` — 等 deq/drain/output 三个队列全排空后才拉高（1 拍脉冲），否则控制核卡在 RUN 状态，下一 `TASK_START` 会被 busy 拒绝。
3. `token 里的 last_*` — 下游不得重新访问 `context_ctr/head_ctr` 做宽比较，只消费 token 的 1-bit flag。

**乙方输出注意：**

- `use_input_lorenzo` / `use_output_lorenzo` 是**组合**输出，在整个 context_block（QK）或 context_group（PV）内稳定；只在 block/group 边界跳变（由 `lane_valid_mask` 是否全1 / `pv_last_inner_count` 是否=32 决定）。
- `deq_token_meta` / `drain_token_meta` 在对应 valid 有效的**同一拍**内必须采样，无寄存延迟。
- `partial_acc_bank_id` / `group_acc_bank_id` 不在 token 结构体里，由甲方出队时补齐。

---

## 8. 常见问题

**Q: 编译报 "cannot find module" 错误？**  
A: 确认 `lte_pkg.sv` 是第一个编译的文件。Makefile 里 `RTL_FILES` 已按顺序排列，直接用 `make` 即可。

**Q: 仿真卡住不结束？**  
A: 集成 TB 有 `#2000000` 超时保护，超时后打印 `[TIMEOUT]` 并 `$finish`。子模块 TB 若卡住，检查 `engine_task_done` 是否被给出（集成 TB 里 A 侧模型必须在 `task_done_pulse` 后给 `engine_task_done`）。

**Q: Verdi 打不开 `.fsdb`？**  
A: 先确认 `sim.fsdb` 存在（`ls sim.fsdb`），然后确认 Verdi 版本与 VCS 匹配。也可以直接 `make wave` 让 Makefile 自动检查。

**Q: 想只 dump 特定信号节省磁盘？**  
A: 修改 `sim/dump_ctrl.sv`，把 `$fsdbDumpvars(0,"")` 改为 `$fsdbDumpvars(2, "tb_lte_task_ctrl_top.dut.u_loop_nest")` 等更精确的路径。

**Q: B9 `lte_legacy_mux` 要不要集成？**  
A: 不需要。项目已全面转 V0.3，顶层 `lte_task_ctrl_top` 直接驱动 datapath，不实例化 legacy mux。该文件保留供未来参考，标注了 `[DEPRECATED]`。
