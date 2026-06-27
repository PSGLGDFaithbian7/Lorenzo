//==============================================================================
// tb_lte_tdt_decode.sv - B5 TDT decode and legality checks
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_tdt_decode;

  logic [255:0] tdt;
  logic [3:0]  desc_type;
  logic [1:0]  task_mode;
  logic [7:0]  flags, group_size, sa_per_head, hp_parallel;
  logic [15:0] num_heads, ctx_len, dim, head_dim;
  logic [15:0] qk_dim_gc, qk_ctx_bc;
  logic [31:0] qk_tail;
  logic [15:0] pv_ctx_gc;
  logic [5:0]  pv_last_inner;
  logic [7:0]  last_head_count;
  logic        legal;
  logic [7:0]  err_code;

  int err_cnt = 0;

  lte_tdt_decode dut (
    .tdt_rdata                (tdt),
    .desc_type_o              (desc_type),
    .task_mode_o              (task_mode),
    .flags_o                  (flags),
    .num_heads_o              (num_heads),
    .context_length_o         (ctx_len),
    .dim_o                    (dim),
    .head_dim_o               (head_dim),
    .group_size_o             (group_size),
    .sa_per_head_o            (sa_per_head),
    .hp_parallel_o            (hp_parallel),
    .pe_desc_id_o             (),
    .q_buffer_policy_o        (),
    .output_mode_o            (),
    .stream_contract_o        (),
    .deq_prefill_hint_o       (),
    .qk_dim_group_count_o     (qk_dim_gc),
    .qk_context_block_count_o (qk_ctx_bc),
    .qk_context_tail_mask_o   (qk_tail),
    .pv_context_group_count_o (pv_ctx_gc),
    .pv_last_inner_count_o    (pv_last_inner),
    .last_head_count_o        (last_head_count),
    .cfg_legal_o              (legal),
    .cfg_error_code_o         (err_code)
  );

  function automatic logic [255:0] make_qk(
    input logic [15:0] _dim, _ctx, _heads,
    input logic [31:0] _tail,
    input logic [15:0] _dgc, _cbc,
    input logic [7:0]  _hp,
    input logic [7:0]  _last_heads
  );
    logic [255:0] d = '0;
    d[255:252] = 4'hD;
    d[251:248] = 4'h0;
    d[175:168] = 8'd32;
    d[239:224] = _heads;
    d[223:208] = _ctx;
    d[207:192] = _dim;
    d[159:152] = _hp;
    d[111:96]  = _dgc;
    d[95:80]   = _cbc;
    d[79:48]   = _tail;
    d[25:18]   = _last_heads;
    return d;
  endfunction

  function automatic logic [255:0] make_pv(
    input logic [15:0] _heads, _ctx, _hdim,
    input logic [7:0]  _saph, _hp,
    input logic [15:0] _pgc,
    input logic [5:0]  _li,
    input logic [7:0]  _last_heads
  );
    logic [255:0] d = '0;
    d[255:252] = 4'hD;
    d[251:248] = 4'h1;
    d[175:168] = 8'd32;
    d[239:224] = _heads;
    d[223:208] = _ctx;
    d[191:176] = _hdim;
    d[167:160] = _saph;
    d[159:152] = _hp;
    d[47:32]   = _pgc;
    d[31:26]   = _li;
    d[25:18]   = _last_heads;
    return d;
  endfunction

  task automatic chk(input string tc, input logic exp_legal, input logic [7:0] exp_err);
    #1;
    if (legal !== exp_legal || err_code !== exp_err) begin
      $display("[FAIL] t=%0t TC=%s: legal=%b(exp=%b) err=0x%02x(exp=0x%02x)",
               $time, tc, legal, exp_legal, err_code, exp_err);
      err_cnt++;
    end else begin
      $display("[PASS] TC=%s", tc);
    end
  endtask

  initial begin
    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 4, 2);
    chk("LEGAL_QK", 1'b1, ERR_NONE);
    if (last_head_count !== 8'd2) begin
      $display("[FAIL] TC=LEGAL_QK last_head_count=%0d exp=2", last_head_count);
      err_cnt++;
    end

    tdt = make_pv(2, 64, 128, 4, 1, 2, 6'd32, 1);
    chk("LEGAL_PV128", 1'b1, ERR_NONE);

    tdt = make_pv(9, 32, 64, 2, 2, 1, 6'd32, 1);
    chk("LEGAL_PV64_9H_LAST1", 1'b1, ERR_NONE);

    tdt = make_pv(2, 33, 64, 2, 2, 2, 6'd1, 2);
    chk("LEGAL_PV64", 1'b1, ERR_NONE);

    tdt = make_pv(4, 64, 32, 1, 4, 2, 6'd32, 4);
    chk("LEGAL_PV32", 1'b1, ERR_NONE);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 4, 2);
    tdt[255:252] = 4'hA;
    chk("ERR_TASK_DESC", 1'b0, ERR_ILLEGAL_TASK_DESC);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 4, 2);
    tdt[251:248] = 4'h3;
    chk("ERR_TASK_MODE", 1'b0, ERR_ILLEGAL_TASK_MODE);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 4, 2);
    tdt[175:168] = 8'd16;
    chk("ERR_GROUP_SIZE", 1'b0, ERR_ILLEGAL_GROUP_SIZE);

    tdt = make_qk(100, 64, 2, 32'hFFFF_FFFF, 3, 2, 4, 2);
    chk("ERR_DIM", 1'b0, ERR_ILLEGAL_DIM);

    tdt = make_qk(128, 0, 2, 32'hFFFF_FFFF, 4, 0, 4, 2);
    chk("ERR_CTX_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 0, 4, 2);
    chk("ERR_QK_CBC_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    tdt = make_qk(128, 64, 2, 32'h0, 4, 2, 4, 2);
    chk("ERR_TAIL_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    tdt = make_pv(2, 64, 128, 4, 1, 2, 6'd0, 1);
    chk("ERR_PV_LI_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    tdt = make_pv(2, 64, 128, 4, 1, 2, 6'd33, 1);
    chk("ERR_PV_LI_OOB", 1'b0, ERR_ILLEGAL_CONTEXT);

    tdt = make_pv(2, 64, 64, 2, 3, 2, 6'd32, 2);
    chk("ERR_PV_MAP", 1'b0, ERR_ILLEGAL_PV_MAP);

    tdt = make_pv(1, 64, 384, 12, 1, 2, 6'd32, 1);
    chk("ERR_PV_MAP_HDIM_GT128", 1'b0, ERR_ILLEGAL_PV_MAP);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 4, 2);
    tdt[127:120] = 8'h01;
    chk("ERR_STREAM_CONTRACT", 1'b0, ERR_ILLEGAL_STREAM_CONTRACT);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 4, 0);
    chk("ERR_LAST_ACTIVE_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 4, 5);
    chk("ERR_LAST_HEAD_OOB", 1'b0, ERR_ILLEGAL_CONTEXT);

    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2, 2, 3);
    chk("ERR_LAST_HEAD_GT_FULL", 1'b0, ERR_ILLEGAL_CONTEXT);

    if (err_cnt == 0)
      $display("\n[RESULT] tb_lte_tdt_decode: ALL PASS");
    else
      $display("\n[RESULT] tb_lte_tdt_decode: FAIL (%0d errors)", err_cnt);
    $finish;
  end

endmodule
