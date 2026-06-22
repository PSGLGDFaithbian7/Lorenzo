//==============================================================================
// lte_csr.sv   (分工项 B7: CSR 扩展 + debug snapshot)
//------------------------------------------------------------------------------
// 功能 (微架构 §11 / ISA §2.4):
//   - 暴露 task busy/done/error/error_code 给 host
//   - TASK_STATUS_SNAPSHOT (snapshot_req) 把 loop_nest 计数器快照到 CSR
//   - 暴露 pipeline FIFO/bank level 给 debug 读
//   - 写 ERROR_CODE 寄存器产生 err_clear 脉冲清 sticky 错误
//
// 设计要点:
//   - 简单同步寄存器堆: 单读口(组合读)+单写口(同步写)。总线协议由 SoC 适配,
//     本模块只约定地址映射与读写语义。
//   - 计数器快照寄存器仅在 snapshot_req 当拍更新, 保证读到一致的一组计数值。
//==============================================================================
import lte_pkg::*;

module lte_csr (
    input  logic        clk,
    input  logic        rst_n,
    //外界输入的控制信号和数据，表征软件层希望如何控制CSR/从CSR读取什么信息
    // ---- 简化寄存器总线 ---- 
    input  logic [7:0]  csr_addr,
    input  logic        csr_wr,
    input  logic [31:0] csr_wdata,
    input  logic        csr_rd,
    output logic [31:0] csr_rdata,

    // ---- 快照触发 (TASK_STATUS_SNAPSHOT) ----
    //调试用，用于锁存某些时刻的信息
    input  logic        snapshot_req,
    //从各个模块来的信息，用于控制
    // ---- 来自 loop_nest 的实时计数器 ----

    input  logic [HEAD_W-1:0]    head_ctr,
    input  logic [QK_CTX_W-1:0]  context_ctr,
    input  logic [GROUP_CTR_W-1:0] group_ctr,
    input  logic [INNER_W-1:0]   inner_ctr,
    input  logic [DRAIN_W-1:0]   drain_lane_ctr,

    // ---- 来自 dispatch / error_ctrl 的全局状态 ----
    //engine_busy：正在运转灯。绿灯亮，说明车间里有任务在跑。
    //halted_done：正常完工灯。蓝灯亮，说明任务全干完了，机器自己停了。
    //halted_error：故障停机灯。红灯亮，说明出大毛病了，机器被迫卡死停工了。
    //global_error_code：故障代码。如果红灯亮了，这 8 根线上的数字就代表具体是哪种故障（比如代码 01 代表传送带卡死，02 代表缺纸）。
    input  logic        engine_busy,
    input  logic        halted_done,
    input  logic        halted_error,
    input  logic [7:0]  global_error_code,

    // ---- 来自 scoreboard 的 task 级 bitmap ----
    /*
      task_busy[15:0]：忙碌灯阵列。第 0 根线亮，代表 0 号任务正在跑；第 5 根线亮，代表 5 号任务在跑。
      task_done[15:0]：完工灯阵列。哪个任务干完了，对应的灯就亮。
      task_error[15:0]：报错灯阵列。哪个任务出错了，对应的灯就亮。
      task_error_code[15:0][7:0]：详细错误码。16 条线，每条线都有 8 位错误码。配合刚才讲的“旋钮（errcode_sel_q）”，经理想看哪条线的错误码，就选哪条线。
    */
    input  logic [15:0] task_busy,
    input  logic [15:0] task_done,
    input  logic [15:0] task_error,
    input  logic [15:0][7:0] task_error_code,

    // ---- 来自 scoreboard 的 pipeline level ----
    input  logic [3:0]  sb_partial_acc_bank_free,
    input  logic [1:0]  sb_group_acc_bank_free,
    input  logic [3:0]  sb_deq_fifo_level,
    input  logic [3:0]  sb_deq_token_queue_level,
    input  logic [3:0]  sb_drain_token_queue_level,
    input  logic [3:0]  sb_output_queue_level,
    input  logic [3:0]  sb_stream_credit_q,
    input  logic [3:0]  sb_stream_credit_k,
    input  logic [3:0]  sb_stream_credit_p,
    input  logic [3:0]  sb_stream_credit_v,

    // ---- 输出 ----
    output logic        csr_err_clear     // 写 ERROR_CODE -> 清 sticky 错误
);

  //----------------------------------------------------------------------------
  // 地址映射 (8-bit addr, 32-bit word)
  //----------------------------------------------------------------------------
  //地址变量，输入这里面的地址，返回想要的值
  localparam logic [7:0] A_STATUS       = 8'h00; // [0]busy [1]done [2]error
  localparam logic [7:0] A_ERROR_CODE   = 8'h01; // [7:0] 全局 error_code; 写=清错
  localparam logic [7:0] A_TASK_BUSY    = 8'h02;
  localparam logic [7:0] A_TASK_DONE    = 8'h03;
  localparam logic [7:0] A_TASK_ERROR   = 8'h04;
  localparam logic [7:0] A_ERRCODE_SEL  = 8'h05; // 写 task id 选择
  localparam logic [7:0] A_ERRCODE_VAL  = 8'h06; // 读选中 task 的 error_code
  localparam logic [7:0] A_SNAP_HEAD    = 8'h10;
  localparam logic [7:0] A_SNAP_CONTEXT = 8'h11;
  localparam logic [7:0] A_SNAP_GROUP   = 8'h12;
  localparam logic [7:0] A_SNAP_INNER   = 8'h13;
  localparam logic [7:0] A_SNAP_DRAIN   = 8'h14;
  localparam logic [7:0] A_LVL_STREAM   = 8'h20; // {q,k,p,v} 各 4 bit
  localparam logic [7:0] A_LVL_QUEUE    = 8'h21; // {deq_fifo,deq_tok,drain_tok,out_q}
  localparam logic [7:0] A_LVL_BANK     = 8'h22; // {partial_free[3:0],group_free[1:0]}

  //----------------------------------------------------------------------------
  // 计数器快照寄存器 (snapshot_req 当拍锁存)
  //----------------------------------------------------------------------------
  logic [HEAD_W-1:0]     snap_head_q;
  logic [QK_CTX_W-1:0]   snap_context_q;
  logic [GROUP_CTR_W-1:0] snap_group_q;
  logic [INNER_W-1:0]    snap_inner_q;
  logic [DRAIN_W-1:0]    snap_drain_q;
  //snapshot_req拉高，把那一拍的信息全部存入寄存器里面，方便后续查询

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      snap_head_q    <= '0;
      snap_context_q <= '0;
      snap_group_q   <= '0;
      snap_inner_q   <= '0;
      snap_drain_q   <= '0;
    end else if (snapshot_req) begin
      snap_head_q    <= head_ctr;
      snap_context_q <= context_ctr;
      snap_group_q   <= group_ctr;
      snap_inner_q   <= inner_ctr;
      snap_drain_q   <= drain_lane_ctr;
    end
  end

  //----------------------------------------------------------------------------
  // 错误码读选择寄存器
  //----------------------------------------------------------------------------
  //通过csr_addr == A_ERRCODE_SEL，来选择看wdata里面自定的地址里的数据
  //后续再驱动一次rdata，结合上一次选择的地址去选择数据
  logic [3:0] errcode_sel_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                          errcode_sel_q <= 4'd0;
    else if (csr_wr && (csr_addr == A_ERRCODE_SEL))      errcode_sel_q <= csr_wdata[3:0];
  end

  //----------------------------------------------------------------------------
  // 写: 仅 ERROR_CODE 地址产生 err_clear 脉冲 (写 1 清错语义)
  //----------------------------------------------------------------------------
  assign csr_err_clear = csr_wr && (csr_addr == A_ERROR_CODE);
  //清除警报，在csr_addr里面写 == A_ERROR_CODE
  //----------------------------------------------------------------------------
  // 读: 组合多路选择
  //----------------------------------------------------------------------------
  //根据输入的读地址编号，选取host想要看的数据
  always_comb begin
    csr_rdata = 32'd0;
    unique case (csr_addr)
      A_STATUS:       csr_rdata = {29'd0, halted_error, halted_done, engine_busy};
      A_ERROR_CODE:   csr_rdata = {24'd0, global_error_code};
      A_TASK_BUSY:    csr_rdata = {16'd0, task_busy};
      A_TASK_DONE:    csr_rdata = {16'd0, task_done};
      A_TASK_ERROR:   csr_rdata = {16'd0, task_error};
      A_ERRCODE_SEL:  csr_rdata = {28'd0, errcode_sel_q};
      A_ERRCODE_VAL:  csr_rdata = {24'd0, task_error_code[errcode_sel_q]};
      A_SNAP_HEAD:    csr_rdata = 32'(snap_head_q);
      A_SNAP_CONTEXT: csr_rdata = 32'(snap_context_q);
      A_SNAP_GROUP:   csr_rdata = 32'(snap_group_q);
      A_SNAP_INNER:   csr_rdata = 32'(snap_inner_q);
      A_SNAP_DRAIN:   csr_rdata = 32'(snap_drain_q);
      A_LVL_STREAM:   csr_rdata = {16'd0, sb_stream_credit_q, sb_stream_credit_k,
                                          sb_stream_credit_p, sb_stream_credit_v};
      A_LVL_QUEUE:    csr_rdata = {16'd0, sb_deq_fifo_level, sb_deq_token_queue_level,
                                          sb_drain_token_queue_level, sb_output_queue_level};
      A_LVL_BANK:     csr_rdata = {26'd0, sb_partial_acc_bank_free, sb_group_acc_bank_free};
      default:        csr_rdata = 32'd0;
    endcase
  end

endmodule : lte_csr
