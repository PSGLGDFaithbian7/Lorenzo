//==============================================================================
// lte_error_ctrl.sv   (分工项 B8: 错误控制器)
//------------------------------------------------------------------------------
// 功能 (ISA §9 / RTL Design Spec §5.19):
//   - 汇总配置错误(dispatch/decode)与运行错误(backpressure debug 等)
//   - 锁存 sticky 的 halted_error + 最近 error_code 供 CSR 读取
//   - 配置错误时不启动 datapath (启动判定在 dispatch, 这里只负责落 sticky 状态)
//   - 把 per-task 错误事件转发给 scoreboard
//
// 设计要点:
//   - sticky 状态由 csr_err_clear 显式清除 (写 1 清), 与 V0.2 行为一致, 不做自动恢复。
//   - 多个错误同拍时, 以输入优先级编码后的 err_code 为准 (优先级在 dispatch 已定)。
//==============================================================================
import lte_pkg::*;

module lte_error_ctrl (
    input  logic       clk,
    input  logic       rst_n,

    // ---- 配置/启动错误 (来自 dispatch) ----
    input  logic       err_set,
    input  logic [7:0] err_code,
    input  logic [3:0] err_task_id,

    // ---- 运行期 backpressure debug 错误 (可选, 来自 scoreboard 阈值) ----
    input  logic       bp_err_set,
    input  logic [3:0] bp_err_task_id,

    // ---- CSR 清除 ----
    input  logic       csr_err_clear,

    // ---- sticky 状态输出 (给 CSR) ----
    output logic       halted_error,
    output logic [7:0] error_code,

    // ---- 转发给 scoreboard 的 per-task 错误置位 ----
    output logic       task_error_set,
    output logic [3:0] task_error_id,
    output logic [7:0] task_error_code
);

  logic       halted_q;
  logic [7:0] code_q;

  // 合并: 配置错误优先于 backpressure debug
  logic       any_err;
  logic [7:0] any_code;
  logic [3:0] any_id;
  assign any_err  = err_set | bp_err_set;
  assign any_code = err_set ? err_code           : ERR_TASK_BACKPRESSURE_DEBUG;
  assign any_id   = err_set ? err_task_id         : bp_err_task_id;

  //收到错误，锁存
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halted_q <= 1'b0;
      code_q   <= ERR_NONE;
    end else if (csr_err_clear) begin
      halted_q <= 1'b0;
      code_q   <= ERR_NONE;
    end else if (any_err) begin
      halted_q <= 1'b1;
      code_q   <= any_code;     // 最近一次错误码
    end
  end

  assign halted_error    = halted_q;
  assign error_code      = code_q;

  // per-task 错误事件转发 (scoreboard 负责落 bitmap 与 per-task code)
  //同步把错误发生信号，id,code发给scoreboard
  assign task_error_set  = any_err;
  assign task_error_id   = any_id;
  assign task_error_code = any_code;

endmodule : lte_error_ctrl
