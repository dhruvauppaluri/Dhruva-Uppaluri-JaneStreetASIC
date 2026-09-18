`timescale 1ns/1ps

module integration_fetch_tb;

reg clk;
reg reset;
reg advance;

wire [3:0]  address;
wire [15:0] instruction;

integer errors;

integration_fetch dut (
    .clk(clk),
    .reset(reset),
    .advance(advance),
    .address(address),
    .instruction(instruction)
);

// 10 ns clock period = 100 MHz.
always #5 clk = ~clk;

task check_fetch;
    input [3:0]  expected_address;
    input [15:0] expected_instruction;
    begin
        if (address !== expected_address ||
            instruction !== expected_instruction)
        begin
            $display(
                "ERROR at %0t: expected address=%0d instruction=0x%04h, observed address=%0d instruction=0x%04h",
                $time,
                expected_address,
                expected_instruction,
                address,
                instruction
            );
            errors = errors + 1;
        end
    end
endtask

initial
begin
    clk = 1'b0;
    reset = 1'b1;
    advance = 1'b0;
    errors = 0;

    // The synchronous reset selects the first instruction.
    @(posedge clk);
    #1;
    check_fetch(4'd0, 16'h0001); // SET 1

    // Walk through the complete program one instruction per clock.
    @(negedge clk);
    reset = 1'b0;
    advance = 1'b1;

    @(posedge clk); #1; check_fetch(4'd1, 16'h4003); // WAIT 3
    @(posedge clk); #1; check_fetch(4'd2, 16'h0000); // SET 0
    @(posedge clk); #1; check_fetch(4'd3, 16'h4002); // WAIT 2
    @(posedge clk); #1; check_fetch(4'd4, 16'h0001); // SET 1
    @(posedge clk); #1; check_fetch(4'd5, 16'h4000); // WAIT 0
    @(posedge clk); #1; check_fetch(4'd6, 16'h0000); // SET 0
    @(posedge clk); #1; check_fetch(4'd7, 16'h8000); // HALT

    // Holding the PC also holds the selected instruction.
    @(negedge clk);
    advance = 1'b0;

    repeat (3)
    begin
        @(posedge clk);
        #1;
        check_fetch(4'd7, 16'h8000);
    end

    // An unused address returns the ROM's safe HALT default.
    @(negedge clk);
    advance = 1'b1;

    @(posedge clk);
    #1;
    check_fetch(4'd8, 16'h8000);

    // Reset returns the fetch path to the first program entry.
    @(negedge clk);
    reset = 1'b1;

    @(posedge clk);
    #1;
    check_fetch(4'd0, 16'h0001);

    if (errors == 0)
        $display("PASS: program counter and instruction ROM integration verified");
    else
        $display("FAIL: errors=%0d", errors);

    $finish;
end

initial
begin
    #300;
    $display("FAIL: instruction fetch testbench timeout");
    $finish;
end

endmodule
