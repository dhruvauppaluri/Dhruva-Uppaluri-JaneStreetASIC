`timescale 1ns/1ps

module program_counter_tb;

reg clk;
reg reset;
reg advance;
wire [3:0] address;

integer errors;
integer expected;

program_counter dut (
    .clk(clk),
    .reset(reset),
    .advance(advance),
    .address(address)
);

// 10 ns clock period = 100 MHz.
always #5 clk = ~clk;

task check_address;
    input [3:0] expected_address;
    begin
        if (address !== expected_address)
        begin
            $display(
                "ERROR at %0t: expected address=%0d, observed address=%0d",
                $time,
                expected_address,
                address
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

    // Reset is synchronous, so check the address after a rising edge.
    @(posedge clk);
    #1;
    check_address(4'd0);

    @(negedge clk);
    reset = 1'b0;
    advance = 1'b1;

    // Verify three consecutive increments: 0 -> 1 -> 2 -> 3.
    @(posedge clk); #1; check_address(4'd1);
    @(posedge clk); #1; check_address(4'd2);
    @(posedge clk); #1; check_address(4'd3);

    // The counter must hold while advance is low.
    @(negedge clk);
    advance = 1'b0;

    repeat (3)
    begin
        @(posedge clk);
        #1;
        check_address(4'd3);
    end

    // Counting resumes from the held address.
    @(negedge clk);
    advance = 1'b1;

    @(posedge clk);
    #1;
    check_address(4'd4);

    // Verify normal four-bit wraparound from 15 to 0.
    for (expected = 5; expected <= 15; expected = expected + 1)
    begin
        @(posedge clk);
        #1;
        check_address(expected[3:0]);
    end

    @(posedge clk);
    #1;
    check_address(4'd0);

    // Synchronous reset takes priority over advance.
    @(negedge clk);
    reset = 1'b1;
    advance = 1'b1;

    @(posedge clk);
    #1;
    check_address(4'd0);

    if (errors == 0)
        $display("PASS: program counter reset, advance, hold, resume, and wrap verified");
    else
        $display("FAIL: errors=%0d", errors);

    $finish;
end

initial
begin
    #500;
    $display("FAIL: program counter testbench timeout");
    $finish;
end

endmodule
