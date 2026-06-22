//==============================================================================
// tb_lte_error_ctrl.sv — B8 错误控制器 定向测试
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_error_ctrl;
  localparam CLK_HALF = 5;
  logic clk = 0, rst_n = 0;
  always #CLK_HALF clk = ~clk;

  logic       err_set=0, bp_err_set=0, csr_err_clear=0;
  logic [7:0] err_code=0;
  logic [3:0] err_task_id=0, bp_err_task_id=0;
  logic       halted_error;
  logic [7:0] error_code;
  logic       task_error_set;
  logic [3:0] task_error_id;
  logic [7:0] task_error_code;

  lte_error_ctrl dut(.*);

  int err_cnt = 0;
  task automatic chk1(input string nm, input logic got, input logic exp);
    if (got !== exp) begin $display("[FAIL] %s got=%b exp=%b", nm, got, exp); err_cnt++; end
  endtask
  task automatic chkb(input string nm, input logic [7:0] got, input logic [7:0] exp);
    if (got !== exp) begin $display("[FAIL] %s got=0x%02x exp=0x%02x", nm, got, exp); err_cnt++; end
  endtask
  task clk_tick(input int n=1); repeat(n) @(posedge clk); #1; endtask

  initial begin
    @(posedge clk); #1; rst_n=1; clk_tick(2);

    // TC1: 无错误时输出干净
    chk1("init_no_halt", halted_error, 1'b0);
    $display("[PASS] TC1: init clean");

    // TC2: cfg err → halted_error 置 1, error_code 锁存
    err_set=1; err_code=ERR_ILLEGAL_DIM; err_task_id=4'd2;
    clk_tick(1); err_set=0;
    chk1("tc2_halted",      halted_error,      1'b1);
    chkb("tc2_code",        error_code,         ERR_ILLEGAL_DIM);
    chk1("tc2_sb_set",      task_error_set,    1'b0); // already 1 clk ago
    $display("[PASS] TC2: cfg error latched");

    // TC3: bp err 优先级低 (cfg err 已占), 不覆盖 code
    bp_err_set=1; bp_err_task_id=4'd1;
    clk_tick(1); bp_err_set=0;
    chkb("tc3_code_unchanged", error_code, ERR_ILLEGAL_DIM); // cfg err locked first
    $display("[PASS] TC3: bp err does not override existing code");

    // TC4: csr_err_clear 清除 sticky
    csr_err_clear=1; clk_tick(1); csr_err_clear=0;
    chk1("tc4_cleared",  halted_error, 1'b0);
    chkb("tc4_code_0",   error_code,   ERR_NONE);
    $display("[PASS] TC4: err clear");

    // TC5: bp err alone → BACKPRESSURE_DEBUG
    bp_err_set=1; bp_err_task_id=4'd3;
    clk_tick(1); bp_err_set=0;
    chk1("tc5_halted",   halted_error,   1'b1);
    chkb("tc5_bp_code",  error_code,     ERR_TASK_BACKPRESSURE_DEBUG);
    $display("[PASS] TC5: bp err alone");

    if (err_cnt == 0) $display("\n[RESULT] tb_lte_error_ctrl: ALL PASS");
    else              $display("\n[RESULT] tb_lte_error_ctrl: FAIL (%0d errors)", err_cnt);
    $finish;
  end
endmodule
