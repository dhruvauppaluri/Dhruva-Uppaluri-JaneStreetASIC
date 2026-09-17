`timescale 1ns/1ps

// Combinational instruction ROM for the initial SET/WAIT/HALT test program.
// Each 16-bit instruction contains a 2-bit opcode and 14-bit immediate.
module protocol_program_rom (
    input  wire [3:0]  address,
    output reg  [15:0] instruction
);

localparam [1:0] OP_SET  = 2'b00;
localparam [1:0] OP_WAIT = 2'b01;
localparam [1:0] OP_HALT = 2'b10;

always @(*)
begin
    case (address)
        4'd0: instruction = {OP_SET,  14'd1};
        4'd1: instruction = {OP_WAIT, 14'd3};
        4'd2: instruction = {OP_SET,  14'd0};
        4'd3: instruction = {OP_WAIT, 14'd2};
        4'd4: instruction = {OP_SET,  14'd1};

        // Exercise safe handling of a zero-cycle wait.
        4'd5: instruction = {OP_WAIT, 14'd0};

        4'd6: instruction = {OP_SET,  14'd0};
        4'd7: instruction = {OP_HALT, 14'd0};

        // Stop safely if execution reaches an unused address.
        default: instruction = {OP_HALT, 14'd0};
    endcase
end

endmodule
