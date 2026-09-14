`timescale 1ns/1ps

module pin_generator_tb;

reg clk;
reg reset;
reg enable;
reg [3:0] cycles_per_toggle;
wire pin_out;

integer cycles_since_toggle;
integer toggles_seen;
integer errors;
reg previous_pin_out;
reg [3:0] previous_counter;

pin_generator dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .cycles_per_toggle(cycles_per_toggle),
    .pin_out(pin_out)
);

// 10 ns clock period = 100 MHz.
always #5 clk = ~clk;

// Check timing while enabled and verify that the DUT holds while disabled.
always @(negedge clk)
begin
    if (reset)
    begin
        cycles_since_toggle = 0;
    end
    else if (enable && cycles_per_toggle != 0)
    begin
        cycles_since_toggle = cycles_since_toggle + 1;

        if (pin_out != previous_pin_out)
        begin
            toggles_seen = toggles_seen + 1;

            if (cycles_since_toggle != cycles_per_toggle)
            begin
                $display(
                    "ERROR at %0t: expected %0d enabled cycles, observed %0d",
                    $time,
                    cycles_per_toggle,
                    cycles_since_toggle
                );
                errors = errors + 1;
            end

            cycles_since_toggle = 0;
        end
    end
    else if (!enable)
    begin
        if (dut.counter !== previous_counter)
        begin
            $display("ERROR at %0t: counter changed while disabled", $time);
            errors = errors + 1;
        end

        if (pin_out !== previous_pin_out)
        begin
            $display("ERROR at %0t: pin_out changed while disabled", $time);
            errors = errors + 1;
        end
    end

    previous_counter = dut.counter;
    previous_pin_out = pin_out;
end

initial
begin
    clk = 0;
    reset = 1;
    enable = 1;
    cycles_per_toggle = 4'd5;
    cycles_since_toggle = 0;
    toggles_seen = 0;
    errors = 0;
    previous_pin_out = 0;
    previous_counter = 0;

    // Test 1: toggle every five cycles (50 ns).
    #22;
    reset = 0;
    #150;

    // Test 2: reset, then toggle every three cycles (30 ns).
    reset = 1;
    cycles_per_toggle = 4'd3;
    #20;
    reset = 0;
    #120;

    // Test 3: pause after two of five cycles, hold for four clocks,
    // then resume for the remaining three enabled cycles.
    reset = 1;
    cycles_per_toggle = 4'd5;
    #20;
    reset = 0;
    #20;
    enable = 0;
    #40;
    enable = 1;
    #40;

    // Test 4: zero is an invalid timing value. It must put the generator
    // into its safe idle state and keep it there.
    cycles_per_toggle = 4'd0;
    #50;

    if (dut.counter !== 4'd0)
    begin
        $display("ERROR: counter was not zero in zero-cycle mode");
        errors = errors + 1;
    end

    if (pin_out !== 1'b0)
    begin
        $display("ERROR: pin_out was not low in zero-cycle mode");
        errors = errors + 1;
    end

    if (errors == 0 && toggles_seen >= 8)
        $display("PASS: timing, enable pause, and zero-cycle safety verified");
    else
        $display(
            "FAIL: errors=%0d toggles_seen=%0d",
            errors,
            toggles_seen
        );

    $finish;
end

initial
begin
    $monitor(
        "time=%0t reset=%b enable=%b cycles=%0d counter=%0d pin_out=%b",
        $time,
        reset,
        enable,
        cycles_per_toggle,
        dut.counter,
        pin_out
    );
end

endmodule
