//==============================================================================
// lte_loop_nest_ctrl.sv   (分工项 B3: 循环嵌套控制器 —— 乙方最核心模块)
//------------------------------------------------------------------------------
// 本模块严格沿用经过 review 的参考实现 u_loop_nest_control.sv 的【计算次序】,
// 仅做工程化整理:
//   - 模块更名 u_loop_next_ctrl -> lte_loop_nest_ctrl, 位宽改用 lte_pkg
//   - 额外暴露内部进位/触发脉冲 (group_done_fire / qk_block_done_fire /
//     head_step_fire / task_done_fire), 供 lte_boundary_ctrl 直接消费,
//     避免边界控制器重复搭一条跨层比较链。  ★ 不改变任何计数/进位次序 ★
//
// 设计哲学 (微架构 §2.2):
//   - 不写多层嵌套大 FSM, 而是 loop-carry controller:
//     每层 = 本层 counter + 本层等值比较 + 1-bit carry/end。
//   - 跨层组合链只传 1-bit, 不传宽计数器比较结果。
//   - MAC 热路径只含 inner/group 两层; context/head 由下游 group_done_accept 推进。
//   - last 用电平, end = last & 真实 fire (脉冲), 防止后级没接受时 last 长期为高
//     导致计数器空转 —— 这是把 "电平 last" 转成 "单拍 end 脉冲" 的关键。
//
// 关于"片外预算"约束: 本模块入口的 qk_dim_group_count / qk_context_block_count /
// pv_context_group_count / qk_context_tail_mask / pv_last_inner_count 全部是 Host
// 片外算好(除法/求余/ceil)后配置进来的, 片上只做 -1 与等值比较, 无除法/求余。
//==============================================================================
import lte_pkg::*;

