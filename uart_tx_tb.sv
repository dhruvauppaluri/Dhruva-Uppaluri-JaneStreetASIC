`timescale 1ns/1ps

module uart_tx_tb;

localparam CLKS_PER_BIT = 100;
localparam BIT_TIME_NS  = CLKS_PER_BIT * 10;

reg clk;
reg reset;
reg start;
reg [7:0] data;
wire tx;
wire busy;
wire done;

integer errors;
integer frames_checked;

uart_tx #(
    .CLKS_PER_BIT(CLKS_PER_BIT)
) dut (
    .clk(clk),
    .reset(reset),
    .start(start),
    .data(data),
    .tx(tx),
    .busy(busy),
    .done(done)
);

// 10 ns period = 100 MHz.
always #5 clk = ~clk;

task send_and_check;
    input [7:0] expected_data;
    integer bit_number;
    begin
        $display("Testing UART byte 0x%02h", expected_data);

        // Present the byte and pulse start for one complete clock cycle.
        @(negedge clk);
        data = expected_data;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Change the input after start to prove that the DUT latched it.
        data = ~expected_data;

        // Wait for the falling edge that begins the UART start bit,
        // then sample each bit in the middle of its bit period.
        wait (tx == 1'b0);
        #(BIT_TIME_NS / 2);

        if (tx !== 1'b0)
        begin
            $display("ERROR: start bit was not low");
            errors = errors + 1;
        end

        if (busy !== 1'b1)
        begin
            $display("ERROR: busy was not high during the start bit");
            errors = errors + 1;
        end

        // UART sends the least-significant data bit first.
        for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1)
        begin
            #BIT_TIME_NS;

            if (tx !== expected_data[bit_number])
            begin
                $display(
                    "ERROR: data bit %0d expected %b, observed %b",
                    bit_number,
                    expected_data[bit_number],
                    tx
                );
                errors = errors + 1;
            end

            if (busy !== 1'b1)
            begin
                $display("ERROR: busy fell during data bit %0d", bit_number);
                errors = errors + 1;
            end
        end

        #BIT_TIME_NS;

        if (tx !== 1'b1)
        begin
            $display("ERROR: stop bit was not high");
            errors = errors + 1;
        end

        if (busy !== 1'b1)
        begin
            $display("ERROR: busy fell before the stop bit completed");
            errors = errors + 1;
        end

        wait (done == 1'b1);

        if (busy !== 1'b0)
        begin
            $display("ERROR: busy was high when done asserted");
            errors = errors + 1;
        end

        if (tx !== 1'b1)
        begin
            $display("ERROR: tx was not idle-high after the frame");
            errors = errors + 1;
        end

        // done must be a one-clock pulse.
        @(posedge clk);
        #1;
        if (done !== 1'b0)
        begin
            $display("ERROR: done remained high for more than one clock");
            errors = errors + 1;
        end

        frames_checked = frames_checked + 1;
    end
endtask

initial
begin
    clk = 1'b0;
    reset = 1'b1;
    start = 1'b0;
    data = 8'd0;
    errors = 0;
    frames_checked = 0;

    // Release synchronous reset away from a clock edge.
    #22;
    reset = 1'b0;

    @(negedge clk);
    if (tx !== 1'b1 || busy !== 1'b0 || done !== 1'b0)
    begin
        $display("ERROR: UART did not enter its idle state after reset");
        errors = errors + 1;
    end

    send_and_check(8'h55);
    send_and_check(8'hA3);

    if (errors == 0 && frames_checked == 2)
        $display("PASS: UART transmitted 0x55 and 0xA3 correctly");
    else
        $display(
            "FAIL: errors=%0d frames_checked=%0d",
            errors,
            frames_checked
        );

    $finish;
end

initial
begin
    // Two 10-bit frames take about 20 us at 1 Mbit/s.
    #30000;
    $display("FAIL: UART testbench timeout");
    $finish;
end

endmodule
