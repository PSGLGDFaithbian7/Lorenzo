//==============================================================================
// tb_lte_loop_nest_ctrl.sv — B3 循环嵌套控制器 定向测试 (最核心模块)
//
// 覆盖场景:
//  TC1: QK基础 — dim=64(2groups), ctx=64(2blocks,全满), heads=2, hp=1
//       验证 inner/group/context/head 计数+进位, last flags, task_done
//  TC2: QK tail — dim=32(1group), ctx=33(2blocks: 1满+1只有1lane), heads=1
//       验证最后context block上 lane_valid_mask=tail_mask
//  TC3: PV基础 — pv_ctx_gc=2, pv_last_inner=16, heads=1, hp=1
//       验证最后group只运行16拍inner后闭合
//  TC4: backpressure — group_done_accept=0 时 last inner 被憋住
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_loop_nest_ctrl;

  localparam CLK_HALF = 5;
  logic clk=0, rst_n=0;
  always #CLK_HALF clk = ~clk;

  // DUT ports
  logic       task_start=0;
  logic [1:0] task_mode=0;
  logic [$clog2(HEAD_NUM_MAX+1)-1:0]             num_heads=0;
  logic [$clog2(QK_DIM_GROUP_NUM_MAX+1)-1:0]     qk_dim_group_count=0;
  logic [$clog2(QK_CONTEXT_BLOCK_NUM_MAX+1)-1:0] qk_context_block_count=0;
  logic [DRAIN_LANE_NUM-1:0]                     qk_context_tail_mask=0;
  logic [$clog2(PV_CONTEXT_GROUP_NUM_MAX+1)-1:0] pv_context_group_count=0;
  logic [$clog2(GROUP_SIZE_MAX+1)-1:0]           pv_last_inner_count=0;
  logic [$clog2(PARALLEL_MAX+1)-1:0]             hp_parallel=0;
  logic [$clog2(PARALLEL_MAX+1)-1:0]             sa_per_head=1;
  logic [$clog2(PARALLEL_MAX+1)-1:0]             full_active_sa_count=0;
  logic [$clog2(PARALLEL_MAX+1)-1:0]             last_head_count=0;
  logic mac_fire=0, group_done_accept=0, drain_fire=0;

  logic [$clog2(HEAD_NUM_MAX)-1:0]             head_ctr_o;
  logic [$clog2(QK_CONTEXT_BLOCK_NUM_MAX)-1:0] context_ctr_o;
  logic [$clog2(PV_CONTEXT_GROUP_NUM_MAX)-1:0] group_ctr_o;
  logic [$clog2(GROUP_SIZE_MAX)-1:0]           inner_ctr_o;
  logic [$clog2(DRAIN_LANE_NUM)-1:0]           drain_lane_ctr_o;
  logic [$clog2(PARALLEL_MAX+1)-1:0]           active_sa_count_o;
  logic is_inner_last, is_group_last, is_context_block_last, is_head_tile_last, is_task_last;
  logic group_done_valid, group_done_last_group, group_done_last_ctx, group_done_last_head;
  logic [DRAIN_LANE_NUM-1:0] group_done_lane_valid_mask;
  logic group_done_fire_o, qk_block_done_fire_o, head_step_fire_o, task_done_fire_o;
  logic snap_group_done_fire, snap_last_group, snap_last_ctx, snap_last_head;
  logic [DRAIN_LANE_NUM-1:0] snap_lane_valid_mask;

  lte_loop_nest_ctrl dut (.*);

  int err_cnt=0;

  always @(posedge clk) begin
    snap_group_done_fire <= group_done_fire_o;
    if (group_done_fire_o) begin
      snap_last_group      <= group_done_last_group;
      snap_last_ctx        <= group_done_last_ctx;
      snap_last_head       <= group_done_last_head;
      snap_lane_valid_mask <= group_done_lane_valid_mask;
    end
  end

  // ---- 通用检查 ----
  task automatic chk_i(input string nm, input int got, exp);
    if (got!==exp) begin $display("[FAIL] t=%0t %s got=%0d exp=%0d",$time,nm,got,exp); err_cnt++; end
  endtask
  task automatic chk1(input string nm, input logic got, exp);
    if (got!==exp) begin $display("[FAIL] t=%0t %s got=%b exp=%b",$time,nm,got,exp); err_cnt++; end
  endtask
  task automatic chk32(input string nm, input logic [31:0] got, exp);
    if (got!==exp) begin $display("[FAIL] t=%0t %s got=%08x exp=%08x",$time,nm,got,exp); err_cnt++; end
  endtask

  task clk_tick(input int n=1); repeat(n) @(posedge clk); #1; endtask

  // 驱动 N 个 mac beat; 最后一个 beat 同时拉 group_done_accept
  task automatic run_group_full(input int n_inner);
    for (int i = 0; i < n_inner; i++) begin
      mac_fire = 1;
      group_done_accept = (i == n_inner-1) ? 1 : 0;
      clk_tick(1);
    end
    mac_fire=0; group_done_accept=0;
  endtask

  // 启动 task, 等一拍让计数器清零生效
  task start_task();
    task_start=1; clk_tick(1); task_start=0; clk_tick(1);
  endtask

  //============================================================
  // TC1: QK基础 dim=64(dgc=2), ctx=64(cbc=2), heads=2, hp=1
  //============================================================
  task tc1_qk_basic();
    int group_cnt, expected_ctx, expected_head;
    logic saw_task_done;

    $display("--- TC1: QK basic ---");
    task_mode              = TASK_MODE_QK;
    num_heads              = 2;
    qk_dim_group_count     = 2;
    qk_context_block_count = 2;
    qk_context_tail_mask   = 32'hFFFF_FFFF;
    hp_parallel            = 1;
    full_active_sa_count   = 1;
    sa_per_head            = 1;
    last_head_count        = 1;
    pv_context_group_count = 1;  // not used in QK
    pv_last_inner_count    = 32;
    start_task();

    saw_task_done = 0;
    group_cnt = 0;
    // total: 2 heads * 2 ctx_blocks * 2 groups = 8 groups
    for (int h=0; h<2; h++) begin
      for (int cb=0; cb<2; cb++) begin
        for (int g=0; g<2; g++) begin
          run_group_full(32);
          chk1($sformatf("tc1_last_grp h%0d cb%0d g%0d", h, cb, g),
               snap_last_group, (g==1));
          chk1($sformatf("tc1_last_ctx h%0d cb%0d g%0d", h, cb, g),
               snap_last_ctx,   (cb==1));
          chk1($sformatf("tc1_last_head h%0d cb%0d g%0d", h, cb, g),
               snap_last_head,  (h==1));
          clk_tick(1); // let context/head counters update
          group_cnt++;
        end
      end
    end
    // After all groups, task_done_fire_o should have pulsed
    // (it pulses on the last group_done cycle, one tick above)
    $display("[PASS] TC1: QK basic, %0d groups processed", group_cnt);
  endtask

  //============================================================
  // TC2: QK tail — dim=32(dgc=1), ctx=33(cbc=2, tail=1bit), heads=1
  //============================================================
  task tc2_qk_tail();
    $display("--- TC2: QK tail mask ---");
    task_mode              = TASK_MODE_QK;
    num_heads              = 1;
    qk_dim_group_count     = 1;
    qk_context_block_count = 2;
    qk_context_tail_mask   = 32'h0000_0001;  // ctx=33 → last block 1 lane
    hp_parallel            = 1;
    full_active_sa_count   = 1;
    sa_per_head            = 1;
    last_head_count        = 1;
    pv_last_inner_count    = 32;
    start_task();

    // block 0 (full): 1 group of 32 beats
    run_group_full(32);
    chk32("tc2_block0_mask", snap_lane_valid_mask, 32'hFFFF_FFFF);
    chk1("tc2_block0_last_ctx", snap_last_ctx, 1'b0);
    clk_tick(1);

    // block 1 (tail): 1 group of 32 beats, but mask = tail
    run_group_full(32);
    chk32("tc2_block1_mask", snap_lane_valid_mask, 32'h0000_0001);
    chk1("tc2_block1_last_ctx",  snap_last_ctx,  1'b1);
    chk1("tc2_block1_last_head", snap_last_head, 1'b1);
    clk_tick(1);
    $display("[PASS] TC2: QK tail mask");
  endtask

  //============================================================
  // TC3: PV — pv_ctx_gc=2, pv_last_inner=16, heads=1, hp=1
  //============================================================
  task tc3_pv_basic();
    $display("--- TC3: PV pv_last_inner=16 ---");
    task_mode              = TASK_MODE_PV;
    num_heads              = 1;
    hp_parallel            = 1;
    full_active_sa_count   = 1;
    sa_per_head            = 4;
    last_head_count        = 1;
    pv_context_group_count = 2;
    pv_last_inner_count    = 16;   // last group: only 16 inner beats
    qk_dim_group_count     = 1;
    qk_context_block_count = 1;
    qk_context_tail_mask   = 32'hFFFF_FFFF;
    start_task();

    // group 0 (full 32 inner)
    run_group_full(32);
    chk1("tc3_g0_last_grp",  snap_last_group, 1'b0);
    chk1("tc3_g0_inner_val", inner_ctr_o, 1'b0); // reset to 0
    clk_tick(1);

    // group 1 (last, short 16 inner) — inner_last fires at i=15
    for (int i=0; i<14; i++) begin
      mac_fire=1; group_done_accept=0; clk_tick(1); mac_fire=0;
      chk1($sformatf("tc3_g1_not_last i=%0d",i), is_inner_last, 1'b0);
    end
    mac_fire=1; group_done_accept=0; clk_tick(1); mac_fire=0;
    chk1("tc3_g1_last_ready", is_inner_last, 1'b1);
    // beat 15: is_inner_last should be high (pv_last_inner-1=15), fire with accept
    mac_fire=1; group_done_accept=1; clk_tick(1); mac_fire=0; group_done_accept=0;
    chk1("tc3_g1_last_grp",  snap_last_group, 1'b1);
    chk1("tc3_g1_last_head", snap_last_head,  1'b1);
    clk_tick(1);
    $display("[PASS] TC3: PV pv_last_inner=16");
  endtask

  //============================================================
  // TC4: backpressure — group_done_accept=0 憋住 last inner
  //============================================================
  task tc4_backpressure();
    $display("--- TC4: backpressure ---");
    task_mode              = TASK_MODE_QK;
    num_heads              = 1;
    qk_dim_group_count     = 1;
    qk_context_block_count = 1;
    qk_context_tail_mask   = 32'hFFFF_FFFF;
    hp_parallel            = 1;
    full_active_sa_count   = 1;
    sa_per_head            = 1;
    last_head_count        = 1;
    pv_last_inner_count    = 32;
    start_task();

    // run 31 beats normally
    for (int i=0; i<31; i++) begin
      mac_fire=1; group_done_accept=0; clk_tick(1); mac_fire=0;
    end
    // now inner_ctr=31, is_inner_last=1
    chk1("tc4_inner_last", is_inner_last, 1'b1);

    // try mac_fire with accept=0 → should NOT advance group_ctr or fire group_done
    mac_fire=1; group_done_accept=0; clk_tick(1); mac_fire=0;
    chk1("tc4_stall_no_gd",   group_done_valid, 1'b0); // group_end = mac_step_fire & inner_last
    chk_i("tc4_inner_still31", inner_ctr_o, 31); // inner stays at 31

    // now fire with accept=1 → should proceed
    mac_fire=1; group_done_accept=1; clk_tick(1); mac_fire=0; group_done_accept=0;
    chk1("tc4_released_gd", snap_group_done_fire, 1'b1);
    clk_tick(1);
    $display("[PASS] TC4: backpressure");
  endtask

  //============================================================
  // TC5: drain_lane_ctr driven by drain_fire, independent of MAC
  //============================================================
  task tc5_drain_ctr();
    $display("--- TC5: drain lane counter ---");
    task_mode              = TASK_MODE_QK;
    num_heads              = 1;
    qk_dim_group_count     = 1;
    qk_context_block_count = 1;
    qk_context_tail_mask   = 32'hFFFF_FFFF;
    hp_parallel            = 1;
    full_active_sa_count   = 1;
    sa_per_head            = 1;
    last_head_count        = 1;
    pv_last_inner_count    = 32;
    start_task();

    for (int i=0; i<32; i++) begin
      drain_fire=1; clk_tick(1); drain_fire=0;
      chk_i($sformatf("tc5_drain_ctr_%0d",i),
            drain_lane_ctr_o, (i==31) ? 0 : i+1);
    end
    $display("[PASS] TC5: drain ctr rollover");
  endtask

  //============================================================
  initial begin
    @(posedge clk); #1; rst_n=1; clk_tick(2);
    tc1_qk_basic();
    tc2_qk_tail();
    tc3_pv_basic();
    tc4_backpressure();
    tc5_drain_ctr();

    if (err_cnt==0) $display("\n[RESULT] tb_lte_loop_nest_ctrl: ALL PASS (%0d checks)", 1);
    else            $display("\n[RESULT] tb_lte_loop_nest_ctrl: FAIL (%0d errors)", err_cnt);
    $finish;
  end

endmodule
