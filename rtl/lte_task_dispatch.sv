//==============================================================================
// lte_task_dispatch.sv   (分工项 B1: 任务派发器)
//------------------------------------------------------------------------------
// 功能 (ISA §2.1/§2.2 / RTL Design Spec §5.1):
//   - 接收 csr_start + csr_task_id (对应微码 TASK_START)
//   - 检查 task engine 是否 busy; busy 时按 wait_on_launch 决定 stall 或报错
//   - 驱动 tdt_raddr 取出 TDT entry, 等解码合法性结果
//   - 合法 -> 发 task_launch(锁存 ctx) 与 task_start(启动 loop_nest) 脉冲
//   - 非法 / busy -> 发 err_set 脉冲带错误码
//   - 跟踪 task_done, 维护 engine_busy
//
// 设计要点:
//   - 单 task 串行执行 (设计不支持多 task 并发)。
//   - task_launch / task_start 都是 1 拍脉冲; 先 launch 锁存上下文, 次拍 start 让
//     loop_nest 在配置稳定后再清零起跑。
//   - TDT 视为同步读 RAM, 读延迟 1 拍 (IDLE 给地址, FETCH 拿数据)。
//==============================================================================
import lte_pkg::*;

module lte_task_dispatch (
    input  logic         clk,
    input  logic         rst_n,

    // ---- CSR / 微码侧请求 ----
    //task启动+id指定+busy时挂起等待
    input  logic         csr_start,          // TASK_START 脉冲
    input  logic [3:0]   csr_task_id,        // TDT index 0..15
    input  logic         csr_wait_on_launch, // flags[0]: busy 时是否 stall 等待

    // ---- TDT RAM 读口 ----
    //通过task id去取本轮task的配置信息
    output logic [3:0]   tdt_raddr,
    input  logic [255:0] tdt_rdata,          // (本模块不用内容, 只驱动地址/时序)

    // ---- 来自 lte_tdt_decode 的合法性结果 (组合, 跟随 tdt_rdata) ----
    //tdt_data->decode->legal/error_code
    input  logic         cfg_legal,
    input  logic [7:0]   cfg_error_code,

    // ---- 来自 engine/top 的完成信号 (已计入 drain 排空) ----
    input  logic         engine_task_done,

    // ---- 启动握手输出 ----
    //launch:tdt_data->context模块
    output logic         task_launch,        // 锁存 TDT/PE desc 到 task_context (1 拍)
    output logic         task_start,          // 启动 loop_nest / boundary (1 拍)
    output logic [3:0]   task_id_o,           // 当前/将启动的 task id

    // ---- 状态 ----
    output logic         engine_busy,         // 1=有 task 在跑或正在启动

    // ---- 给 scoreboard 的事件脉冲 ----
    output logic         task_busy_set,       // 启动时置 busy[id]
    output logic         task_done_set,       // 完成时置 done[id]
    output logic [3:0]   done_task_id,

    // ---- 给 error_ctrl / scoreboard 的错误脉冲 ----
    output logic         err_set,
    output logic [7:0]   err_code,
    output logic [3:0]   err_task_id
);
  //dispatch 的状态机分类
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_FETCH  = 3'd1,   // TDT 读数据有效, 做合法性裁决
    S_LAUNCH = 3'd2,   // 发 task_launch
    S_START  = 3'd3,   // 发 task_start
    S_RUN    = 3'd4,   // 等 engine_task_done
    S_ERROR  = 3'd5    // 发 err_set 一拍后回 IDLE
  } state_e;

  state_e      state_q, state_d;
  logic [3:0]  task_id_q;          // 锁存当前处理的 task id
  logic [7:0]  err_code_q;         //当前的error_code

  // wait_on_launch 的挂起请求 (busy 时到来, 等 IDLE 再处理) 锁存task busy的时候来的任务请求
  logic        pend_valid_q;
  logic [3:0]  pend_id_q;

  //----------------------------------------------------------------------------
  // 次态
  //----------------------------------------------------------------------------

  always_comb begin
    state_d = state_q;
    unique case (state_q)
    //有之前积压的task请求或者新的task申请
      S_IDLE:   if (csr_start || pend_valid_q) state_d = S_FETCH;
      //取TDT，decode判定有没有错误的码值
      S_FETCH:  state_d = cfg_legal ? S_LAUNCH : S_ERROR;
      //LAUNCH：锁存CONTEXT
      S_LAUNCH: state_d = S_START;
      //S_LAUNCH（发 task_launch 脉冲）：这一拍，通知 B2（上下文锁存模块）把 TDT 的配置存进寄存器。这就好比把图纸上的参数输入到机器的仪表盘上。此时机器还没转，参数刚刚落位。
      //S_START（发 task_start 脉冲）：次拍，通知 B3（循环控制器）开始运转。因为上一拍参数已经稳定锁存了，这时开机，机器读取到的配置绝对是稳定的，不会出现“一边开机一边改参数”的致命竞态。
      //开始工作
      S_START:  state_d = S_RUN;
      //运行中，运行完成后回到IDLE态
      S_RUN:    if (engine_task_done) state_d = S_IDLE;
      //错误态
      S_ERROR:  state_d = S_IDLE;
      default:  state_d = S_IDLE;
    endcase
  end

  //----------------------------------------------------------------------------
  // task_id 锁存 + 挂起请求管理
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q      <= S_IDLE;
      task_id_q    <= 4'd0;
      err_code_q   <= ERR_NONE;
      pend_valid_q <= 1'b0;
      pend_id_q    <= 4'd0;
    end else begin
      state_q <= state_d;

      // IDLE: 接受新请求或消费挂起请求, 锁存 id
      if (state_q == S_IDLE) begin
        if (csr_start) begin
          task_id_q <= csr_task_id;
          //如果之前有已经挂起的请求，暂时有没有新来的start，那就先消费这个请求。
        end else if (pend_valid_q) begin
          task_id_q    <= pend_id_q;
          pend_valid_q <= 1'b0;        // 挂起请求被消费
        end
      end

      // 锁存合法性裁决结果 (FETCH 拍)
      // FETCH拍取TDT+decode
      if (state_q == S_FETCH && !cfg_legal) begin
        err_code_q <= cfg_error_code;
      end

      // busy 期间收到新的 csr_start
      if (state_q != S_IDLE && csr_start) begin
        //启用挂起功能
        if (csr_wait_on_launch) begin
          // 记挂起, 等当前 task 结束再启动 (后到的覆盖, 单深度)
          //这个记事贴只有一张（单深度）。如果忙的时候连来两个等待请求，后一个会覆盖前一个。
          pend_valid_q <= 1'b1;
          pend_id_q    <= csr_task_id;
        end
        // 非 wait_on_launch 的 busy 拒绝 -> err 在输出段产生 (见 err_set)
      end
    end
  end

  //----------------------------------------------------------------------------
  // 输出 (脉冲)
  //----------------------------------------------------------------------------
 //给tdt的读地址
  assign tdt_raddr   = (state_q == S_IDLE) ?
                       (csr_start ? csr_task_id : pend_id_q) : task_id_q;
 //对外的task_id展示                     
  assign task_id_o   = task_id_q;
//对外的busy信号
  assign engine_busy = (state_q != S_IDLE);
 //task_launch的时候给context_latch脉冲 
 //task_start时给nest_loop脉冲
  assign task_launch = (state_q == S_LAUNCH);
  assign task_start  = (state_q == S_START);
  //给scoreboard的task开始/结束/id
  assign task_busy_set = (state_q == S_LAUNCH);
  assign task_done_set = (state_q == S_RUN) && engine_task_done;
  assign done_task_id  = task_id_q;

  // 错误脉冲: 1) 配置非法 (S_FETCH -> S_ERROR) ; 2) busy 且非 wait_on_launch 拒绝
  logic cfg_err_pulse;
  logic busy_reject_pulse;
  assign cfg_err_pulse     = (state_q == S_FETCH) && !cfg_legal;
  assign busy_reject_pulse = (state_q != S_IDLE) && csr_start && !csr_wait_on_launch;

  assign err_set     = cfg_err_pulse | busy_reject_pulse;
  assign err_code    = cfg_err_pulse ? cfg_error_code : ERR_TASK_ENGINE_BUSY;
  assign err_task_id = busy_reject_pulse ? csr_task_id : task_id_q;

endmodule : lte_task_dispatch
