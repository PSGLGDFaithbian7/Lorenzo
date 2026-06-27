//==============================================================================
// lte_tdt_decode.sv   (分工项 B5: TDT 解码 + 合法性检查)
//------------------------------------------------------------------------------
// 功能:
//   - 把 256-bit TDT entry 按 ISA §3 的字段切片解码为命名信号
//   - 做一次性合法性检查 (ISA §9), 产生 1-bit cfg_legal + 8-bit cfg_error_code
//
// 设计要点:
//   - 纯组合逻辑。本模块只在 TASK_START 那一拍被 dispatch 采样, 不在数据热路径上,
//     因此这里出现的少量定值比较 (dim[4:0]==0, hp_parallel*head_dim==128 等) 都是
//     一次性、低频的检查, 不违反"热路径无除法/求余"的约束。
//   - 真正需要除法/求余的循环常量 (dim/32, ceil(ctx/32)) 由 Host 片外算好后,
//     已经以 qk_dim_group_count / qk_context_block_count / pv_context_group_count
//     字段直接进来, 本模块只做"一致性可选检查", 不重新推导。
//==============================================================================
import lte_pkg::*;

module lte_tdt_decode (
    // 原始 TDT entry (256-bit)
    //原始的TDT是一个由配置信息组成的长指令
    input  logic [255:0] tdt_rdata,

    // ---- 解码输出 (命名字段, 给 lte_task_context 锁存) ----
    output logic [3:0]   desc_type_o,
    output logic [1:0]   task_mode_o,
    output logic [7:0]   flags_o,
    output logic [15:0]  num_heads_o,
    output logic [15:0]  context_length_o,
    output logic [15:0]  dim_o,
    output logic [15:0]  head_dim_o,
    output logic [7:0]   group_size_o,
    output logic [7:0]   sa_per_head_o,
    output logic [7:0]   hp_parallel_o,
    output logic [7:0]   pe_desc_id_o,
    output logic [7:0]   q_buffer_policy_o,
    output logic [7:0]   output_mode_o,
    output logic [7:0]   stream_contract_o,
    output logic [7:0]   deq_prefill_hint_o,
    output logic [15:0]  qk_dim_group_count_o,
    output logic [15:0]  qk_context_block_count_o,
    output logic [31:0]  qk_context_tail_mask_o,
    output logic [15:0]  pv_context_group_count_o,
    output logic [5:0]   pv_last_inner_count_o,
    output logic [7:0]   last_head_count_o,

    // ---- 合法性结果 ----
    output logic         cfg_legal_o,       // 1=全部检查通过
    output logic [7:0]   cfg_error_code_o   // 第一个命中的错误码 (优先级见下)
);

  //----------------------------------------------------------------------------
  // 字段切片 (ISA §3, TDT = 16 x 256-bit)
  //----------------------------------------------------------------------------
  //README中有TDT各字段含义，简单拆分
  assign desc_type_o              = tdt_rdata[255:252];
  assign task_mode_o              = tdt_rdata[249:248];   // 低 2 bit; [251:250] 应为 0
  assign flags_o                  = tdt_rdata[247:240];
  assign num_heads_o              = tdt_rdata[239:224];
  assign context_length_o         = tdt_rdata[223:208];
  assign dim_o                    = tdt_rdata[207:192];
  assign head_dim_o               = tdt_rdata[191:176];
  assign group_size_o             = tdt_rdata[175:168];
  assign sa_per_head_o            = tdt_rdata[167:160];
  assign hp_parallel_o            = tdt_rdata[159:152];
  assign pe_desc_id_o             = tdt_rdata[151:144];
  assign q_buffer_policy_o        = tdt_rdata[143:136];
  assign output_mode_o            = tdt_rdata[135:128];
  assign stream_contract_o        = tdt_rdata[127:120];
  assign deq_prefill_hint_o       = tdt_rdata[119:112];
  assign qk_dim_group_count_o     = tdt_rdata[111:96];
  assign qk_context_block_count_o = tdt_rdata[95:80];
  assign qk_context_tail_mask_o   = tdt_rdata[79:48];
  assign pv_context_group_count_o = tdt_rdata[47:32];
  assign pv_last_inner_count_o    = tdt_rdata[31:26];
  assign last_head_count_o        = tdt_rdata[25:18];

  // task_mode 的高 2 bit (用于检测非法 mode, 例如 0x2 fused 当前未实现)
  logic [3:0] task_mode_full;
  assign task_mode_full = tdt_rdata[251:248];

  //----------------------------------------------------------------------------
  // 各 mode 下的子检查
  //----------------------------------------------------------------------------
  //进行运算类型判断
  logic is_qk, is_pv;
  assign is_qk = (task_mode_o == TASK_MODE_QK) && (task_mode_full[3:2] == 2'b00) && (task_mode_full[1] == 1'b0);
  assign is_pv = (task_mode_o == TASK_MODE_PV) && (task_mode_full[3:2] == 2'b00);
 
  //检查QK dim_per_head是否能被整除 
  // QK: dim 必须 32 对齐 (只看低 5 bit, 廉价)
  logic qk_dim_ok;
  assign qk_dim_ok = (dim_o[4:0] == 5'd0) && (dim_o != 16'd0);

  // context 公共: context_length 非 0
  logic num_heads_ok;
  logic ctx_len_ok;
  assign num_heads_ok = (num_heads_o != 16'd0);
  assign ctx_len_ok = (context_length_o != 16'd0);

  // QK context: block count 非 0, tail mask 非 0
  logic qk_ctx_ok;
  assign qk_ctx_ok = (qk_context_block_count_o != 16'd0) &&
                     (qk_dim_group_count_o     != 16'd0) &&
                     (qk_context_tail_mask_o   != 32'd0);

  // PV context: group count 非 0, last_inner 在 1..32
  logic pv_ctx_ok;
  assign pv_ctx_ok = (pv_context_group_count_o != 16'd0) &&
                     (pv_last_inner_count_o    >= 6'd1)  &&
                     (pv_last_inner_count_o    <= 6'd32);

  logic last_head_count_ok;
  logic hp_parallel_ok;
  assign hp_parallel_ok = (hp_parallel_o >= 8'd1) &&
                          (hp_parallel_o <= 8'(PARALLEL_MAX));
  assign last_head_count_ok = (last_head_count_o >= 8'd1) &&
                              (last_head_count_o <= 8'(PARALLEL_MAX)) &&
                              (last_head_count_o <= hp_parallel_o) &&
                              ({8'd0, last_head_count_o} <= num_heads_o);

  // PV mapping 检查 (一次性小乘法, 非热路径):
  //   head_dim>=32, head_dim%32==0, hp_parallel*head_dim==128, sa_per_head*32==head_dim
  logic [15:0] hp_x_headdim;   // hp_parallel * head_dim
  logic [15:0] saph_x_32;      // sa_per_head * 32
  assign hp_x_headdim = hp_parallel_o[7:0] * head_dim_o[7:0];
  assign saph_x_32    = {sa_per_head_o, 5'd0};         // *32 = 左移 5
  logic pv_map_ok;
  assign pv_map_ok = (head_dim_o >= 16'd32)        &&
                     (head_dim_o[4:0] == 5'd0)     &&
                     (hp_x_headdim == 16'd128)     &&
                     (saph_x_32[15:0] == head_dim_o);

  //----------------------------------------------------------------------------
  // 合法性裁决 —— 固定优先级 (从严重到次要), 命中第一个即定 error_code
  //   优先级与 ISA §9 列表一致
  //----------------------------------------------------------------------------
  //逐个检查上面的运算结果，输出错误码
  always_comb begin
    cfg_error_code_o = ERR_NONE;

    if (desc_type_o != TDT_DESC_TYPE) begin
      cfg_error_code_o = ERR_ILLEGAL_TASK_DESC;
    end else if (!(is_qk || is_pv)) begin
      cfg_error_code_o = ERR_ILLEGAL_TASK_MODE;
    end else if (group_size_o != 8'd32) begin
      cfg_error_code_o = ERR_ILLEGAL_GROUP_SIZE;
    end else if (is_qk && !qk_dim_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_DIM;
    end else if (!num_heads_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_CONTEXT;
    end else if (!ctx_len_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_CONTEXT;
    end else if (!hp_parallel_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_CONTEXT;
    end else if (!last_head_count_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_CONTEXT;
    end else if (is_qk && !qk_ctx_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_CONTEXT;
    end else if (is_pv && !pv_ctx_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_CONTEXT;
    end else if (is_pv && !pv_map_ok) begin
      cfg_error_code_o = ERR_ILLEGAL_PV_MAP;
    end else if (stream_contract_o != 8'd0) begin
      cfg_error_code_o = ERR_ILLEGAL_STREAM_CONTRACT;
    end
  end

  assign cfg_legal_o = (cfg_error_code_o == ERR_NONE);

endmodule : lte_tdt_decode
