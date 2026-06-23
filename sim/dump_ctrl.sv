// dump_ctrl.sv - waveform dump top for VCS/Verdi.
`timescale 1ns/1ps

module dump_ctrl;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("sim.fsdb");
`ifdef TB_TOP
    $fsdbDumpvars(0, `TB_TOP);
`else
    $fsdbDumpvars(0);
`endif
    $fsdbDumpSVA;
`endif
`ifdef VCD
    $dumpfile("sim.vcd");
    $dumpvars(0);
`endif
  end
endmodule
