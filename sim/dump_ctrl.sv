// dump_ctrl.sv — 独立的波形 dump 顶层模块
// 作为第二个仿真顶 (VCS 支持多个 top) 注入, 不修改任何 TB 文件
// 通过 Makefile 传入 +define+FSDB 来启用 FSDB dump
`timescale 1ns/1ps
module dump_ctrl;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("sim.fsdb");
    $fsdbDumpvars(0, "");
    $fsdbDumpSVA;          // 同时 dump assertion
`endif
`ifdef VCD
    $dumpfile("sim.vcd");
    $dumpvars(0);
`endif
  end
endmodule
