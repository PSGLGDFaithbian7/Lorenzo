//==============================================================================
// tb_lte_task_scoreboard.sv — B6 记分板 定向测试
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_task_scoreboard;
  localparam CLK_HALF = 5;
  logic clk=0, rst_n=0;
  always #CLK_HALF clk = ~clk;

  logic       task_busy_set=0, task_done_set=0, task_error_set=0, wait_consume=0;
  logic [3:0] busy_task_id=0, done_task_id=0, task_error_id=0, wait_task_id=0;
  logic [7:0] task_error_code_i=0;
  // datapath levels (just wire to constants in test)
  logic [3:0] partial_acc_bank_free=4'hA, group_acc_bank_free_4=4'hB;
  logic [1:0] group_acc_bank_free = 2'b11;
  logic [3:0] deq_fifo_level=4'd3, deq_token_queue_level=4'd1;
  logic [3:0] drain_token_queue_level=4'd2, output_queue_level=4'd0;
  logic [3:0] stream_credit_q=4'd5, stream_credit_k=4'd6;
  logic [3:0] stream_credit_p=4'd7, stream_credit_v=4'd4;

  logic [15:0] task_busy, task_done, task_error;
  logic [15:0][7:0] task_error_code;
  logic [3:0] sb_partial_acc_bank_free, sb_deq_fifo_level;
  logic [1:0] sb_group_acc_bank_free;
  logic [3:0] sb_deq_token_queue_level, sb_drain_token_queue_level;
  logic [3:0] sb_output_queue_level;
  logic [3:0] sb_stream_credit_q, sb_stream_credit_k, sb_stream_credit_p, sb_stream_credit_v;

  lte_task_scoreboard dut (
    .clk(clk), .rst_n(rst_n),
    .task_busy_set(task_busy_set), .busy_task_id(busy_task_id),
    .task_done_set(task_done_set), .done_task_id(done_task_id),
    .task_error_set(task_error_set), .task_error_id(task_error_id),
    .task_error_code_i(task_error_code_i),
    .wait_consume(wait_consume), .wait_task_id(wait_task_id),
    .partial_acc_bank_free(partial_acc_bank_free),
    .group_acc_bank_free(group_acc_bank_free),
    .deq_fifo_level(deq_fifo_level),
    .deq_token_queue_level(deq_token_queue_level),
    .drain_token_queue_level(drain_token_queue_level),
    .output_queue_level(output_queue_level),
    .stream_credit_q(stream_credit_q), .stream_credit_k(stream_credit_k),
    .stream_credit_p(stream_credit_p), .stream_credit_v(stream_credit_v),
    .task_busy(task_busy), .task_done(task_done), .task_error(task_error),
    .task_error_code(task_error_code),
    .sb_partial_acc_bank_free(sb_partial_acc_bank_free),
    .sb_group_acc_bank_free(sb_group_acc_bank_free),
    .sb_deq_fifo_level(sb_deq_fifo_level),
    .sb_deq_token_queue_level(sb_deq_token_queue_level),
    .sb_drain_token_queue_level(sb_drain_token_queue_level),
    .sb_output_queue_level(sb_output_queue_level),
    .sb_stream_credit_q(sb_stream_credit_q), .sb_stream_credit_k(sb_stream_credit_k),
    .sb_stream_credit_p(sb_stream_credit_p), .sb_stream_credit_v(sb_stream_credit_v)
  );

  int err_cnt=0;
  task automatic chkw(input string nm, input logic [15:0] got, exp);
    if (got!==exp) begin $display("[FAIL] %s got=%04x exp=%04x", nm, got, exp); err_cnt++; end
  endtask
  task automatic chkb(input string nm, input logic [7:0] got, exp);
    if (got!==exp) begin $display("[FAIL] %s got=%02x exp=%02x", nm, got, exp); err_cnt++; end
  endtask
  task automatic chk4(input string nm, input logic [3:0] got, exp);
    if (got!==exp) begin $display("[FAIL] %s got=%x exp=%x", nm, got, exp); err_cnt++; end
  endtask
  task clk_tick(input int n=1); repeat(n) @(posedge clk); #1; endtask

  initial begin
    @(posedge clk); #1; rst_n=1; clk_tick(2);

    // TC1: busy_set for task 3
    busy_task_id=4'd3; task_busy_set=1; clk_tick(1); task_busy_set=0; clk_tick(1);
    chkw("tc1_busy",  task_busy,  16'h0008);
    chkw("tc1_done",  task_done,  16'h0000);
    $display("[PASS] TC1: busy_set");

    // TC2: done_set for task 3
    done_task_id=4'd3; task_done_set=1; clk_tick(1); task_done_set=0; clk_tick(1);
    chkw("tc2_busy_cleared", task_busy, 16'h0000);
    chkw("tc2_done_set",     task_done, 16'h0008);
    $display("[PASS] TC2: done_set clears busy");

    // TC3: wait_consume clears done
    wait_task_id=4'd3; wait_consume=1; clk_tick(1); wait_consume=0; clk_tick(1);
    chkw("tc3_done_cleared", task_done, 16'h0000);
    $display("[PASS] TC3: wait_consume");

    // TC4: error_set for task 5
    busy_task_id=4'd5; task_busy_set=1; clk_tick(1); task_busy_set=0;
    task_error_id=4'd5; task_error_code_i=ERR_ILLEGAL_PV_MAP; task_error_set=1;
    clk_tick(1); task_error_set=0; clk_tick(1);
    chkw("tc4_err_bit",  task_error, 16'h0020);
    chkw("tc4_busy_clr", task_busy,  16'h0000);
    chkb("tc4_code",     task_error_code[5], ERR_ILLEGAL_PV_MAP);
    $display("[PASS] TC4: error_set");

    // TC5: pipeline level passthrough (registered one cycle later)
    chk4("tc5_deq_fifo", sb_deq_fifo_level, 4'd3);
    chk4("tc5_cred_q",   sb_stream_credit_q, 4'd5);
    $display("[PASS] TC5: pipeline levels registered");

    if (err_cnt==0) $display("\n[RESULT] tb_lte_task_scoreboard: ALL PASS");
    else            $display("\n[RESULT] tb_lte_task_scoreboard: FAIL (%0d errors)", err_cnt);
    $finish;
  end
endmodule