module lte_loop_nest_ctrl #(
    parameter int GROUP_SIZE_MAX           = lte_pkg::GROUP_SIZE_MAX,
    parameter int HEAD_NUM_MAX             = lte_pkg::HEAD_NUM_MAX,
    parameter int QK_CONTEXT_BLOCK_NUM_MAX = lte_pkg::QK_CONTEXT_BLOCK_NUM_MAX,
    parameter int QK_DIM_GROUP_NUM_MAX     = lte_pkg::QK_DIM_GROUP_NUM_MAX,
    parameter int PV_CONTEXT_GROUP_NUM_MAX = lte_pkg::PV_CONTEXT_GROUP_NUM_MAX,
    parameter int DRAIN_LANE_NUM           = lte_pkg::DRAIN_LANE_NUM,
    parameter int PARALLEL_MAX             = lte_pkg::PARALLEL_MAX
) (
    input  logic clk,
    input  logic rst_n,

    // 任务启动 + QK/PV 模式选择
    // (本设计定义: 竖着划分为 group, 横着划分为 block)
    input  logic       task_start,
    input  logic [1:0] task_mode,    // 0: QK, 1: PV

    // Host 预算好的循环常量 (片外算好配置进来)
    input  logic [$clog2(HEAD_NUM_MAX+1)-1:0]             num_heads,
    input  logic [$clog2(QK_DIM_GROUP_NUM_MAX+1)-1:0]     qk_dim_group_count,
    input  logic [$clog2(QK_CONTEXT_BLOCK_NUM_MAX+1)-1:0] qk_context_block_count,
    input  logic [DRAIN_LANE_NUM-1:0]                     qk_context_tail_mask,
    input  logic [$clog2(PV_CONTEXT_GROUP_NUM_MAX+1)-1:0] pv_context_group_count,
    input  logic [$clog2(GROUP_SIZE_MAX+1)-1:0]           pv_last_inner_count,
    input  logic [$clog2(PARALLEL_MAX+1)-1:0]             hp_parallel,

    // MAC 侧: 热路径只允许 inner/group 两个计数器
    input  logic mac_fire,           // MAC 完成一次乘加返回一次 fire
    // group-done 的同拍接受: 逻辑 group 的最后一个 MAC beat 只有在下游可接受
    // group-done token 时才发射, 防止低层计数器跑到 token 路径前面。
    input  logic group_done_accept,
    // drain 侧独立于 MAC 调度: 一条 lane 输出一个就 fire 一次
    input  logic drain_fire,

    // ---- 对外计数状态展示 ----
    output logic [$clog2(HEAD_NUM_MAX)-1:0]             head_ctr_o,
    output logic [$clog2(QK_CONTEXT_BLOCK_NUM_MAX)-1:0] context_ctr_o,
    output logic [$clog2(PV_CONTEXT_GROUP_NUM_MAX)-1:0] group_ctr_o,
    output logic [$clog2(GROUP_SIZE_MAX)-1:0]           inner_ctr_o,
    output logic [$clog2(DRAIN_LANE_NUM)-1:0]           drain_lane_ctr_o,

    // ---- 各层 last 状态 (本地 predecode/status, 下游优先用 token.last_*) ----
    output logic is_inner_last,
    output logic is_group_last,
    output logic is_context_block_last,
    output logic is_head_tile_last,
    output logic is_task_last,

    // ---- group_done token 的 1-bit meta (供 boundary_ctrl 打包) ----
    output logic                      group_done_valid,
    output logic                      group_done_last_group,
    output logic                      group_done_last_ctx,
    output logic                      group_done_last_head,
    output logic [DRAIN_LANE_NUM-1:0] group_done_lane_valid_mask,

    // ---- ★ 新增: 暴露内部进位脉冲, 供 lte_boundary_ctrl 直接映射事件 ----
    output logic group_done_fire_o,    // 一个逻辑 group 真正被 dequant 接受
    output logic qk_block_done_fire_o, // QK 一个 context block 完成 (= row_done)
    output logic head_step_fire_o,     // 一个 head tile 完成 (= head_tile_done)
    output logic task_done_fire_o      // 整个 task 完成
);

  localparam logic [1:0] TASK_MODE_QK = 2'd0;
  localparam logic [1:0] TASK_MODE_PV = 2'd1;

  localparam int HEAD_W       = $clog2(HEAD_NUM_MAX);
  localparam int HEAD_COUNT_W = $clog2(HEAD_NUM_MAX+1);
  localparam int QK_CTX_W     = $clog2(QK_CONTEXT_BLOCK_NUM_MAX);
  localparam int QK_GRP_W     = $clog2(QK_DIM_GROUP_NUM_MAX);
  localparam int PV_GRP_W     = $clog2(PV_CONTEXT_GROUP_NUM_MAX);
  localparam int GROUP_CTR_W  = (QK_GRP_W > PV_GRP_W) ? QK_GRP_W : PV_GRP_W;
  localparam int INNER_W      = $clog2(GROUP_SIZE_MAX);
  localparam int DRAIN_W      = $clog2(DRAIN_LANE_NUM);

  // 状态机状态
  typedef enum logic {
    TASK_IDLE = 1'b0,
    TASK_RUN  = 1'b1
  } state_e;
  state_e state_q, state_d;

  //----------------------------------------------------------------------------
  // 内部计数器 (5 个): head / context_block / group / inner / drain_lane
  //----------------------------------------------------------------------------
  logic [HEAD_W-1:0]      head_ctr_q;
  logic [QK_CTX_W-1:0]    context_ctr_q;
  logic [GROUP_CTR_W-1:0] group_ctr_q;
  logic [INNER_W-1:0]     inner_ctr_q;
  logic [DRAIN_W-1:0]     drain_lane_ctr_q;

  // predecode flag
  logic context_last_q;
  logic head_last_q;

  logic [GROUP_CTR_W-1:0]  group_max_minus1;
  logic [INNER_W-1:0]      pv_last_inner_minus1;
  logic [HEAD_COUNT_W-1:0] next_head_ctr_ext;
  logic [HEAD_COUNT_W-1:0] head_after_next_tile_ext;
  logic                    next_head_is_last;
  logic                    next_context_is_last;

  logic task_active;
  logic qk_mode;
  logic pv_mode;

  logic group_last_c;
  logic inner_last_c;
  logic mac_step_fire;
  logic inner_end;
  logic group_end;
  logic group_done_fire;
  logic qk_block_done_fire;
  logic pv_tile_done_fire;
  logic head_step_fire;
  logic task_done_fire;

  logic [DRAIN_LANE_NUM-1:0] current_lane_valid_mask;

  // TASK_RUN 时置高 active, 代表正在工作
  assign task_active = (state_q == TASK_RUN);
  // 模式选择
  assign qk_mode = (task_mode == TASK_MODE_QK);
  assign pv_mode = (task_mode == TASK_MODE_PV);

  // group 计数上限: QK=dim_group, PV=context_group, 含义随 mode 不同
  always_comb begin
    if (qk_mode) begin
      group_max_minus1 = GROUP_CTR_W'(qk_dim_group_count - 1'b1);
    end else begin
      group_max_minus1 = GROUP_CTR_W'(pv_context_group_count - 1'b1);
    end
  end

  // group last: 计数器到达上限的电平 (需结合运算级反馈才发 end)
  assign group_last_c = (group_ctr_q == group_max_minus1);

  // inner last: QK 固定到 31; PV 最后一组用 pv_last_inner_count 提前闭合
  always_comb begin
    pv_last_inner_minus1 = INNER_W'(pv_last_inner_count - 1'b1);
    if (qk_mode) begin
      inner_last_c = (inner_ctr_q == INNER_W'(GROUP_SIZE_MAX-1));
    end else if (group_last_c) begin
      inner_last_c = (inner_ctr_q == pv_last_inner_minus1);
    end else begin
      inner_last_c = (inner_ctr_q == INNER_W'(GROUP_SIZE_MAX-1));
    end
  end

  // 逻辑 group 的最后一个 inner beat: MAC step 与 group-done accept 必须同拍,
  // 防止低层计数器跑到 group-done token 路径前面。
  assign mac_step_fire = task_active && mac_fire && (!inner_last_c || group_done_accept);

  // end = last && 真实 fire; 低层计数器只在 end 时向上进位
  assign inner_end = mac_step_fire && inner_last_c;
  assign group_end = inner_end;

  // QK 最后一个 context block 的 lane 不一定全有效, 用 tail mask
  assign current_lane_valid_mask =
      (qk_mode && context_last_q) ? qk_context_tail_mask : {DRAIN_LANE_NUM{1'b1}};

  //----------------------------------------------------------------------------
  // 顶层状态机
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_q <= TASK_IDLE;
    else        state_q <= state_d;
  end

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      TASK_IDLE: if (task_start)     state_d = TASK_RUN;
      TASK_RUN:  if (task_done_fire) state_d = TASK_IDLE;
      default:                       state_d = TASK_IDLE;
    endcase
  end

  //----------------------------------------------------------------------------
  // MAC 侧热计数器: inner / group (只由 mac 推进)
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      inner_ctr_q <= '0;
      group_ctr_q <= '0;
    end else if (task_start) begin
      inner_ctr_q <= '0;
      group_ctr_q <= '0;
    end else if (task_active) begin
      if (mac_step_fire) begin
        inner_ctr_q <= inner_last_c ? '0 : inner_ctr_q + 1'b1;
      end
      // group_end 进位; 用 end 而非 last, 后级没反应时不会让 group 一直自增
      if (group_end) begin
        group_ctr_q <= group_last_c ? '0 : group_ctr_q + 1'b1;
      end
    end
  end

  //----------------------------------------------------------------------------
  // 逐层进位链 (跨层只与 1-bit)
  //----------------------------------------------------------------------------
  // 一个 group 计算完成且被 dequant 接受
  assign group_done_fire    = task_active && group_end && group_done_accept;
  // QK: 一个 context block 完成
  assign qk_block_done_fire = qk_mode && group_done_fire && group_done_last_group;
  // PV: 一个 context_group 完成, 等价于一个 head tile 完成
  assign pv_tile_done_fire  = pv_mode && group_done_fire && group_done_last_group;
  // 一个 head tile
  assign head_step_fire     = (qk_block_done_fire && group_done_last_ctx) || pv_tile_done_fire;
  // 一个 task
  assign task_done_fire     = head_step_fire && group_done_last_head;

  // context_block 计数器 (QK 专用), 由 retire(block done) 推进
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)              context_ctr_q <= '0;
    else if (task_start)     context_ctr_q <= '0;
    else if (qk_block_done_fire)
      context_ctr_q <= context_last_q ? '0 : context_ctr_q + 1'b1;
  end

  // head 计数器, 考虑 PV 多头并行步长 hp_parallel
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)              head_ctr_q <= '0;
    else if (task_start)     head_ctr_q <= '0;
    else if (head_step_fire)
      head_ctr_q <= head_last_q ? '0 : next_head_ctr_ext[HEAD_W-1:0];
  end

  always_comb begin
    // PV 阶段下一批次到第几个 head
    next_head_ctr_ext        = HEAD_COUNT_W'(head_ctr_q) + HEAD_COUNT_W'(hp_parallel);
    // 再下一批次到第几个 head
    head_after_next_tile_ext = next_head_ctr_ext + HEAD_COUNT_W'(hp_parallel);
    // 判定下一批是否最后一个 head 批次
    next_head_is_last        = (head_after_next_tile_ext >= HEAD_COUNT_W'(num_heads));
    // 判定下一个 context block 是否最后一个
    next_context_is_last     = (context_ctr_q + 1'b1 == QK_CTX_W'(qk_context_block_count - 1'b1));
  end

  // 寄存的 predecode flag; token 打包只消费这两个 1-bit
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      context_last_q <= 1'b0;
      head_last_q    <= 1'b0;
    end else if (task_start) begin
      context_last_q <= (qk_context_block_count <= 1);
      head_last_q    <= (hp_parallel >= num_heads);
    end else begin
      if (qk_block_done_fire) begin
        context_last_q <= context_last_q ? (qk_context_block_count <= 1) : next_context_is_last;
      end
      if (head_step_fire) begin
        head_last_q <= head_last_q ? (hp_parallel >= num_heads) : next_head_is_last;
      end
    end
  end

  // MAC 输出 (drain) 计数器, 独立于 MAC 调度
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)              drain_lane_ctr_q <= '0;
    else if (task_start)     drain_lane_ctr_q <= '0;
    else if (task_active && drain_fire)
      drain_lane_ctr_q <= (drain_lane_ctr_q == DRAIN_W'(DRAIN_LANE_NUM-1)) ?
                          '0 : drain_lane_ctr_q + 1'b1;
  end

  //----------------------------------------------------------------------------
  // 对外输出
  //----------------------------------------------------------------------------
  assign group_done_valid           = group_end;
  assign group_done_last_group      = group_last_c;
  assign group_done_last_ctx        = context_last_q;
  assign group_done_last_head       = head_last_q;
  assign group_done_lane_valid_mask = current_lane_valid_mask;

  assign is_inner_last         = inner_last_c;
  assign is_group_last         = group_last_c;
  assign is_context_block_last = qk_mode && context_last_q;
  assign is_head_tile_last     = qk_mode ? (context_last_q && group_last_c) : group_last_c;
  assign is_task_last          = is_head_tile_last && head_last_q;

  assign head_ctr_o       = head_ctr_q;
  assign context_ctr_o    = context_ctr_q;
  assign group_ctr_o      = group_ctr_q[$clog2(PV_CONTEXT_GROUP_NUM_MAX)-1:0];
  assign inner_ctr_o      = inner_ctr_q;
  assign drain_lane_ctr_o = drain_lane_ctr_q;

  // 暴露内部进位脉冲
  assign group_done_fire_o    = group_done_fire;
  assign qk_block_done_fire_o = qk_block_done_fire;
  assign head_step_fire_o     = head_step_fire;
  assign task_done_fire_o     = task_done_fire;

endmodule : lte_loop_nest_ctrl
