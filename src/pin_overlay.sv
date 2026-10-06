`timescale 1ns/1ps
`default_nettype none

// Map A pin overlay: CPU GPIO merged with the serial engine.
// USB uses bits 0-1; RMII TX uses bits 2-4 (RX on 5-7 is input-only).
module pin_overlay (
    input  wire [7:0] cpu_out,
    input  wire [7:0] cpu_oe,
    input  wire [7:0] eng_out,
    input  wire [7:0] eng_oe,
    output wire [7:0] gpio_out,
    output wire [7:0] gpio_oe
);

assign gpio_out = (cpu_out & ~eng_oe) | (eng_out & eng_oe);
assign gpio_oe  = cpu_oe | eng_oe;

endmodule

`default_nettype wire
