//==============================================================================
// lte_task_ctrl_top.sv   (乙方控制面集成 wrapper, 对应微架构 §1 的 u_task_engine 控制核)
//------------------------------------------------------------------------------
// 把分工项 B1~B8 连成一个完整的 task-engine 控制核, 对外只暴露:
//   - CSR / 启动接口 (host 侧)
//   - TDT / PE descriptor 读口
//   - 与甲方 datapath 的 token/credit/event 契约 (分工计划 §4)
//
// B9 (legacy mux) 不在本 wrapper 内实例化 —— 它在更高层把"本控制核"与 V0.2 legacy
// sequencer 做 2:1 选择, 属于集成层职责。
//
// 注意: 本 wrapper 不含任何 datapath 算术, 只做控制/配置/调度 。
//==============================================================================
import lte_pkg::*;

module lte_task_ctrl_top (
    input  logic        clk,
    input  logic        rst_n,

    //==========================================================================
    // Host / CSR 接口
    //==========================================================================
    input  logic        csr_start,          // TASK_START
    input  logic [3:0]   csr_task_id,
    input  logic        csr_wait_on_launch,
    input  logic        snapshot_req,        // TASK_STATUS_SNAPSHOT
    input  logic        wait_consume,        // TASK_WAIT 消费 done
    input  logic [3:0]   wait_task_id,

    input  logic [7:0]   csr_addr,
    input  logic        csr_wr,
    input  logic [31:0]  csr_wdata,
    input  logic        csr_rd,
    output logic [31:0]  csr_rdata,

    //==========================================================================
    // TDT / PE descriptor 读口 (Host 启动前写好, 本核只读)
    //==========================================================================
    output logic [3:0]   tdt_raddr,
    input  logic [255:0] tdt_rdata,
    output logic [3:0]   pe_desc_raddr,
    input  logic [127:0] pe_desc_rdata,

    //==========================================================================
    // 甲方 datapath -> 乙方控制 (数据通路反馈)
    //==========================================================================
    input  logic        mac_fire,            // MAC 实际发射
    input  logic        group_done_accept,   // dequant 可接受 group-done token
    input  logic        drain_fire,          // 一条 drain lane 输出
    input  logic        engine_task_done,    // 整 task 完成(含 drain 排空)

    // pipeline backpressure level (供 scoreboard/CSR)
    input  logic [3:0]   partial_acc_bank_free,
    input  logic [1:0]   group_acc_bank_free,
    input  logic [3:0]   deq_fifo_level,
    input  logic [3:0]   deq_token_queue_level,
    input  logic [3:0]   drain_token_queue_level,
    input  logic [3:0]   output_queue_level,
    input  logic [3:0]   stream_credit_q,
    input  logic [3:0]   stream_credit_k,
    input  logic [3:0]   stream_credit_p,
    input  logic [3:0]   stream_credit_v,
    // 运行期 backpressure debug 错误 (可选)
    input  logic        bp_err_set,
    input  logic [3:0]   bp_err_task_id,

    //==========================================================================
    // 乙方控制 -> 甲方 datapath (配置 / 事件 / token)
    //==========================================================================
    // 锁存后的 task 配置
    output task_ctx_t   task_ctx,
    output logic [1:0]   task_mode,
    output logic [7:0]   active_sa_count,
    // use_*_lorenzo: 动态单 bit (对所有 active SA 相同, 由 boundary_ctrl 运行期计算)
    output logic                               use_input_lorenzo,
    output logic                               use_output_lorenzo,
    output logic [NUM_SA-1:0][VALID_LEN_W-1:0] valid_len,   // 静态 per-SA, 来自 PE desc

    // 启动脉冲
    output logic        task_start,

    // 边界事件
    output logic        head_tile_start,
    output logic        row_start,
    output logic        group_start,
    output logic        group_done_pulse,
    output logic        row_done_pulse,
    output logic        head_tile_done_pulse,
    output logic        task_done_pulse,

    // dequant token (控制面字段; bank id 由甲方出队时补齐)
    output logic            deq_token_valid,
    output deq_token_meta_t deq_token_meta,

    // drain token (控制面字段)
    output logic              drain_token_valid,
    output drain_token_meta_t drain_token_meta,
    // drain 侧 lorenzo/valid_len 直接使用上方的 use_output_lorenzo / valid_len

    // 计数器 (供 datapath lane 映射 / debug)
    output logic [HEAD_W-1:0]      head_ctr,
    output logic [QK_CTX_W-1:0]    context_ctr,
    output logic [GROUP_CTR_W-1:0] group_ctr,
    output logic [INNER_W-1:0]     inner_ctr,
    output logic [DRAIN_W-1:0]     drain_lane_ctr,

    //==========================================================================
    // 全局状态
    //==========================================================================
    output logic        engine_busy,
    output logic        halted_error,
    output logic [7:0]   error_code
);

  //----------------------------------------------------------------------------
  // B5: TDT 解码 + 合法性检查 (组合)
  //----------------------------------------------------------------------------
  logic [1:0]  dec_task_mode;
  logic [7:0]  dec_flags;
  logic [15:0] dec_num_heads, dec_context_length, dec_dim, dec_head_dim;
  logic [7:0]  dec_group_size, dec_sa_per_head, dec_hp_parallel, dec_pe_desc_id;
  logic [7:0]  dec_q_buffer_policy, dec_output_mode, dec_stream_contract, dec_deq_prefill_hint;
  logic [15:0] dec_qk_dim_group_count, dec_qk_context_block_count;
  logic [31:0] dec_qk_context_tail_mask;
  logic [15:0] dec_pv_context_group_count;
  logic [5:0]  dec_pv_last_inner_count;
  logic [7:0]  dec_last_head_count;
  logic [3:0]  dec_desc_type;
  logic        cfg_legal;
  logic [7:0]  cfg_error_code;

  lte_tdt_decode u_tdt_decode (
    .tdt_rdata                (tdt_rdata),
    .desc_type_o              (dec_desc_type),
    .task_mode_o              (dec_task_mode),
    .flags_o                  (dec_flags),
    .num_heads_o              (dec_num_heads),
    .context_length_o         (dec_context_length),
    .dim_o                    (dec_dim),
    .head_dim_o               (dec_head_dim),
    .group_size_o             (dec_group_size),
    .sa_per_head_o            (dec_sa_per_head),
    .hp_parallel_o            (dec_hp_parallel),
    .pe_desc_id_o             (dec_pe_desc_id),
    .q_buffer_policy_o        (dec_q_buffer_policy),
    .output_mode_o            (dec_output_mode),
    .stream_contract_o        (dec_stream_contract),
    .deq_prefill_hint_o       (dec_deq_prefill_hint),
    .qk_dim_group_count_o     (dec_qk_dim_group_count),
    .qk_context_block_count_o (dec_qk_context_block_count),
    .qk_context_tail_mask_o   (dec_qk_context_tail_mask),
    .pv_context_group_count_o (dec_pv_context_group_count),
    .pv_last_inner_count_o    (dec_pv_last_inner_count),
    .last_head_count_o        (dec_last_head_count),
    .cfg_legal_o              (cfg_legal),
    .cfg_error_code_o         (cfg_error_code)
  );

  // PE descriptor 地址 = TDT 解出的 pe_desc_id (tdt_rdata 在 FETCH..RUN 稳定)
  assign pe_desc_raddr = dec_pe_desc_id[3:0];

  //----------------------------------------------------------------------------
  // B1: 任务派发器
  //----------------------------------------------------------------------------
  logic        task_launch;
  logic [3:0]  task_id;
  logic        task_busy_set, task_done_set;
  logic [3:0]  done_task_id;
  logic        disp_err_set;
  logic [7:0]  disp_err_code;
  logic [3:0]  disp_err_task_id;

  lte_task_dispatch u_dispatch (
    .clk                (clk),
    .rst_n              (rst_n),
    .csr_start          (csr_start),
    .csr_task_id        (csr_task_id),
    .csr_wait_on_launch (csr_wait_on_launch),
    .tdt_raddr          (tdt_raddr),
    .tdt_rdata          (tdt_rdata),
    .cfg_legal          (cfg_legal),
    .cfg_error_code     (cfg_error_code),
    .engine_task_done   (engine_task_done),
    .task_launch        (task_launch),
    .task_start         (task_start),
    .task_id_o          (task_id),
    .engine_busy        (engine_busy),
    .task_busy_set      (task_busy_set),
    .task_done_set      (task_done_set),
    .done_task_id       (done_task_id),
    .err_set            (disp_err_set),
    .err_code           (disp_err_code),
    .err_task_id        (disp_err_task_id)
  );

  //----------------------------------------------------------------------------
  // B2: 任务上下文锁存
  //----------------------------------------------------------------------------
  task_ctx_t ctx;

  logic        flag_in_lz, flag_in_lz_full_only, flag_out_lz, flag_out_lz_full_only;

  lte_task_context u_task_context (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .task_launch              (task_launch),
    .task_mode_i              (dec_task_mode),
    .flags_i                  (dec_flags),
    .num_heads_i              (dec_num_heads),
    .context_length_i         (dec_context_length),
    .dim_i                    (dec_dim),
    .head_dim_i               (dec_head_dim),
    .group_size_i             (dec_group_size),
    .sa_per_head_i            (dec_sa_per_head),
    .hp_parallel_i            (dec_hp_parallel),
    .q_buffer_policy_i        (dec_q_buffer_policy),
    .output_mode_i            (dec_output_mode),
    .stream_contract_i        (dec_stream_contract),
    .deq_prefill_hint_i       (dec_deq_prefill_hint),
    .qk_dim_group_count_i     (dec_qk_dim_group_count),
    .qk_context_block_count_i (dec_qk_context_block_count),
    .qk_context_tail_mask_i   (dec_qk_context_tail_mask),
    .pv_context_group_count_i (dec_pv_context_group_count),
    .pv_last_inner_count_i    (dec_pv_last_inner_count),
    .last_head_count_i        (dec_last_head_count),
    .pe_desc_rdata            (pe_desc_rdata),
    .task_ctx_o               (ctx),
    .valid_len_o              (valid_len),
    .flag_in_lz_o             (flag_in_lz),
    .flag_in_lz_full_only_o   (flag_in_lz_full_only),
    .flag_out_lz_o            (flag_out_lz),
    .flag_out_lz_full_only_o  (flag_out_lz_full_only)
  );

  assign task_ctx        = ctx;
  assign task_mode       = ctx.task_mode;

  //----------------------------------------------------------------------------
  // B3: 循环嵌套控制器
  //   注意把 ctx 的宽字段切到 loop_nest 各端口宽度 (Host 已保证不溢出)
  //----------------------------------------------------------------------------
  localparam int LN_HEADC_W = $clog2(HEAD_NUM_MAX+1);
  localparam int LN_QKGRP_W = $clog2(QK_DIM_GROUP_NUM_MAX+1);
  localparam int LN_QKCTX_W = $clog2(QK_CONTEXT_BLOCK_NUM_MAX+1);
  localparam int LN_PVGRP_W = $clog2(PV_CONTEXT_GROUP_NUM_MAX+1);
  localparam int LN_INNER_W = $clog2(GROUP_SIZE_MAX+1);
  localparam int LN_HP_W    = $clog2(PARALLEL_MAX+1);

  logic gd_valid, gd_last_group, gd_last_ctx, gd_last_head;
  logic [DRAIN_LANE_NUM-1:0] gd_lane_mask;
  logic ln_group_done_fire, ln_qk_block_done_fire, ln_head_step_fire, ln_task_done_fire;
  logic [LN_HP_W-1:0] ln_active_sa_count;

  assign active_sa_count = 8'(ln_active_sa_count);

  lte_loop_nest_ctrl u_loop_nest (
    .clk                        (clk),
    .rst_n                      (rst_n),
    .task_start                 (task_start),
    .task_mode                  (ctx.task_mode),
    .num_heads                  (ctx.num_heads[LN_HEADC_W-1:0]),
    .qk_dim_group_count         (ctx.qk_dim_group_count[LN_QKGRP_W-1:0]),
    .qk_context_block_count     (ctx.qk_context_block_count[LN_QKCTX_W-1:0]),
    .qk_context_tail_mask       (ctx.qk_context_tail_mask),
    .pv_context_group_count     (ctx.pv_context_group_count[LN_PVGRP_W-1:0]),
    .pv_last_inner_count        (ctx.pv_last_inner_count[LN_INNER_W-1:0]),
    .hp_parallel                (ctx.hp_parallel[LN_HP_W-1:0]),
    .sa_per_head                (ctx.sa_per_head[LN_HP_W-1:0]),
    .full_active_sa_count       (ctx.active_sa_count[LN_HP_W-1:0]),
    .last_head_count            (ctx.last_head_count[LN_HP_W-1:0]),
    .mac_fire                   (mac_fire),
    .group_done_accept          (group_done_accept),
    .drain_fire                 (drain_fire),
    .head_ctr_o                 (head_ctr),
    .context_ctr_o              (context_ctr),
    .group_ctr_o                (group_ctr),
    .inner_ctr_o                (inner_ctr),
    .drain_lane_ctr_o           (drain_lane_ctr),
    .active_sa_count_o          (ln_active_sa_count),
    .is_inner_last              (/* status */),
    .is_group_last              (/* status */),
    .is_context_block_last      (/* status */),
    .is_head_tile_last          (/* status */),
    .is_task_last               (/* status */),
    .group_done_valid           (gd_valid),
    .group_done_last_group      (gd_last_group),
    .group_done_last_ctx        (gd_last_ctx),
    .group_done_last_head       (gd_last_head),
    .group_done_lane_valid_mask (gd_lane_mask),
    .group_done_fire_o          (ln_group_done_fire),
    .qk_block_done_fire_o       (ln_qk_block_done_fire),
    .head_step_fire_o           (ln_head_step_fire),
    .task_done_fire_o           (ln_task_done_fire)
  );

  //----------------------------------------------------------------------------
  // B4: 边界控制器 + token 打包
  //----------------------------------------------------------------------------
  logic bc_full_pe_active;  // 当前 block/group 是否数据满载 (供 MAC scheduler 查询)

  lte_boundary_ctrl u_boundary (
    .task_start                 (task_start),
    .task_mode                  (ctx.task_mode),
    .group_done_fire            (ln_group_done_fire),
    .qk_block_done_fire         (ln_qk_block_done_fire),
    .head_step_fire             (ln_head_step_fire),
    .task_done_fire             (ln_task_done_fire),
    .head_ctr                   (head_ctr),
    .context_ctr                (context_ctr),
    .group_ctr                  (group_ctr),
    .group_done_last_group      (gd_last_group),
    .group_done_last_ctx        (gd_last_ctx),
    .group_done_last_head       (gd_last_head),
    .group_done_lane_valid_mask (gd_lane_mask),
    .output_mode                (ctx.output_mode),
    .flag_in_lz                 (flag_in_lz),
    .flag_in_lz_full_only       (flag_in_lz_full_only),
    .flag_out_lz                (flag_out_lz),
    .flag_out_lz_full_only      (flag_out_lz_full_only),
    .pv_last_inner_count        (ctx.pv_last_inner_count),
    .head_tile_start            (head_tile_start),
    .row_start                  (row_start),
    .group_start                (group_start),
    .group_done_pulse           (group_done_pulse),
    .row_done_pulse             (row_done_pulse),
    .head_tile_done_pulse       (head_tile_done_pulse),
    .task_done_pulse            (task_done_pulse),
    .deq_token_valid            (deq_token_valid),
    .deq_token_meta             (deq_token_meta),
    .drain_token_valid          (drain_token_valid),
    .drain_token_meta           (drain_token_meta),
    .full_pe_active             (bc_full_pe_active),
    .use_input_lorenzo          (use_input_lorenzo),
    .use_output_lorenzo         (use_output_lorenzo)
  );

  //----------------------------------------------------------------------------
  // B8: 错误控制器
  //----------------------------------------------------------------------------
  logic        csr_err_clear;
  logic        sb_task_error_set;
  logic [3:0]  sb_task_error_id;
  logic [7:0]  sb_task_error_code;

  lte_error_ctrl u_error (
    .clk             (clk),
    .rst_n           (rst_n),
    .err_set         (disp_err_set),
    .err_code        (disp_err_code),
    .err_task_id     (disp_err_task_id),
    .bp_err_set      (bp_err_set),
    .bp_err_task_id  (bp_err_task_id),
    .csr_err_clear   (csr_err_clear),
    .halted_error    (halted_error),
    .error_code      (error_code),
    .task_error_set  (sb_task_error_set),
    .task_error_id   (sb_task_error_id),
    .task_error_code (sb_task_error_code)
  );

  //----------------------------------------------------------------------------
  // B6: 记分板
  //----------------------------------------------------------------------------
  logic [15:0]      sb_task_busy, sb_task_done, sb_task_error;
  logic [15:0][7:0] sb_task_err_code;
  logic [3:0]  sb_partial_free, sb_deq_fifo, sb_deq_tok, sb_drain_tok, sb_out_q;
  logic [3:0]  sb_cred_q, sb_cred_k, sb_cred_p, sb_cred_v;
  logic [1:0]  sb_group_free;

  lte_task_scoreboard u_scoreboard (
    .clk                        (clk),
    .rst_n                      (rst_n),
    .task_busy_set              (task_busy_set),
    .busy_task_id               (task_id),
    .task_done_set              (task_done_set),
    .done_task_id               (done_task_id),
    .task_error_set             (sb_task_error_set),
    .task_error_id              (sb_task_error_id),
    .task_error_code_i          (sb_task_error_code),
    .wait_consume               (wait_consume),
    .wait_task_id               (wait_task_id),
    .partial_acc_bank_free      (partial_acc_bank_free),
    .group_acc_bank_free        (group_acc_bank_free),
    .deq_fifo_level             (deq_fifo_level),
    .deq_token_queue_level      (deq_token_queue_level),
    .drain_token_queue_level    (drain_token_queue_level),
    .output_queue_level         (output_queue_level),
    .stream_credit_q            (stream_credit_q),
    .stream_credit_k            (stream_credit_k),
    .stream_credit_p            (stream_credit_p),
    .stream_credit_v            (stream_credit_v),
    .task_busy                  (sb_task_busy),
    .task_done                  (sb_task_done),
    .task_error                 (sb_task_error),
    .task_error_code            (sb_task_err_code),
    .sb_partial_acc_bank_free   (sb_partial_free),
    .sb_group_acc_bank_free     (sb_group_free),
    .sb_deq_fifo_level          (sb_deq_fifo),
    .sb_deq_token_queue_level   (sb_deq_tok),
    .sb_drain_token_queue_level (sb_drain_tok),
    .sb_output_queue_level      (sb_out_q),
    .sb_stream_credit_q         (sb_cred_q),
    .sb_stream_credit_k         (sb_cred_k),
    .sb_stream_credit_p         (sb_cred_p),
    .sb_stream_credit_v         (sb_cred_v)
  );

  //----------------------------------------------------------------------------
  // B7: CSR + debug snapshot
  //----------------------------------------------------------------------------
  lte_csr u_csr (
    .clk                        (clk),
    .rst_n                      (rst_n),
    .csr_addr                   (csr_addr),
    .csr_wr                     (csr_wr),
    .csr_wdata                  (csr_wdata),
    .csr_rd                     (csr_rd),
    .csr_rdata                  (csr_rdata),
    .snapshot_req               (snapshot_req),
    .head_ctr                   (head_ctr),
    .context_ctr                (context_ctr),
    .group_ctr                  (group_ctr),
    .inner_ctr                  (inner_ctr),
    .drain_lane_ctr             (drain_lane_ctr),
    .engine_busy                (engine_busy),
    .halted_done                (task_done_set),
    .halted_error               (halted_error),
    .global_error_code          (error_code),
    .task_busy                  (sb_task_busy),
    .task_done                  (sb_task_done),
    .task_error                 (sb_task_error),
    .task_error_code            (sb_task_err_code),
    .sb_partial_acc_bank_free   (sb_partial_free),
    .sb_group_acc_bank_free     (sb_group_free),
    .sb_deq_fifo_level          (sb_deq_fifo),
    .sb_deq_token_queue_level   (sb_deq_tok),
    .sb_drain_token_queue_level (sb_drain_tok),
    .sb_output_queue_level      (sb_out_q),
    .sb_stream_credit_q         (sb_cred_q),
    .sb_stream_credit_k         (sb_cred_k),
    .sb_stream_credit_p         (sb_cred_p),
    .sb_stream_credit_v         (sb_cred_v),
    .csr_err_clear              (csr_err_clear)
  );

endmodule : lte_task_ctrl_top
