//==============================================================================
// tb_lte_tdt_decode.sv — B5 TDT解码+合法性检查 定向测试
// 覆盖: 所有9种错误码 + 合法QK/PV配置
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
    .cfg_legal_o              (legal),
    .cfg_error_code_o         (err_code)
  );

  // 构造一个合法QK TDT
  function automatic logic [255:0] make_qk(
    input logic [15:0] _dim, _ctx, _heads,
    input logic [31:0] _tail,
    input logic [15:0] _dgc, _cbc
  );
    logic [255:0] d = '0;
    d[255:252] = 4'hD;
    d[251:248] = 4'h0;       // task_mode=QK
    d[175:168] = 8'd32;      // group_size=32
    d[239:224] = _heads;
    d[223:208] = _ctx;
    d[207:192] = _dim;
    d[111:96]  = _dgc;
    d[95:80]   = _cbc;
    d[79:48]   = _tail;
    return d;
  endfunction

  // 构造合法PV TDT
  function automatic logic [255:0] make_pv(
    input logic [15:0] _heads, _ctx, _hdim,
    input logic [7:0]  _saph, _hp,
    input logic [15:0] _pgc,
    input logic [5:0]  _li
  );
    logic [255:0] d = '0;
    d[255:252] = 4'hD;
    d[251:248] = 4'h1;       // task_mode=PV
    d[175:168] = 8'd32;      // group_size=32
    d[239:224] = _heads;
    d[223:208] = _ctx;
    d[191:176] = _hdim;
    d[167:160] = _saph;
    d[159:152] = _hp;
    d[47:32]   = _pgc;
    d[31:26]   = _li;
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
    // ---- TC01: 合法 QK ----
    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2);
    chk("LEGAL_QK", 1'b1, ERR_NONE);

    // ---- TC02: 合法 PV head_dim=128 ----
    tdt = make_pv(2, 64, 128, 4, 1, 2, 6'd32);
    chk("LEGAL_PV128", 1'b1, ERR_NONE);

    // ---- TC03: 合法 PV head_dim=64 ----
    tdt = make_pv(2, 33, 64, 2, 2, 2, 6'd1);
    chk("LEGAL_PV64", 1'b1, ERR_NONE);

    // ---- TC04: 合法 PV head_dim=32 ----
    tdt = make_pv(4, 64, 32, 1, 4, 2, 6'd32);
    chk("LEGAL_PV32", 1'b1, ERR_NONE);

    // ---- TC05: ILLEGAL_TASK_DESC ----
    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2);
    tdt[255:252] = 4'hA;
    chk("ERR_TASK_DESC", 1'b0, ERR_ILLEGAL_TASK_DESC);

    // ---- TC06: ILLEGAL_TASK_MODE (mode=3) ----
    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2);
    tdt[251:248] = 4'h3;
    chk("ERR_TASK_MODE", 1'b0, ERR_ILLEGAL_TASK_MODE);

    // ---- TC07: ILLEGAL_GROUP_SIZE ----
    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2);
    tdt[175:168] = 8'd16;
    chk("ERR_GROUP_SIZE", 1'b0, ERR_ILLEGAL_GROUP_SIZE);

    // ---- TC08: ILLEGAL_DIM (dim not multiple of 32) ----
    tdt = make_qk(100, 64, 2, 32'hFFFF_FFFF, 3, 2);
    chk("ERR_DIM", 1'b0, ERR_ILLEGAL_DIM);

    // ---- TC09: ILLEGAL_CONTEXT (context_length=0) ----
    tdt = make_qk(128, 0, 2, 32'hFFFF_FFFF, 4, 0);
    chk("ERR_CTX_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    // ---- TC10: ILLEGAL_CONTEXT (qk_context_block_count=0) ----
    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 0);
    chk("ERR_QK_CBC_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    // ---- TC11: ILLEGAL_CONTEXT (tail_mask=0) ----
    tdt = make_qk(128, 64, 2, 32'h0, 4, 2);
    chk("ERR_TAIL_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    // ---- TC12: ILLEGAL_CONTEXT (pv_last_inner=0) ----
    tdt = make_pv(2, 64, 128, 4, 1, 2, 6'd0);
    chk("ERR_PV_LI_ZERO", 1'b0, ERR_ILLEGAL_CONTEXT);

    // ---- TC13: ILLEGAL_CONTEXT (pv_last_inner>32) ----
    tdt = make_pv(2, 64, 128, 4, 1, 2, 6'd33);
    chk("ERR_PV_LI_OOB", 1'b0, ERR_ILLEGAL_CONTEXT);

    // ---- TC14: ILLEGAL_PV_MAP (hp*hdim != 128) ----
    tdt = make_pv(2, 64, 64, 2, 3, 2, 6'd32);  // hp=3: 3*64=192 ≠ 128
    chk("ERR_PV_MAP", 1'b0, ERR_ILLEGAL_PV_MAP);

    // ---- TC15: ILLEGAL_STREAM_CONTRACT ----
    tdt = make_qk(128, 64, 2, 32'hFFFF_FFFF, 4, 2);
    tdt[127:120] = 8'h01;
    chk("ERR_STREAM_CONTRACT", 1'b0, ERR_ILLEGAL_STREAM_CONTRACT);

    if (err_cnt == 0)
      $display("\n[RESULT] tb_lte_tdt_decode: ALL PASS");
    else
      $display("\n[RESULT] tb_lte_tdt_decode: FAIL (%0d errors)", err_cnt);
    $finish;
  end

endmodule
