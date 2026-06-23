//==============================================================================
// tb_lte_task_ctrl_top.sv — 控制面集成 TB (定向测试)
//
// 场景:
//  TC1: QK dim=64(dgc=2), ctx=64(cbc=2,全满), heads=1
//  TC2: QK dim=32(dgc=1), ctx=33(cbc=2,tail=0x1), heads=1
//  TC3: PV head_dim=128(hp=1), ctx=64(pgc=2,pli=32), heads=1
//  TC4: PV head_dim=64(hp=2), ctx=33(pgc=2,pli=1), heads=2
//  TC5: 非法 desc_type → err_set, 不启动
//  TC6: QK 多 head — dim=32, ctx=32, heads=4, hp=1
//==============================================================================
`timescale 1ns/1ps
import lte_pkg::*;

module tb_lte_task_ctrl_top;

  localparam CLK_HALF = 5;
  logic clk=0, rst_n=0;
  always #CLK_HALF clk = ~clk;

  //--------------------------------------------------------------------------
  // TDT / PE descriptor RAM 模型 (组合读, dispatch FSM 做1拍流水)
  //--------------------------------------------------------------------------
  logic [255:0] tdt_mem[0:15];
  logic [127:0] pe_mem [0:15];
  logic [3:0]   tdt_raddr, pe_desc_raddr;
  logic [255:0] tdt_rdata;
  logic [127:0] pe_desc_rdata;
  assign tdt_rdata     = tdt_mem[tdt_raddr];
  assign pe_desc_rdata = pe_mem[pe_desc_raddr];

  //--------------------------------------------------------------------------
  // DUT I/O
  //--------------------------------------------------------------------------
  logic       csr_start=0, csr_wait_on_launch=0;
  logic [3:0] csr_task_id=0;
  logic       snapshot_req=0, wait_consume=0;
  logic [3:0] wait_task_id=0;
  logic [7:0] csr_addr=0;
  logic       csr_wr=0, csr_rd=0;
  logic [31:0]csr_wdata=0, csr_rdata;

  // A→B
  logic mac_fire=0, group_done_accept=0, drain_fire=0, engine_task_done=0;
  logic [3:0] partial_acc_bank_free=4'hF;
  logic [1:0] group_acc_bank_free=2'b11;
  logic [3:0] deq_fifo_level=0, deq_token_queue_level=0;
  logic [3:0] drain_token_queue_level=0, output_queue_level=0;
  logic [3:0] stream_credit_q=4'd8, stream_credit_k=4'd8;
  logic [3:0] stream_credit_p=4'd8, stream_credit_v=4'd8;
  logic       bp_err_set=0;
  logic [3:0] bp_err_task_id=0;

  // B→A
  task_ctx_t  task_ctx;
  logic [1:0] task_mode_o;
  logic [7:0] active_sa_count;
  logic       use_input_lorenzo, use_output_lorenzo;
  logic [NUM_SA-1:0][VALID_LEN_W-1:0] valid_len;
  logic       task_start_o;
  logic       head_tile_start, row_start, group_start;
  logic       group_done_pulse, row_done_pulse, head_tile_done_pulse, task_done_pulse;
  logic       deq_token_valid;
  deq_token_meta_t  deq_token_meta;
  logic       drain_token_valid;
  drain_token_meta_t drain_token_meta;
  logic [$clog2(HEAD_NUM_MAX)-1:0]              head_ctr;
  logic [$clog2(QK_CONTEXT_BLOCK_NUM_MAX)-1:0]  context_ctr;
  logic [$clog2(PV_CONTEXT_GROUP_NUM_MAX)-1:0]  group_ctr;
  logic [$clog2(GROUP_SIZE_MAX)-1:0]            inner_ctr;
  logic [$clog2(DRAIN_LANE_NUM)-1:0]            drain_lane_ctr;
  logic       engine_busy, halted_error;
  logic [7:0] error_code;

  lte_task_ctrl_top dut (
    .clk(clk), .rst_n(rst_n),
    .csr_start(csr_start), .csr_task_id(csr_task_id),
    .csr_wait_on_launch(csr_wait_on_launch),
    .snapshot_req(snapshot_req),
    .wait_consume(wait_consume), .wait_task_id(wait_task_id),
    .csr_addr(csr_addr), .csr_wr(csr_wr), .csr_rd(csr_rd),
    .csr_wdata(csr_wdata), .csr_rdata(csr_rdata),
    .tdt_raddr(tdt_raddr), .tdt_rdata(tdt_rdata),
    .pe_desc_raddr(pe_desc_raddr), .pe_desc_rdata(pe_desc_rdata),
    .mac_fire(mac_fire), .group_done_accept(group_done_accept),
    .drain_fire(drain_fire), .engine_task_done(engine_task_done),
    .partial_acc_bank_free(partial_acc_bank_free),
    .group_acc_bank_free(group_acc_bank_free),
    .deq_fifo_level(deq_fifo_level),
    .deq_token_queue_level(deq_token_queue_level),
    .drain_token_queue_level(drain_token_queue_level),
    .output_queue_level(output_queue_level),
    .stream_credit_q(stream_credit_q), .stream_credit_k(stream_credit_k),
    .stream_credit_p(stream_credit_p), .stream_credit_v(stream_credit_v),
    .bp_err_set(bp_err_set), .bp_err_task_id(bp_err_task_id),
    .task_ctx(task_ctx), .task_mode(task_mode_o),
    .active_sa_count(active_sa_count),
    .use_input_lorenzo(use_input_lorenzo), .use_output_lorenzo(use_output_lorenzo),
    .valid_len(valid_len),
    .task_start(task_start_o),
    .head_tile_start(head_tile_start), .row_start(row_start),
    .group_start(group_start),
    .group_done_pulse(group_done_pulse), .row_done_pulse(row_done_pulse),
    .head_tile_done_pulse(head_tile_done_pulse), .task_done_pulse(task_done_pulse),
    .deq_token_valid(deq_token_valid), .deq_token_meta(deq_token_meta),
    .drain_token_valid(drain_token_valid), .drain_token_meta(drain_token_meta),
    .head_ctr(head_ctr), .context_ctr(context_ctr),
    .group_ctr(group_ctr), .inner_ctr(inner_ctr),
    .drain_lane_ctr(drain_lane_ctr),
    .engine_busy(engine_busy), .halted_error(halted_error),
    .error_code(error_code)
  );

  //--------------------------------------------------------------------------
  // 脉冲事件计数器 (posedge 捕获, 用于事后校验数量)
  //--------------------------------------------------------------------------
  int cnt_group_done   = 0;
  int cnt_row_done     = 0;
  int cnt_head_done    = 0;
  int cnt_task_done    = 0;
  int cnt_drain_tok    = 0;

  always @(posedge clk) begin
    if (group_done_pulse)      cnt_group_done++;
    if (row_done_pulse)        cnt_row_done++;
    if (head_tile_done_pulse)  cnt_head_done++;
    if (task_done_pulse)       cnt_task_done++;
    if (drain_token_valid)     cnt_drain_tok++;
  end

  // 清除所有计数器
  task automatic reset_counters();
    @(posedge clk); #1;
    cnt_group_done=0; cnt_row_done=0; cnt_head_done=0;
    cnt_task_done=0;  cnt_drain_tok=0;
  endtask

  // 捕获 group_done 那一拍的 token last 字段 (辅助检查)
  logic snap_last_group, snap_last_ctx, snap_last_head;
  logic [HEAD_W-1:0] snap_head_tile_id;
  logic [31:0] snap_lane_mask;
  always @(posedge clk) begin
    if (group_done_pulse) begin
      snap_last_group <= deq_token_meta.last_group;
      snap_last_ctx   <= deq_token_meta.last_ctx;
      snap_last_head  <= deq_token_meta.last_head;
      snap_head_tile_id <= deq_token_meta.head_tile_id;
      snap_lane_mask  <= deq_token_meta.lane_valid_mask;
    end
  end

  //--------------------------------------------------------------------------
  // 通用检查工具
  //--------------------------------------------------------------------------
  int  err_cnt = 0;
  string cur_tc = "NONE";

  task automatic chk1(input string nm, input logic got, exp);
    if (got !== exp) begin
      $display("[FAIL][%s] t=%0t %s: got=%b exp=%b", cur_tc, $time, nm, got, exp);
      err_cnt++;
    end
  endtask

  task automatic chk_i(input string nm, input int got, exp);
    if (got !== exp) begin
      $display("[FAIL][%s] t=%0t %s: got=%0d exp=%0d", cur_tc, $time, nm, got, exp);
      err_cnt++;
    end
  endtask

  task automatic chk32(input string nm, input logic [31:0] got, exp);
    if (got !== exp) begin
      $display("[FAIL][%s] t=%0t %s: got=%08x exp=%08x", cur_tc, $time, nm, got, exp);
      err_cnt++;
    end
  endtask

  task clk_tick(input int n=1); repeat(n) @(posedge clk); #1; endtask

  //--------------------------------------------------------------------------
  // PE descriptor: 所有 SA valid_len=32
  //--------------------------------------------------------------------------
  task automatic init_pe(input int id);
    pe_mem[id] = {96'h0, 8'd32, 8'd32, 8'd32, 8'd32};
  endtask

  //--------------------------------------------------------------------------
  // TDT 构造
  //--------------------------------------------------------------------------
  task automatic set_qk(
    input int    id,
    input logic [15:0] heads, ctx, dim,
    input logic [31:0] tail,
    input logic [15:0] dgc, cbc,
    input logic [7:0]  flags
  );
    logic [255:0] d;
    d = '0;
    d[255:252] = 4'hD; d[251:248] = 4'h0; d[175:168] = 8'd32;
    d[247:240] = flags;
    d[239:224] = heads; d[223:208] = ctx; d[207:192] = dim;
    d[159:152] = 8'd1;
    d[111:96]  = dgc;   d[95:80]   = cbc; d[79:48]   = tail;
    tdt_mem[id] = d;
  endtask

  task automatic set_pv(
    input int    id,
    input logic [15:0] heads, ctx, hdim,
    input logic [7:0]  saph, hp,
    input logic [15:0] pgc,
    input logic [5:0]  pli,
    input logic [7:0]  flags
  );
    logic [255:0] d;
    d = '0;
    d[255:252] = 4'hD; d[251:248] = 4'h1; d[175:168] = 8'd32;
    d[247:240] = flags;
    d[239:224] = heads;  d[223:208] = ctx;  d[191:176] = hdim;
    d[167:160] = saph;   d[159:152] = hp;
    d[47:32]   = pgc;    d[31:26]   = pli;
    tdt_mem[id] = d;
  endtask

  //--------------------------------------------------------------------------
  // A 侧驱动原语
  //--------------------------------------------------------------------------
  // 运行 N 拍 MAC, 最后一拍同时 group_done_accept=1
  task automatic run_group(input int n);
    for (int i = 0; i < n; i++) begin
      mac_fire          = 1;
      group_done_accept = (i == n-1) ? 1 : 0;
      @(posedge clk); #1;
    end
    mac_fire = 0; group_done_accept = 0;
  endtask

  // 运行 N 拍 drain
  task automatic run_drain(input int n);
    repeat(n) begin drain_fire=1; @(posedge clk); #1; end
    drain_fire = 0;
  endtask

  // 启动 task: 发 csr_start, 等 task_start_o 有效
  task automatic do_start(input int tid);
    int to;
    to = 0;
    csr_task_id = 4'(tid); csr_start=1; @(posedge clk); #1; csr_start=0;
    while (!task_start_o && to < 20) begin @(posedge clk); #1; to++; end
    if (to >= 20) begin
      $display("[FAIL][%s] timeout waiting task_start (tid=%0d)", cur_tc, tid);
      err_cnt++;
    end
    clk_tick(1); // 额外 1 拍让计数器清零稳定
  endtask

  // 等待 task_done_pulse, 超时报错
  task automatic wait_task_done(input int timeout=5000);
    int to;
    to = 0;
    if (cnt_task_done != 0) return;
    while (cnt_task_done == 0 && to < timeout) begin @(posedge clk); #1; to++; end
    if (to >= timeout) begin
      $display("[FAIL][%s] timeout waiting task_done_pulse", cur_tc); err_cnt++;
    end
  endtask

  //--------------------------------------------------------------------------
  // TC1: QK 基础 — dim=64(dgc=2), ctx=64(cbc=2,全满), heads=1
  //--------------------------------------------------------------------------
  task automatic tc1_qk_basic();
    cur_tc = "TC1_QK_BASIC";
    $display("--- %s ---", cur_tc);
    set_qk(0, 1, 64, 64, 32'hFFFF_FFFF, 2, 2, 8'h01);
    init_pe(0);
    reset_counters();
    do_start(0);

    chk1("mode_qk",  task_mode_o==TASK_MODE_QK, 1'b1);
    chk_i("act_sa",  active_sa_count, 4);

    // 1 head * 2 cbs * 2 groups = 4 groups, 2 row_dones, 1 head_tile_done
    for (int cb=0; cb<2; cb++) begin
      for (int g=0; g<2; g++) begin
        run_group(32);   // fires group_done_pulse on last beat
        clk_tick(1);     // let context/head counters latch
      end
      run_drain(32); clk_tick(2);
    end

    wait_task_done();
    engine_task_done=1; clk_tick(1); engine_task_done=0;
    clk_tick(3);

    chk_i("group_cnt",  cnt_group_done,  4);
    chk_i("row_cnt",    cnt_row_done,    2);
    chk_i("hdone_cnt",  cnt_head_done,   1);
    chk_i("task_done",  cnt_task_done,   1);
    chk_i("drain_tok",  cnt_drain_tok,   2);  // 2 context blocks
    chk1("idle_after",  engine_busy,     1'b0);
    // snap_last_* reflects the LAST group_done — should be last of task
    chk1("last_grp",   snap_last_group,  1'b1);
    chk1("last_ctx",   snap_last_ctx,    1'b1);
    chk1("last_head",  snap_last_head,   1'b1);
    chk32("full_mask", snap_lane_mask, 32'hFFFF_FFFF);
    $display("[PASS] TC1");
  endtask

  //--------------------------------------------------------------------------
  // TC2: QK tail — dim=32(dgc=1), ctx=33(cbc=2, tail=32'h1), heads=1
  //--------------------------------------------------------------------------
  task automatic tc2_qk_tail();
    cur_tc = "TC2_QK_TAIL";
    $display("--- %s ---", cur_tc);
    set_qk(1, 1, 33, 32, 32'h0000_0001, 1, 2, 8'h01);
    init_pe(1);
    reset_counters();
    do_start(1);

    // block 0 (full)
    run_group(32); clk_tick(2);
    // snap_lane_mask should be 全1 here (not yet in last ctx)
    chk32("blk0_mask", snap_lane_mask, 32'hFFFF_FFFF);
    run_drain(32); clk_tick(2);

    // block 1 (tail)
    run_group(32); clk_tick(2);
    chk32("blk1_mask",    snap_lane_mask, 32'h0000_0001);
    chk1("blk1_lctx",    snap_last_ctx,  1'b1);
    chk1("blk1_lhead",   snap_last_head, 1'b1);
    run_drain(32); clk_tick(2);

    wait_task_done();
    engine_task_done=1; clk_tick(1); engine_task_done=0;
    clk_tick(3);

    chk_i("group_cnt", cnt_group_done, 2);
    chk_i("row_cnt",   cnt_row_done,   2);
    chk1("idle",       engine_busy,    1'b0);
    $display("[PASS] TC2");
  endtask

  //--------------------------------------------------------------------------
  // TC3: PV 基础 — head_dim=128(hp=1,saph=4), ctx=64(pgc=2,pli=32), heads=1
  //--------------------------------------------------------------------------
  task automatic tc3_pv_basic();
    cur_tc = "TC3_PV_BASIC";
    $display("--- %s ---", cur_tc);
    set_pv(2, 1, 64, 128, 4, 1, 2, 32, 8'h00);
    init_pe(2);
    reset_counters();
    do_start(2);

    chk1("mode_pv",  task_mode_o==TASK_MODE_PV, 1'b1);

    // 1 head tile, 2 groups of 32
    run_group(32); clk_tick(2);
    chk1("g0_lg0", snap_last_group, 1'b0);
    run_group(32); clk_tick(2);
    chk1("g1_lg1", snap_last_group, 1'b1);

    // PV: head_tile_done fires on last group being accepted
    chk_i("head_done_cnt", cnt_head_done, 1);
    run_drain(32); clk_tick(2);

    wait_task_done();
    engine_task_done=1; clk_tick(1); engine_task_done=0;
    clk_tick(3);

    chk_i("group_cnt", cnt_group_done, 2);
    chk_i("task_done", cnt_task_done,  1);
    chk_i("no_rowdone",cnt_row_done,   0); // PV: no row_done
    chk1("idle",       engine_busy,    1'b0);
    $display("[PASS] TC3");
  endtask

  //--------------------------------------------------------------------------
  // TC4: PV multihead + tail — head_dim=64(hp=2,saph=2), ctx=33(pgc=2,pli=1), heads=2
  //    num_heads=2, hp_parallel=2 → 1 head tile
  //--------------------------------------------------------------------------
  task automatic tc4_pv_tail();
    cur_tc = "TC4_PV_TAIL";
    $display("--- %s ---", cur_tc);
    set_pv(3, 2, 33, 64, 2, 2, 2, 1, 8'h01);
    init_pe(3);
    reset_counters();
    do_start(3);

    // group 0: full 32 inner
    run_group(32); clk_tick(2);
    chk1("g0_not_last", snap_last_group, 1'b0);

    // group 1: only 1 inner (pv_last_inner_count=1 → inner_last at beat 0)
    run_group(1); clk_tick(2);
    chk1("g1_last_grp",  snap_last_group, 1'b1);
    chk1("g1_last_head", snap_last_head,  1'b1);

    // head_tile_done + drain
    chk_i("htd_cnt", cnt_head_done, 1);
    run_drain(32); clk_tick(2);

    wait_task_done();
    engine_task_done=1; clk_tick(1); engine_task_done=0;
    clk_tick(3);

    chk_i("group_cnt", cnt_group_done, 2);
    chk1("idle",       engine_busy,    1'b0);
    $display("[PASS] TC4");
  endtask

  //--------------------------------------------------------------------------
  // TC5: 非法 desc_type → err_set, 不启动
  //--------------------------------------------------------------------------
  task automatic tc5_illegal();
    cur_tc = "TC5_ILLEGAL";
    $display("--- %s ---", cur_tc);
    tdt_mem[4] = '0;  // desc_type = 0 ≠ 0xD
    init_pe(4);
    csr_task_id=4'd4; csr_start=1; @(posedge clk); #1; csr_start=0;
    clk_tick(6);
    chk1("halted",    halted_error, 1'b1);
    chk1("not_busy",  engine_busy,  1'b0);
    chk1("err_code",  error_code==ERR_ILLEGAL_TASK_DESC, 1'b1);
    $display("[PASS] TC5");
  endtask

  //--------------------------------------------------------------------------
  // TC6: QK 多 head — dim=32(dgc=1), ctx=32(cbc=1), heads=4, hp=1
  //    期望: 4 groups, 4 row_dones, 4 head_tile_dones
  //--------------------------------------------------------------------------
  task automatic tc6_qk_multihead();
    cur_tc = "TC6_QK_MHEAD";
    $display("--- %s ---", cur_tc);
    set_qk(5, 4, 32, 32, 32'hFFFF_FFFF, 1, 1, 8'h00);
    init_pe(5);
    reset_counters();
    do_start(5);

    for (int h=0; h<4; h++) begin
      run_group(32); clk_tick(1);
      // head_ctr should equal h at the time of this group
      chk_i($sformatf("head_ctr_h%0d",h), snap_head_tile_id, h);
      run_drain(32); clk_tick(2);
    end

    wait_task_done();
    engine_task_done=1; clk_tick(1); engine_task_done=0;
    clk_tick(3);

    chk_i("group_cnt",  cnt_group_done, 4);
    chk_i("row_cnt",    cnt_row_done,   4);
    chk_i("head_cnt",   cnt_head_done,  4);
    chk_i("task_done",  cnt_task_done,  1);
    chk1("idle",        engine_busy,    1'b0);
    $display("[PASS] TC6");
  endtask

  //--------------------------------------------------------------------------
  // Main
  //--------------------------------------------------------------------------
  initial begin
    foreach(tdt_mem[i]) tdt_mem[i] = '0;
    foreach(pe_mem[i])  pe_mem[i]  = '0;

    @(posedge clk); #1; rst_n=1; clk_tick(3);

    tc1_qk_basic();
    tc2_qk_tail();
    tc3_pv_basic();
    tc4_pv_tail();
    tc5_illegal();
    tc6_qk_multihead();

    clk_tick(5);
    if (err_cnt == 0)
      $display("\n[RESULT] tb_lte_task_ctrl_top: ALL PASS");
    else
      $display("\n[RESULT] tb_lte_task_ctrl_top: FAIL (%0d errors)", err_cnt);
    $finish;
  end

  // 仿真超时保护
  initial begin #2000000; $display("[TIMEOUT]"); $finish; end

endmodule
