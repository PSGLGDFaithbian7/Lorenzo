//==============================================================================
// lte_task_scoreboard.sv   (分工项 B6: 任务记分板)
//------------------------------------------------------------------------------
// 功能 (微架构 §10 / 分工计划 B6):
//   - task 级状态: task_busy / task_done / task_error / task_error_code (各 16 项)
//   - TASK_WAIT 只看 task_done / task_error (done 为 sticky, 由 wait 消费后清)
//   - pipeline 级状态: 把 datapath 上报的 FIFO/bank level 寄存一拍后转给 CSR debug;
//     这些不暴露给微码, 只能 CSR 读。
//
// 设计要点:
//   - busy/done/error 用 per-task bit, 按 id one-hot 更新, 不互相覆盖。
//   - 启动(busy_set) 时清掉该 id 旧的 done/error, 保证一次 TASK_START 后状态干净。
//==============================================================================
import lte_pkg::*;

module lte_task_scoreboard (
    input  logic        clk,
    input  logic        rst_n,

    // ---- 来自 dispatch 的 task 生命周期事件 ----
    //每个任务的开始和结束都会发出信号
    input  logic        task_busy_set,
    input  logic [3:0]  busy_task_id,
    input  logic        task_done_set,
    input  logic [3:0]  done_task_id,

    // ---- 来自 error_ctrl 的错误事件 ----
    //
    input  logic        task_error_set,
    input  logic [3:0]  task_error_id,
    input  logic [7:0]  task_error_code_i,

    // ---- TASK_WAIT 消费 done bit ----
    //非IDLE下进来一个csr_start,在这里记录一下
    input  logic        wait_consume,
    input  logic [3:0]  wait_task_id,

    // ---- datapath 上报的 pipeline level (甲方 -> 乙方 scoreboard) ----
    input  logic [3:0]  partial_acc_bank_free,
    input  logic [1:0]  group_acc_bank_free,
    input  logic [3:0]  deq_fifo_level,
    input  logic [3:0]  deq_token_queue_level,
    input  logic [3:0]  drain_token_queue_level,
    input  logic [3:0]  output_queue_level,
    input  logic [3:0]  stream_credit_q,
    input  logic [3:0]  stream_credit_k,
    input  logic [3:0]  stream_credit_p,
    input  logic [3:0]  stream_credit_v,

    // ---- task 级 bitmap 输出 ----
    //具体到16个task，每一个task的状态
    output logic [15:0] task_busy,
    output logic [15:0] task_done,
    output logic [15:0] task_error,
    output logic [15:0][7:0] task_error_code,

    // ---- pipeline 级 snapshot 输出 (寄存后给 CSR) ----
    output logic [3:0]  sb_partial_acc_bank_free,
    output logic [1:0]  sb_group_acc_bank_free,
    output logic [3:0]  sb_deq_fifo_level,
    output logic [3:0]  sb_deq_token_queue_level,
    output logic [3:0]  sb_drain_token_queue_level,
    output logic [3:0]  sb_output_queue_level,
    output logic [3:0]  sb_stream_credit_q,
    output logic [3:0]  sb_stream_credit_k,
    output logic [3:0]  sb_stream_credit_p,
    output logic [3:0]  sb_stream_credit_v
);

  logic [15:0]      busy_q, done_q, error_q;
  logic [15:0][7:0] err_code_q;

  //----------------------------------------------------------------------------
  // task 级状态机 (per-id bit 更新)
  //----------------------------------------------------------------------------

 //从dispatch来的task id与begin/end，start一个task,把id送到这里面，记录为busy。end同理，中间出现error，那就把置 error + code送到这里
 //中间出现一个插入的task,把wait的状态和Id也在这里更新
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q     <= 16'd0;
      done_q     <= 16'd0;
      error_q    <= 16'd0;
      err_code_q <= '0;
    end else begin
      // 启动: 置 busy, 清该 id 旧 done/error
      if (task_busy_set) begin
        busy_q[busy_task_id]  <= 1'b1;
        done_q[busy_task_id]  <= 1'b0;
        error_q[busy_task_id] <= 1'b0;
      end
      // 完成: 清 busy, 置 sticky done
      if (task_done_set) begin
        busy_q[done_task_id] <= 1'b0;
        done_q[done_task_id] <= 1'b1;
      end
      // 错误: 清 busy, 置 error + code
      if (task_error_set) begin
        busy_q[task_error_id]     <= 1'b0;
        error_q[task_error_id]    <= 1'b1;
        err_code_q[task_error_id] <= task_error_code_i;
      end
      // TASK_WAIT 消费 done
      if (wait_consume) begin
        done_q[wait_task_id] <= 1'b0;
      end
    end
  end

  assign task_busy       = busy_q;
  assign task_done       = done_q;
  assign task_error      = error_q;
  assign task_error_code = err_code_q;

  //----------------------------------------------------------------------------
  // pipeline level: 单纯寄存一拍 (去毛刺 + 时序隔离), 转给 CSR debug
  //----------------------------------------------------------------------------
  //datapath上报的错误，打一拍转交给CSR，这里不处理
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sb_partial_acc_bank_free   <= '0;
      sb_group_acc_bank_free     <= '0;
      sb_deq_fifo_level          <= '0;
      sb_deq_token_queue_level   <= '0;
      sb_drain_token_queue_level <= '0;
      sb_output_queue_level      <= '0;
      sb_stream_credit_q         <= '0;
      sb_stream_credit_k         <= '0;
      sb_stream_credit_p         <= '0;
      sb_stream_credit_v         <= '0;
    end else begin
      sb_partial_acc_bank_free   <= partial_acc_bank_free;
      sb_group_acc_bank_free     <= group_acc_bank_free;
      sb_deq_fifo_level          <= deq_fifo_level;
      sb_deq_token_queue_level   <= deq_token_queue_level;
      sb_drain_token_queue_level <= drain_token_queue_level;
      sb_output_queue_level      <= output_queue_level;
      sb_stream_credit_q         <= stream_credit_q;
      sb_stream_credit_k         <= stream_credit_k;
      sb_stream_credit_p         <= stream_credit_p;
      sb_stream_credit_v         <= stream_credit_v;
    end
  end

endmodule : lte_task_scoreboard
