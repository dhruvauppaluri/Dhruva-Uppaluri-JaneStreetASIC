`timescale 1ns/1ps

// Connects the program counter to the combinational instruction ROM.
module integration_fetch (
    input  wire        clk,
    input  wire        reset,
    input  wire        advance,
    output wire [3:0]  address,
    output wire [15:0] instruction
);

program_counter pc (
    .clk(clk),
    .reset(reset),
    .advance(advance),
    .address(address)
);

protocol_program_rom rom (
    .address(address),
    .instruction(instruction)
);

endmodule
