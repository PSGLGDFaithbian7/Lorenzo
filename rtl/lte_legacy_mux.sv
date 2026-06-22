//==============================================================================
// lte_legacy_mux.sv   (分工项 B9: Legacy 兼容 Mux)
//==============================================================================
// ★★★ DEPRECATED / 已标注废弃 (2026-06) ★★★
//   项目已全面转向 V0.3 Task Engine, 不再维护 V0.2 microcode 执行路径。
//   本模块暂时保留(便于回溯/未来若要加多执行模式时复用), 但:
//     - 不应在新的顶层集成中实例化;
//     - 默认顶层 lte_task_ctrl_top 直接驱动 datapath, 无模式 mux;
//     - 待确认彻底不需要后可整文件删除。
//==============================================================================
//------------------------------------------------------------------------------
// 功能 (微架构 §12):
//   - 在 Task Engine Mode 与 Legacy Microcode Mode 之间, 选择由谁驱动【共享 datapath】
//     的控制总线。
//       Task   mode: 控制来自 lte_loop_nest_ctrl + lte_boundary_ctrl
//       Legacy mode: 控制来自 V0.2 的 u_loop_ctrl + u_cmd_dispatch
//   - 模式寄存器由 CSR 配置; 非当前模式的一侧被隔离, 不影响 datapath。
//
// 设计要点:
//   - V0.2 legacy RTL 不在本次交付范围内, 因此本模块对"控制总线"做参数化(CTRL_W)的
//     2:1 选择, 由集成时把两侧实际控制信号打包成同宽 bus 接入即可; 同时显式列出几路
//     关键的共享边界事件做命名 mux, 便于联调对线。
//   - mode 切换只允许在 engine idle 时发生 (engine_busy=0), 切换在 idle 拍生效,
//     避免运行中切源造成 datapath 半拍错配。
//==============================================================================

module lte_legacy_mux #(
    // 共享 datapath 控制总线宽度 (集成时按实际打包信号数确定)
    parameter int CTRL_W = 64
) (
    input  logic              clk,
    input  logic              rst_n,

    // ---- 模式配置 (来自 CSR) ----
    input  logic              csr_mode_we,       // 写模式寄存器使能
    input  logic              csr_mode_wdata,    // 0=legacy, 1=task
    input  logic              engine_busy,       // 1 时禁止切换

    // ---- 两个控制源的总线 ----
    input  logic [CTRL_W-1:0] task_ctrl_bus,     // 来自 task engine 控制面
    input  logic [CTRL_W-1:0] legacy_ctrl_bus,   // 来自 V0.2 sequencer

    // ---- 关键共享边界事件 (命名 mux, 便于联调) ----
    input  logic              task_head_tile_start,
    input  logic              task_row_start,
    input  logic              task_group_start,
    input  logic              task_group_done_pulse,
    input  logic              task_row_done_pulse,
    input  logic              task_head_tile_done_pulse,

    input  logic              legacy_head_tile_start,
    input  logic              legacy_row_start,
    input  logic              legacy_group_start,
    input  logic              legacy_group_done_pulse,
    input  logic              legacy_row_done_pulse,
    input  logic              legacy_head_tile_done_pulse,

    // ---- 选择后送往共享 datapath ----
    output logic              task_mode_active,  // 1=task, 0=legacy
    output logic [CTRL_W-1:0] dp_ctrl_bus,

    output logic              dp_head_tile_start,
    output logic              dp_row_start,
    output logic              dp_group_start,
    output logic              dp_group_done_pulse,
    output logic              dp_row_done_pulse,
    output logic              dp_head_tile_done_pulse
);

  //----------------------------------------------------------------------------
  // 模式寄存器: 仅在 idle 时可改, 复位默认 legacy(0) 以兼容 V0.2 bring-up
  //----------------------------------------------------------------------------
  logic mode_q;   // 0=legacy, 1=task
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                  mode_q <= 1'b0;
    else if (csr_mode_we && !engine_busy)        mode_q <= csr_mode_wdata;
  end

  assign task_mode_active = mode_q;

  //----------------------------------------------------------------------------
  // 2:1 控制源选择
  //----------------------------------------------------------------------------
  assign dp_ctrl_bus = mode_q ? task_ctrl_bus : legacy_ctrl_bus;

  assign dp_head_tile_start      = mode_q ? task_head_tile_start      : legacy_head_tile_start;
  assign dp_row_start            = mode_q ? task_row_start            : legacy_row_start;
  assign dp_group_start          = mode_q ? task_group_start          : legacy_group_start;
  assign dp_group_done_pulse     = mode_q ? task_group_done_pulse     : legacy_group_done_pulse;
  assign dp_row_done_pulse       = mode_q ? task_row_done_pulse       : legacy_row_done_pulse;
  assign dp_head_tile_done_pulse = mode_q ? task_head_tile_done_pulse : legacy_head_tile_done_pulse;

endmodule : lte_legacy_mux
