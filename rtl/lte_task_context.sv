//==============================================================================
// lte_task_context.sv   (分工项 B2: 任务上下文锁存)
//------------------------------------------------------------------------------
// 功能 (微架构 §2.1 / RTL Design Spec §5.2):
//   - 在 task_launch 那一拍, 把 lte_tdt_decode 解出的字段 + PE descriptor 一次性
//     锁存为本 task 的运行常量 (task_ctx_t)。
//   - 计算 active_sa_count (有效 SA 数 1..4)。
//   - 输出 Lorenzo 全局开关 flag bits 给 lte_boundary_ctrl 做动态判断。
//
// 设计要点:
//   - full_pe_active / use_*_lorenzo 是运行期动态量 (随 context_block/context_group
//     变化), 不在此静态锁存 —— 由 lte_boundary_ctrl 在每次 token 打包时实时计算。
//   - 此模块只锁存"整个 task 期间不变"的配置常量。
//   - 片上不做除法/求余, 循环常量全来自 Host 预算字段。
//==============================================================================
import lte_pkg::*;

module lte_task_context (
    input  logic                 clk,
    input  logic                 rst_n,

    // dispatch 在 LAUNCH 状态发出的锁存脉冲 (1 拍)
    input  logic                 task_launch,

    // ---- 来自 lte_tdt_decode 的解码字段 ----
    input  logic [1:0]           task_mode_i,
    input  logic [7:0]           flags_i,
    input  logic [15:0]          num_heads_i,
    input  logic [15:0]          context_length_i,
    input  logic [15:0]          dim_i,
    input  logic [15:0]          head_dim_i,
    input  logic [7:0]           group_size_i,
    input  logic [7:0]           sa_per_head_i,
    input  logic [7:0]           hp_parallel_i,
    input  logic [7:0]           q_buffer_policy_i,
    input  logic [7:0]           output_mode_i,
    input  logic [7:0]           stream_contract_i,
    input  logic [7:0]           deq_prefill_hint_i,
    input  logic [15:0]          qk_dim_group_count_i,
    input  logic [15:0]          qk_context_block_count_i,
    input  logic [31:0]          qk_context_tail_mask_i,
    input  logic [15:0]          pv_context_group_count_i,
    input  logic [5:0]           pv_last_inner_count_i,
    input  logic [7:0]           last_head_count_i,

    // ---- PE descriptor (128-bit, per-SA {mask_mode[1b], valid_len[6b]}) ----
    input  logic [127:0]         pe_desc_rdata,

    // ---- 锁存后的 task 配置 ----
    output task_ctx_t            task_ctx_o,

    // ---- per-SA valid_len (静态, 来自 PE descriptor) ----
    output logic [NUM_SA-1:0][VALID_LEN_W-1:0] valid_len_o,

    // ---- Lorenzo 全局开关 (task 级静态, 供 boundary_ctrl 动态合并) ----
    // boundary_ctrl 用这 4 bit + 运行期 full_pe_active 算出动态 use_*_lorenzo
    output logic                 flag_in_lz_o,           // flags[0]
    output logic                 flag_in_lz_full_only_o, // flags[1]
    output logic                 flag_out_lz_o,          // flags[2]
    output logic                 flag_out_lz_full_only_o // flags[3]
);

  //----------------------------------------------------------------------------
  // 组合: 从 pe_desc 切出 per-SA valid_len
  //   pe_desc 按 8-bit/SA 对齐: [5:0]=valid_len, [6]=mask_mode
  //----------------------------------------------------------------------------
  logic [NUM_SA-1:0][VALID_LEN_W-1:0] valid_len_c;

  genvar gs;
  generate
    for (gs = 0; gs < NUM_SA; gs++) begin : g_sa_desc
      assign valid_len_c[gs] = pe_desc_rdata[gs*PE_DESC_STRIDE +: VALID_LEN_W];
    end
  endgenerate

  // Full head tile active SA count. The runtime value for the final head tile is
  // selected later in lte_loop_nest_ctrl using last_head_count.
  logic [7:0] full_active_sa_count_c;
  always_comb begin
    if (task_mode_i == TASK_MODE_PV)
      full_active_sa_count_c = hp_parallel_i * sa_per_head_i;
    else
      full_active_sa_count_c = hp_parallel_i;
  end

  //----------------------------------------------------------------------------
  // 时序锁存: 仅在 task_launch 脉冲那一拍更新
  //----------------------------------------------------------------------------
  task_ctx_t                           ctx_q;
  logic [NUM_SA-1:0][VALID_LEN_W-1:0] valid_len_q;
  logic [3:0]                          lz_flags_q;   // {out_full_only, out_lz, in_full_only, in_lz}

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctx_q       <= '0;
      valid_len_q <= '0;
      lz_flags_q  <= '0;
    end else if (task_launch) begin
      ctx_q.task_mode              <= task_mode_i;
      ctx_q.num_heads              <= num_heads_i;
      ctx_q.context_length         <= context_length_i;
      ctx_q.dim                    <= dim_i;
      ctx_q.head_dim               <= head_dim_i;
      ctx_q.group_size             <= group_size_i;
      ctx_q.sa_per_head            <= sa_per_head_i;
      ctx_q.hp_parallel            <= hp_parallel_i;
      ctx_q.flags                  <= flags_i;
      ctx_q.q_buffer_policy        <= q_buffer_policy_i;
      ctx_q.output_mode            <= output_mode_i;
      ctx_q.stream_contract        <= stream_contract_i;
      ctx_q.deq_prefill_hint       <= deq_prefill_hint_i;
      ctx_q.qk_dim_group_count     <= qk_dim_group_count_i;
      ctx_q.qk_context_block_count <= qk_context_block_count_i;
      ctx_q.qk_context_tail_mask   <= qk_context_tail_mask_i;
      ctx_q.pv_context_group_count <= pv_context_group_count_i;
      ctx_q.pv_last_inner_count    <= pv_last_inner_count_i;
      ctx_q.active_sa_count        <= full_active_sa_count_c;
      ctx_q.last_head_count        <= last_head_count_i;

      valid_len_q <= valid_len_c;
      lz_flags_q  <= flags_i[3:0];
    end
  end

  assign task_ctx_o               = ctx_q;
  assign valid_len_o              = valid_len_q;
  assign flag_in_lz_o             = lz_flags_q[0];
  assign flag_in_lz_full_only_o   = lz_flags_q[1];
  assign flag_out_lz_o            = lz_flags_q[2];
  assign flag_out_lz_full_only_o  = lz_flags_q[3];

endmodule : lte_task_context
