//==============================================================================
// tb_lte_boundary_ctrl.sv — B4 边界控制器 定向测试
// 覆盖: 6类边界事件相位、QK/PV模式差异、token字段、full_pe_active动态判断
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_boundary_ctrl;

  localparam CLK_HALF = 5;
  logic clk=0, rst_n=0;
  always #CLK_HALF clk = ~clk;

  // DUT inputs
  logic       task_start=0;
  logic [1:0] task_mode=0;
  logic       group_done_fire=0, qk_block_done_fire=0, head_step_fire=0, task_done_fire=0;
  logic [HEAD_W-1:0]         head_ctr=0;
  logic [QK_CTX_W-1:0]       context_ctr=0;
  logic [GROUP_CTR_W-1:0]    group_ctr=0;
  logic                      group_done_last_group=0, group_done_last_ctx=0, group_done_last_head=0;
  logic [DRAIN_LANE_NUM-1:0] group_done_lane_valid_mask=32'hFFFF_FFFF;
  logic [7:0]  output_mode=0;
  logic        flag_in_lz=1, flag_in_lz_full_only=0;
  logic        flag_out_lz=1, flag_out_lz_full_only=0;
  logic [5:0]  pv_last_inner_count=6'd32;

  // DUT outputs
  logic head_tile_start, row_start, group_start;
  logic group_done_pulse, row_done_pulse, head_tile_done_pulse, task_done_pulse;
  logic deq_token_valid;
  deq_token_meta_t deq_token_meta;
  logic drain_token_valid;
  drain_token_meta_t drain_token_meta;
  logic full_pe_active, use_input_lorenzo, use_output_lorenzo;

  lte_boundary_ctrl dut (.*);

  int err_cnt=0;
  task automatic chk1(input string nm, input logic got, exp);
    if (got!==exp) begin $display("[FAIL] t=%0t %s got=%b exp=%b",$time,nm,got,exp); err_cnt++; end
  endtask
  task automatic chk32(input string nm, input logic [31:0] got, exp);
    if (got!==exp) begin $display("[FAIL] t=%0t %s got=%08x exp=%08x",$time,nm,got,exp); err_cnt++; end
  endtask
  task clk_tick(input int n=1); repeat(n) @(posedge clk); #1; endtask

  // 发一拍脉冲的 helper
  task automatic pulse(ref logic sig);
    sig=1; clk_tick(1); sig=0; #1;
  endtask

  initial begin
    @(posedge clk); #1; rst_n=1; clk_tick(2);

    //--------------------------------------------------------------------
    // TC1: task_start 同拍产生 group_start + head_tile_start
    // (QK mode 还额外产生 row_start)
    //--------------------------------------------------------------------
    task_mode = TASK_MODE_QK;
    task_start=1; clk_tick(1); task_start=0; #1;
    chk1("tc1_group_start",     group_start,     1'b0); // fires on task_start cycle, now 1 tick later
    // 检查上一拍的组合输出 (clk_tick已走过，需要在走之前检查):
    // 重新发 task_start 并在同一拍检查
    task_start=1;
    #1; // combinational settle
    chk1("tc1_gs_combo",    group_start,     1'b1);
    chk1("tc1_hts_combo",   head_tile_start, 1'b1);
    chk1("tc1_rs_combo",    row_start,       1'b1); // QK only
    @(posedge clk); #1; task_start=0;
    $display("[PASS] TC1: task_start events");

    //--------------------------------------------------------------------
    // TC2: group_done_fire → group_done_pulse + deq_token_valid, token字段
    //--------------------------------------------------------------------
    head_ctr=6'd2; context_ctr=10'd1; group_ctr=10'd3;
    group_done_last_group=1'b0; group_done_last_ctx=1'b1; group_done_last_head=1'b0;
    group_done_lane_valid_mask = 32'hFFFF_FFFF;
    group_done_fire=1; #1;
    chk1("tc2_gdp",          group_done_pulse,    1'b1);
    chk1("tc2_deq_valid",    deq_token_valid,     1'b1);
    chk1("tc2_deq_last_grp", deq_token_meta.last_group, 1'b0);
    chk1("tc2_deq_last_ctx", deq_token_meta.last_ctx,   1'b1);
    chk1("tc2_deq_last_hd",  deq_token_meta.last_head,  1'b0);
    chk32("tc2_deq_mask",    deq_token_meta.lane_valid_mask, 32'hFFFF_FFFF);
    @(posedge clk); #1; group_done_fire=0;
    $display("[PASS] TC2: group_done token");

    //--------------------------------------------------------------------
    // TC3: qk_block_done_fire → row_done_pulse + drain_token_valid (QK)
    //      head_step_fire 不同时 → head_tile_done_pulse 不发
    //--------------------------------------------------------------------
    task_mode = TASK_MODE_QK;
    group_done_last_group=1'b1;
    group_done_lane_valid_mask = 32'h0000_000F; // tail mask
    qk_block_done_fire=1; head_step_fire=0; task_done_fire=0; #1;
    chk1("tc3_row_done",      row_done_pulse,      1'b1);
    chk1("tc3_drain_valid",   drain_token_valid,   1'b1);
    chk32("tc3_drain_mask",   drain_token_meta.lane_valid_mask, 32'h0000_000F);
    chk1("tc3_no_hdone",      head_tile_done_pulse, 1'b0);
    @(posedge clk); #1; qk_block_done_fire=0;
    $display("[PASS] TC3: QK row_done");

    //--------------------------------------------------------------------
    // TC4: head_step_fire → head_tile_done_pulse; 如果不是 task_done, group_start 在下一拍发
    //--------------------------------------------------------------------
    task_done_fire=0; head_step_fire=1; #1;
    chk1("tc4_hdone",         head_tile_done_pulse, 1'b1);
    chk1("tc4_hts_on_step",   head_tile_start, 1'b1); // ~task_done → new head tile starts
    @(posedge clk); #1; head_step_fire=0;
    $display("[PASS] TC4: head_tile_done");

    //--------------------------------------------------------------------
    // TC5: task_done_fire → task_done_pulse, 但 group_start 不发 (task结束)
    //--------------------------------------------------------------------
    group_done_fire=1; task_done_fire=1; #1;
    chk1("tc5_task_done",    task_done_pulse, 1'b1);
    chk1("tc5_no_gs",        group_start,    1'b0); // group_done_fire & task_done → no new group_start
    @(posedge clk); #1; group_done_fire=0; task_done_fire=0;
    $display("[PASS] TC5: task_done, no new group_start");

    //--------------------------------------------------------------------
    // TC6: PV mode — no row_done, head_tile_done 由 head_step_fire 发
    //      drain_token_valid 在 head_step_fire (not qk_block_done) 时发
    //--------------------------------------------------------------------
    task_mode = TASK_MODE_PV;
    pv_last_inner_count = 6'd32;
    group_done_lane_valid_mask = 32'hFFFF_FFFF;
    // qk_block_done should NOT produce drain in PV
    qk_block_done_fire=1; #1;
    chk1("tc6_no_row_done",    row_done_pulse,    1'b0); // PV: no row_done
    chk1("tc6_no_drain_pv_qkb",drain_token_valid, 1'b0);
    @(posedge clk); #1; qk_block_done_fire=0;
    // head_step_fire → drain_token in PV
    head_step_fire=1; task_done_fire=0; #1;
    chk1("tc6_pv_drain_valid", drain_token_valid, 1'b1);
    chk1("tc6_pv_drain_mode",  drain_token_meta.mode, 1'b1); // 1=PV
    chk32("tc6_pv_drain_mask", drain_token_meta.lane_valid_mask, 32'hFFFF_FFFF);
    @(posedge clk); #1; head_step_fire=0;
    $display("[PASS] TC6: PV mode events");

    //--------------------------------------------------------------------
    // TC7: full_pe_active / use_input_lorenzo 动态判断
    //  QK 且 lane_mask = 全1 → full_pe_active=1 → lz=1
    //  QK 且 lane_mask ≠ 全1 → full_pe_active=0 → lz取决于 full_only flag
    //--------------------------------------------------------------------
    task_mode = TASK_MODE_QK;
    // flag_in_lz=1, flag_in_lz_full_only=1 → only when full
    flag_in_lz=1; flag_in_lz_full_only=1;
    group_done_lane_valid_mask = 32'hFFFF_FFFF; #1;
    chk1("tc7_full_lz_on",   use_input_lorenzo, 1'b1);
    group_done_lane_valid_mask = 32'h0000_000F; #1;
    chk1("tc7_tail_lz_off",  use_input_lorenzo, 1'b0); // not full → off
    // flag_in_lz_full_only=0 → lz always on (if flag_in_lz=1)
    flag_in_lz_full_only=0; #1;
    chk1("tc7_always_lz_on", use_input_lorenzo, 1'b1);
    $display("[PASS] TC7: dynamic use_input_lorenzo");

    //--------------------------------------------------------------------
    // TC8: PV full_pe_active — last group but pv_last_inner_count=32 → still full
    //--------------------------------------------------------------------
    task_mode = TASK_MODE_PV;
    flag_in_lz=1; flag_in_lz_full_only=1;
    group_done_last_group = 1'b1;
    pv_last_inner_count = 6'd32; #1;
    chk1("tc8_pv_full",  use_input_lorenzo, 1'b1);
    pv_last_inner_count = 6'd16; #1;
    chk1("tc8_pv_short", use_input_lorenzo, 1'b0);
    $display("[PASS] TC8: PV dynamic full_pe_active");

    if (err_cnt==0) $display("\n[RESULT] tb_lte_boundary_ctrl: ALL PASS");
    else            $display("\n[RESULT] tb_lte_boundary_ctrl: FAIL (%0d errors)", err_cnt);
    $finish;
  end

endmodule
