`timescale 1ns/1ps
`default_nettype none

// Inferrable PROGRAM_WORDS x 16 instruction memory.
//
// Tiny Tapeout's IHP 130 nm CMOS5L / sg13g2 shuttles ship compiled SRAM
// macros (see the Tiny Tapeout SRAM examples, e.g. wrappers around
// RM_IHPSG13_1P_* 256x16-class blocks). This repository does not vendor a
// PDK cell: instantiating a fake macro name would break iverilog, Verilator,
// and Yosys simulation.
//
// Clocked write + combinational read keeps the protocol ISA single-cycle
// fetch, so WAIT timing and the existing UART/SPI/I2C firmware TBs stay
// valid. Yosys still maps the array to $mem / flip-flops in this shuttle
// RTL (no PDK macro is vendored). For GDS, wrap
// RM_IHPSG13_1P_256x16_c2_bm_bist (or the CMOS5L equivalent) with the same
// ports; a synchronous-read macro would also need a fetch register and a
// stall policy, which this design deliberately avoids so WAIT N stays N+2.
module instruction_sram #(
    parameter integer DEPTH      = 256,
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
) (
    input  wire                     clk,
    input  wire                     we,
    input  wire [ADDR_WIDTH-1:0]    waddr,
    input  wire [DATA_WIDTH-1:0]    wdata,
    input  wire [ADDR_WIDTH-1:0]    raddr,
    output wire [DATA_WIDTH-1:0]    rdata
);

(* ram_style = "block" *)
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

always @(posedge clk) begin
    if (we)
        mem[waddr] <= wdata;
end

assign rdata = mem[raddr];

endmodule

`default_nettype wire
