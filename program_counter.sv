`timescale 1ns/1ps

// Four-bit program counter with synchronous reset and clock-enable control.
module program_counter (
    input  wire       clk,
    input  wire       reset,
    input  wire       advance,
    output reg  [3:0] address
);

always @(posedge clk)
begin
    if (reset)
    begin
        address <= 4'd0;
    end
    else if (advance)
    begin
        address <= address + 4'd1;
    end
end

endmodule
