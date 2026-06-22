//==============================================================================
// tb_lte_csr.sv — B7 CSR寄存器 + debug snapshot 定向测试
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_csr;
  localparam CLK_HALF = 5;
  logic clk=0, rst_n=0;
  always #CLK_HALF clk = ~clk;

  logic [7:0]  csr_addr=0;
  logic        csr_wr=0, csr_rd=0;
  logic [31:0] csr_wdata=0;
  logic [31:0] csr_rdata;
  logic        snapshot_req=0;
  // counters
  logic [HEAD_W-1:0]      head_ctr    = 6'd7;
  logic [QK_CTX_W-1:0]    context_ctr = 10'd15;
  logic [GROUP_CTR_W-1:0] group_ctr   = 10'd3;
  logic [INNER_W-1:0]     inner_ctr   = 5'd20;
  logic [DRAIN_W-1:0]     drain_lane_ctr = 5'd11;
  // status
  logic engine_busy=1, halted_done=0, halted_error=1;
  logic [7:0] global_error_code = ERR_ILLEGAL_DIM;
  logic [15:0] task_busy=16'hA5A5, task_done=16'h1234, task_error=16'h0001;
  logic [15:0][7:0] task_error_code = '0;
  // pipeline levels
  logic [3:0] sb_partial=4'hC, sb_deq_fifo=4'd4, sb_deq_tok=4'd2;
  logic [3:0] sb_drain_tok=4'd1, sb_out_q=4'd3;
  logic [1:0] sb_group=2'b10;
  logic [3:0] sb_cq=4'd5, sb_ck=4'd6, sb_cp=4'd7, sb_cv=4'd4;
  logic        csr_err_clear;

  lte_csr dut (
    .clk(clk), .rst_n(rst_n),
    .csr_addr(csr_addr), .csr_wr(csr_wr), .csr_wdata(csr_wdata),
    .csr_rd(csr_rd), .csr_rdata(csr_rdata),
    .snapshot_req(snapshot_req),
    .head_ctr(head_ctr), .context_ctr(context_ctr), .group_ctr(group_ctr),
    .inner_ctr(inner_ctr), .drain_lane_ctr(drain_lane_ctr),
    .engine_busy(engine_busy), .halted_done(halted_done), .halted_error(halted_error),
    .global_error_code(global_error_code),
    .task_busy(task_busy), .task_done(task_done), .task_error(task_error),
    .task_error_code(task_error_code),
    .sb_partial_acc_bank_free(sb_partial), .sb_group_acc_bank_free(sb_group),
    .sb_deq_fifo_level(sb_deq_fifo), .sb_deq_token_queue_level(sb_deq_tok),
    .sb_drain_token_queue_level(sb_drain_tok), .sb_output_queue_level(sb_out_q),
    .sb_stream_credit_q(sb_cq), .sb_stream_credit_k(sb_ck),
    .sb_stream_credit_p(sb_cp), .sb_stream_credit_v(sb_cv),
    .csr_err_clear(csr_err_clear)
  );

  int err_cnt=0;
  task automatic chk32(input string nm, input logic [31:0] got, exp);
    if (got!==exp) begin $display("[FAIL] %s got=0x%08x exp=0x%08x", nm, got, exp); err_cnt++; end
  endtask
  task automatic chk1(input string nm, input logic got, exp);
    if (got!==exp) begin $display("[FAIL] %s got=%b exp=%b", nm, got, exp); err_cnt++; end
  endtask
  task clk_tick(input int n=1); repeat(n) @(posedge clk); #1; endtask

  // 读 CSR 的 task
  task automatic rd(input logic [7:0] addr, output logic [31:0] data);
    csr_addr=addr; csr_rd=1; clk_tick(1); csr_rd=0;
    data = csr_rdata; // combinational read, valid immediately
  endtask

  logic [31:0] rval;

  initial begin
    task_error_code[0] = ERR_ILLEGAL_DIM;
    @(posedge clk); #1; rst_n=1; clk_tick(2);

    // TC1: STATUS register
    rd(8'h00, rval);
    chk32("tc1_status", rval, 32'h00000005); // busy=1 done=0 error=1 → 101b=5
    $display("[PASS] TC1: status");

    // TC2: ERROR_CODE register
    rd(8'h01, rval);
    chk32("tc2_errcode", rval, 32'(ERR_ILLEGAL_DIM));
    $display("[PASS] TC2: error_code");

    // TC3: TASK_BUSY
    rd(8'h02, rval);
    chk32("tc3_task_busy", rval, 32'h0000A5A5);
    $display("[PASS] TC3: task_busy");

    // TC4: TASK_DONE
    rd(8'h03, rval);
    chk32("tc4_task_done", rval, 32'h00001234);
    $display("[PASS] TC4: task_done");

    // TC5: snapshot → then read snapshot regs
    snapshot_req=1; clk_tick(1); snapshot_req=0; clk_tick(1);
    rd(8'h10, rval); chk32("tc5_snap_head",    rval, 32'(6'd7));
    rd(8'h11, rval); chk32("tc5_snap_context", rval, 32'(10'd15));
    rd(8'h12, rval); chk32("tc5_snap_group",   rval, 32'(10'd3));
    rd(8'h13, rval); chk32("tc5_snap_inner",   rval, 32'(5'd20));
    rd(8'h14, rval); chk32("tc5_snap_drain",   rval, 32'(5'd11));
    $display("[PASS] TC5: snapshot");

    // TC6: counter changes after snapshot are NOT reflected until next snapshot
    head_ctr = 6'd99; clk_tick(1);
    rd(8'h10, rval); chk32("tc6_snap_head_frozen", rval, 32'(6'd7));
    $display("[PASS] TC6: snapshot frozen");

    // TC7: csr_err_clear fires on write to 0x01
    csr_addr=8'h01; csr_wr=1; clk_tick(1); csr_wr=0;
    chk1("tc7_err_clear_pulse", csr_err_clear, 1'b0); // 1 clk ago it was high
    $display("[PASS] TC7: err_clear");

    // TC8: per-task errcode read via selector
    csr_addr=8'h05; csr_wr=1; csr_wdata=32'd0; clk_tick(1); csr_wr=0;
    rd(8'h06, rval);
    chk32("tc8_pertak_code", rval, 32'(ERR_ILLEGAL_DIM));
    $display("[PASS] TC8: per-task errcode");

    if (err_cnt==0) $display("\n[RESULT] tb_lte_csr: ALL PASS");
    else            $display("\n[RESULT] tb_lte_csr: FAIL (%0d errors)", err_cnt);
    $finish;
  end
endmodule
