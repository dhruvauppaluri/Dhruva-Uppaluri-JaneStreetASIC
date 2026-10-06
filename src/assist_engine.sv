`timescale 1ns/1ps
`default_nettype none

// Backward-compatible name for serial_engine (legacy unit TB).
module assist_engine #(
    parameter integer FIFO_BYTES = 64,
    parameter [2:0]   PIN_A      = 3'd0,
    parameter [2:0]   PIN_B      = 3'd1
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,
    input  wire       we,
    input  wire [1:0] wr_addr,
    input  wire [7:0] wr_data,
    input  wire [1:0] rd_addr,
    output wire [7:0] rd_data,
    input  wire [7:0] gpio_in,
    output wire [7:0] assist_out,
    output wire [7:0] assist_oe
);

serial_engine #(
    .RAM_BYTES(FIFO_BYTES),
    .PIN_A(PIN_A),
    .PIN_B(PIN_B)
) u_eng (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .we(we),
    .wr_addr(wr_addr),
    .wr_data(wr_data),
    .rd_addr(rd_addr),
    .rd_inc(1'b0),
    .rd_data(rd_data),
    .gpio_in(gpio_in),
    .assist_out(assist_out),
    .assist_oe(assist_oe)
);

endmodule

`default_nettype wire
