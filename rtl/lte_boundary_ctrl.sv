//==============================================================================
// lte_boundary_ctrl.sv   (分工项 B4: 边界控制器)
//------------------------------------------------------------------------------
// 功能 (微架构 §2.3 / RTL Design Spec §5.4):
//   边界事件生成 + dequant/drain token 打包 (同前)。
//
// 变更 (相对初版):
//   full_pe_active / use_*_lorenzo 改为动态计算, 不再用 task_context 的静态锁存值。
//
//   判定规则:
//     QK: full_pe_active = lane_valid_mask 全 1
//         → 非最后一个 context_block 恒为真; 最后一个 block 若 tail_mask 非全 1 则假
//     PV: full_pe_active = 非最后一个 context_group, 或最后一组 pv_last_inner_count==32
//         → 只有最后一个 group 且 inner 不足 32 时才假
//
//   lane_valid_mask 来自 loop_nest (已是 context_last_q ? tail_mask : 32'hFFFF_FFFF),
//   是跨 group 稳定的寄存信号, 可直接用于 MAC 侧的 full_pe_active 判断。
//==============================================================================
import lte_pkg::*;

module lte_boundary_ctrl (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      task_start,
    input  logic [1:0]                task_mode,

    // ---- 来自 lte_loop_nest_ctrl 的进位脉冲 ----
    input  logic                      group_done_fire,
    input  logic                      qk_block_done_fire,
    input  logic                      head_step_fire,
    input  logic                      task_done_fire,

    // ---- 来自 loop_nest 的计数器 / 1-bit meta ----
    input  logic [HEAD_W-1:0]         head_ctr,
    input  logic [QK_CTX_W-1:0]       context_ctr,
    input  logic [GROUP_CTR_W-1:0]    group_ctr,
    input  logic                      group_done_last_group,
    input  logic                      group_done_last_ctx,
    input  logic                      group_done_last_head,
    // 当前 lane_valid_mask: QK=(context_last_q ? tail_mask : 全1), PV=全1
    // 跨 group 稳定 (由 loop_nest 内的寄存 context_last_q 驱动)
    input  logic [DRAIN_LANE_NUM-1:0] group_done_lane_valid_mask,

    // ---- 来自 task_context 的静态配置 ----
    input  logic [7:0]                output_mode,
    // Lorenzo 全局开关 (task 级常量)
    input  logic                      flag_in_lz,
    input  logic                      flag_in_lz_full_only,
    input  logic                      flag_out_lz,
    input  logic                      flag_out_lz_full_only,
    // PV 最后一组有效 inner 数 (Host 预算, 用于 PV full_pe_active 判定)
    input  logic [5:0]                pv_last_inner_count,

    // ---- 边界清零 / 切换事件 (1 拍脉冲) ----
    output logic                      head_tile_start,
    output logic                      row_start,
    output logic                      group_start,
    output logic                      group_done_pulse,
    output logic                      row_done_pulse,
    output logic                      head_tile_done_pulse,
    output logic                      task_done_pulse,

    // ---- dequant token (控制面字段) ----
    output logic                      deq_token_valid,
    output deq_token_meta_t           deq_token_meta,

    // ---- drain token (控制面字段) ----
    output logic                      drain_token_valid,
    output drain_token_meta_t         drain_token_meta,

    // ---- 动态 Lorenzo 选择 (当拍有效, 供 MAC scheduler / drain scheduler 直接用) ----
    // full_pe_active: 当前 block/group 数据是否填满 32 lane/inner
    output logic                      full_pe_active,
    // use_*_lorenzo: 全局开关 & 动态 full_pe 的组合, 对全部 active SA 相同
    output logic                      use_input_lorenzo,
    output logic                      use_output_lorenzo
);

  logic qk_mode;
  assign qk_mode = (task_mode == TASK_MODE_QK);

  //----------------------------------------------------------------------------
  // 1. 清零 / 启动脉冲
  //----------------------------------------------------------------------------
  logic group_start_done_q;
  logic row_start_done_q;
  logic head_tile_start_done_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      group_start_done_q     <= 1'b0;
      row_start_done_q       <= 1'b0;
      head_tile_start_done_q <= 1'b0;
    end else begin
      group_start_done_q     <= group_done_fire    & ~task_done_fire;
      row_start_done_q       <= qk_block_done_fire & ~task_done_fire;
      head_tile_start_done_q <= head_step_fire     & ~task_done_fire;
    end
  end

  assign group_start     = task_start | group_start_done_q;
  assign row_start       = (qk_mode & task_start) | row_start_done_q;
  assign head_tile_start = task_start | head_tile_start_done_q;

  //----------------------------------------------------------------------------
  // 2. 完成脉冲
  //----------------------------------------------------------------------------
  logic group_done_pulse_q;
  logic row_done_pulse_q;
  logic head_tile_done_pulse_q;
  logic task_done_pulse_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      group_done_pulse_q     <= 1'b0;
      row_done_pulse_q       <= 1'b0;
      head_tile_done_pulse_q <= 1'b0;
      task_done_pulse_q      <= 1'b0;
    end else begin
      group_done_pulse_q     <= group_done_fire;
      row_done_pulse_q       <= qk_mode & qk_block_done_fire;
      head_tile_done_pulse_q <= head_step_fire;
      task_done_pulse_q      <= task_done_fire;
    end
  end

  assign group_done_pulse     = group_done_pulse_q;
  assign row_done_pulse       = row_done_pulse_q;
  assign head_tile_done_pulse = head_tile_done_pulse_q;
  assign task_done_pulse      = task_done_pulse_q;

  //----------------------------------------------------------------------------
  // 3. 动态 full_pe_active 判定
  //
  //   QK: lane_valid_mask 是否全 1
  //       - 非最后 context_block: loop_nest 输出 32'hFFFF_FFFF → 全 1 → true
  //       - 最后 context_block:   loop_nest 输出 tail_mask   → 看 Host 配的值
  //
  //   PV: 非最后 context_group 必定 32 个 inner → true
  //       最后 context_group 看 pv_last_inner_count 是否为 32
  //----------------------------------------------------------------------------
  always_comb begin
    if (qk_mode) begin
      full_pe_active = (group_done_lane_valid_mask == {DRAIN_LANE_NUM{1'b1}});
    end else begin
      // PV: 非最后 group 恒满; 最后 group 看 inner count
      full_pe_active = !group_done_last_group ||
                       (pv_last_inner_count == 6'(GROUP_SIZE_MAX));
    end
  end

  // use_*_lorenzo: 全局开关 AND (非 full_only 模式 OR 当前 block/group 恰好满)
  // 对所有 active SA 相同 (因为 full_pe 是 block/group 级, 非 SA 级)
  assign use_input_lorenzo  = flag_in_lz  && (!flag_in_lz_full_only  || full_pe_active);
  assign use_output_lorenzo = flag_out_lz && (!flag_out_lz_full_only || full_pe_active);

  //----------------------------------------------------------------------------
  // 4. dequant token 打包 (group_done 那一拍)
  //----------------------------------------------------------------------------
  logic deq_token_valid_q;
  deq_token_meta_t deq_token_meta_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      deq_token_valid_q <= 1'b0;
      deq_token_meta_q  <= '0;
    end else begin
      deq_token_valid_q <= group_done_fire;
      if (group_done_fire) begin
        deq_token_meta_q                  <= '0;
        deq_token_meta_q.mode             <= ~qk_mode;
        deq_token_meta_q.head_tile_id     <= head_ctr;
        deq_token_meta_q.context_block_id <= context_ctr;
        deq_token_meta_q.group_id         <= group_ctr;
        deq_token_meta_q.last_group       <= group_done_last_group;
        deq_token_meta_q.last_ctx         <= group_done_last_ctx;
        deq_token_meta_q.last_head        <= group_done_last_head;
        deq_token_meta_q.lane_valid_mask  <= group_done_lane_valid_mask;
      end
    end
  end

  assign deq_token_valid = deq_token_valid_q;
  assign deq_token_meta  = deq_token_meta_q;

  //----------------------------------------------------------------------------
  // 5. drain token 打包 (QK: row_done; PV: head_tile_done)
  //----------------------------------------------------------------------------
  logic drain_token_valid_q;
  drain_token_meta_t drain_token_meta_q;
  logic drain_token_fire;

  assign drain_token_fire = qk_mode ? qk_block_done_fire : head_step_fire;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      drain_token_valid_q <= 1'b0;
      drain_token_meta_q  <= '0;
    end else begin
      drain_token_valid_q <= drain_token_fire;
      if (drain_token_fire) begin
        drain_token_meta_q                  <= '0;
        drain_token_meta_q.mode             <= ~qk_mode;
        drain_token_meta_q.head_tile_id     <= head_ctr;
        drain_token_meta_q.context_block_id <= context_ctr;
        drain_token_meta_q.lane_valid_mask  <= qk_mode ? group_done_lane_valid_mask
                                                        : {DRAIN_LANE_NUM{1'b1}};
        drain_token_meta_q.output_mode      <= output_mode;
      end
    end
  end

  assign drain_token_valid = drain_token_valid_q;
  assign drain_token_meta  = drain_token_meta_q;

endmodule : lte_boundary_ctrl
