//==============================================================================
// tb_lte_task_dispatch.sv — B1 任务派发器 定向测试
// 覆盖: 正常启动, busy拒绝, wait_on_launch挂起, 配置错误路径
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_task_dispatch;

  localparam CLK_HALF = 5;
  logic clk = 0, rst_n = 0;
  always #CLK_HALF clk = ~clk;

  // DUT I/O
  logic        csr_start = 0, csr_wait_on_launch = 0;
  logic [3:0]  csr_task_id = 0;
  logic [3:0]  tdt_raddr;
  logic [255:0] tdt_rdata = '0;
  logic        cfg_legal = 1, engine_task_done = 0;
  logic [7:0]  cfg_error_code = 8'h01;

  logic        task_launch, task_start;
  logic [3:0]  task_id_o;
  logic        engine_busy, task_busy_set, task_done_set;
  logic [3:0]  done_task_id;
  logic        err_set;
  logic [7:0]  err_code;
  logic [3:0]  err_task_id;

  lte_task_dispatch dut (.*);

  int err_cnt = 0;

  task automatic chk1(input string nm, input logic got, input logic exp);
    if (got !== exp) begin
      $display("[FAIL] t=%0t %s: got=%b exp=%b", $time, nm, got, exp);
      err_cnt++;
    end
  endtask

  task clk_tick(input int n = 1);
    repeat(n) @(posedge clk); #1;
  endtask

  initial begin
    @(posedge clk); #1; rst_n = 1; clk_tick(2);

    // ---- TC1: 正常启动流程 ----
    cfg_legal = 1;
    csr_task_id = 4'd3;
    csr_start = 1; clk_tick(1); csr_start = 0;
    // IDLE->FETCH (raddr=3)
    clk_tick(1);
    // FETCH->LAUNCH: task_launch must fire
    chk1("tc1_launch", task_launch, 1'b1);
    chk1("tc1_busy",   engine_busy, 1'b1);
    clk_tick(1);
    // LAUNCH->START: task_start must fire
    chk1("tc1_start",  task_start, 1'b1);
    clk_tick(1);
    // Now in RUN
    chk1("tc1_run_busy", engine_busy, 1'b1);
    // Signal done
    engine_task_done = 1; clk_tick(1); engine_task_done = 0;
    clk_tick(1);
    chk1("tc1_idle_after_done", engine_busy, 1'b0);
    $display("[PASS] TC1: normal launch");

    // ---- TC2: busy 期间拒绝 (wait_on_launch=0) ----
    cfg_legal = 1; csr_wait_on_launch = 0;
    csr_task_id = 4'd1; csr_start = 1; clk_tick(1); csr_start = 0;
    clk_tick(3); // now in RUN
    chk1("tc2_busy_running", engine_busy, 1'b1);
    // Send another start while busy
    csr_task_id = 4'd2; csr_start = 1; clk_tick(1); csr_start = 0;
    chk1("tc2_err_set", err_set, 1'b1);
    chk1("tc2_err_code", err_code == ERR_TASK_ENGINE_BUSY, 1'b1);
    // Finish first task
    engine_task_done = 1; clk_tick(1); engine_task_done = 0;
    clk_tick(2);
    $display("[PASS] TC2: busy reject");

    // ---- TC3: wait_on_launch=1 — 挂起等待 ----
    cfg_legal = 1; csr_wait_on_launch = 1;
    csr_task_id = 4'd5; csr_start = 1; clk_tick(1); csr_start = 0;
    clk_tick(3); // task 5 running
    // Request task 7 while busy → should pend
    csr_task_id = 4'd7; csr_start = 1; clk_tick(1); csr_start = 0;
    chk1("tc3_no_err", err_set, 1'b0); // no error, pending
    // Finish task 5 → should auto-launch task 7
    engine_task_done = 1; clk_tick(1); engine_task_done = 0;
    clk_tick(2); // task 7 should launch
    chk1("tc3_pending_launched", engine_busy, 1'b1);
    engine_task_done = 1; clk_tick(1); engine_task_done = 0;
    clk_tick(2);
    $display("[PASS] TC3: wait_on_launch pending");

    // ---- TC4: 配置非法 → err_set, 不启动 ----
    cfg_legal = 0; cfg_error_code = ERR_ILLEGAL_DIM;
    csr_task_id = 4'd0; csr_start = 1; clk_tick(1); csr_start = 0;
    clk_tick(2); // FETCH -> ERROR
    chk1("tc4_err_set",    err_set,   1'b1);
    chk1("tc4_err_code",   err_code == ERR_ILLEGAL_DIM, 1'b1);
    chk1("tc4_not_busy",   engine_busy, 1'b0); // should return to IDLE
    clk_tick(2);
    $display("[PASS] TC4: illegal cfg -> error");

    if (err_cnt == 0)
      $display("\n[RESULT] tb_lte_task_dispatch: ALL PASS");
    else
      $display("\n[RESULT] tb_lte_task_dispatch: FAIL (%0d errors)", err_cnt);
    $finish;
  end

endmodule
