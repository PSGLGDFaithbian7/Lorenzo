//==============================================================================
// tb_lte_task_context.sv — B2 任务上下文锁存 定向测试
// 覆盖: task_launch 锁存、无 launch 不更新、valid_len 切片、flag bits、active_sa_count
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_task_context;

  localparam CLK_HALF = 5;

  logic clk = 0, rst_n = 0;
  always #CLK_HALF clk = ~clk;

  // DUT inputs
  logic        task_launch = 0;
  logic [1:0]  task_mode_i = 0;
  logic [7:0]  flags_i = 0;
  logic [15:0] num_heads_i, ctx_i, dim_i, hdim_i;
  logic [7:0]  gs_i, saph_i, hpp_i, qbp_i, om_i, sc_i, dph_i;
  logic [15:0] dgc_i, cbc_i, pgc_i;
  logic [31:0] tail_i;
  logic [5:0]  pli_i;
  logic [127:0] pe_desc_i = '0;

  // DUT outputs
  task_ctx_t ctx_o;
  logic [NUM_SA-1:0][VALID_LEN_W-1:0] vlen_o;
  logic flag_in_lz_o, flag_in_lz_fo, flag_out_lz_o, flag_out_lz_fo;

  assign num_heads_i = 16'd4;
  assign ctx_i       = 16'd64;
  assign dim_i       = 16'd128;
  assign hdim_i      = 16'd64;
  assign gs_i        = 8'd32;
  assign saph_i      = 8'd2;
  assign hpp_i       = 8'd2;
  assign qbp_i       = 8'd0;
  assign om_i        = 8'd1;
  assign sc_i        = 8'd0;
  assign dph_i       = 8'd2;
  assign dgc_i       = 16'd4;
  assign cbc_i       = 16'd2;
  assign tail_i      = 32'hFFFF_FFFF;
  assign pgc_i       = 16'd2;
  assign pli_i       = 6'd32;

  lte_task_context dut (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .task_launch              (task_launch),
    .task_mode_i              (task_mode_i),
    .flags_i                  (flags_i),
    .num_heads_i              (num_heads_i),
    .context_length_i         (ctx_i),
    .dim_i                    (dim_i),
    .head_dim_i               (hdim_i),
    .group_size_i             (gs_i),
    .sa_per_head_i            (saph_i),
    .hp_parallel_i            (hpp_i),
    .q_buffer_policy_i        (qbp_i),
    .output_mode_i            (om_i),
    .stream_contract_i        (sc_i),
    .deq_prefill_hint_i       (dph_i),
    .qk_dim_group_count_i     (dgc_i),
    .qk_context_block_count_i (cbc_i),
    .qk_context_tail_mask_i   (tail_i),
    .pv_context_group_count_i (pgc_i),
    .pv_last_inner_count_i    (pli_i),
    .pe_desc_rdata            (pe_desc_i),
    .task_ctx_o               (ctx_o),
    .valid_len_o              (vlen_o),
    .flag_in_lz_o             (flag_in_lz_o),
    .flag_in_lz_full_only_o   (flag_in_lz_fo),
    .flag_out_lz_o            (flag_out_lz_o),
    .flag_out_lz_full_only_o  (flag_out_lz_fo)
  );

  int err_cnt = 0;

  task automatic chk_int(input string name, input int got, input int exp);
    if (got !== exp) begin
      $display("[FAIL] t=%0t %s: got=%0d exp=%0d", $time, name, got, exp);
      err_cnt++;
    end
  endtask

  task automatic chk1(input string name, input logic got, input logic exp);
    if (got !== exp) begin
      $display("[FAIL] t=%0t %s: got=%b exp=%b", $time, name, got, exp);
      err_cnt++;
    end
  endtask

  task clk_tick(input int n = 1);
    repeat(n) @(posedge clk);
    #1;
  endtask

  initial begin
    @(posedge clk); #1;
    rst_n = 1;
    clk_tick(2);

    // ---- TC1: 无 launch，输出保持零 ----
    chk_int("no_launch_mode",    ctx_o.task_mode,      0);
    chk_int("no_launch_heads",   ctx_o.num_heads,      0);
    $display("[PASS] TC1: no-launch output stays zero");

    // ---- TC2: QK 模式 launch ----
    task_mode_i = TASK_MODE_QK;
    flags_i     = 8'b0000_0101;   // in_lz=1, out_lz=1
    // PE desc: SA0=32, SA1=16, SA2=0, SA3=0
    pe_desc_i   = {96'h0, 8'd0, 8'd0, 8'd16, 8'd32};
    task_launch = 1; clk_tick(1); task_launch = 0;
    clk_tick(1);

    chk_int("qk_mode",       ctx_o.task_mode,               TASK_MODE_QK);
    chk_int("num_heads",     ctx_o.num_heads,               4);
    chk_int("qk_dim",        ctx_o.dim,                     128);
    chk_int("qk_dgc",        ctx_o.qk_dim_group_count,      4);
    chk_int("qk_cbc",        ctx_o.qk_context_block_count,  2);
    chk_int("active_sa_cnt", ctx_o.active_sa_count,         2); // SA0=32, SA1=16 → 2 active
    chk_int("vlen_sa0",      vlen_o[0],                     32);
    chk_int("vlen_sa1",      vlen_o[1],                     16);
    chk_int("vlen_sa2",      vlen_o[2],                     0);
    chk1("flag_in_lz",       flag_in_lz_o,                  1'b1);
    chk1("flag_out_lz",      flag_out_lz_o,                 1'b1);
    chk1("flag_in_lz_fo",    flag_in_lz_fo,                 1'b0); // bit[1]=0
    $display("[PASS] TC2: QK launch");

    // ---- TC3: 不发 launch，输出不改变 ----
    task_mode_i = TASK_MODE_PV;
    flags_i     = 8'hFF;
    clk_tick(2);
    chk_int("no_launch_still_qk", ctx_o.task_mode, TASK_MODE_QK);
    $display("[PASS] TC3: values held without launch");

    // ---- TC4: PV 模式 launch ----
    flags_i = 8'b0000_1010; // in_lz_full_only=1, out_lz_full_only=1
    pe_desc_i = {96'h0, 8'd32, 8'd32, 8'd32, 8'd32}; // all 4 SA full
    task_launch = 1; clk_tick(1); task_launch = 0;
    clk_tick(1);

    chk_int("pv_mode",       ctx_o.task_mode,       TASK_MODE_PV);
    chk_int("active_sa4",    ctx_o.active_sa_count,  4);
    chk_int("vlen3",         vlen_o[3],              32);
    chk1("flag_in_lz_off",   flag_in_lz_o,           1'b0); // bit[0]=0
    chk1("flag_in_fo_on",    flag_in_lz_fo,          1'b1); // bit[1]=1
    chk1("flag_out_fo",      flag_out_lz_fo,         1'b1); // bit[3]=1
    $display("[PASS] TC4: PV launch");

    if (err_cnt == 0)
      $display("\n[RESULT] tb_lte_task_context: ALL PASS");
    else
      $display("\n[RESULT] tb_lte_task_context: FAIL (%0d errors)", err_cnt);
    $finish;
  end

endmodule
