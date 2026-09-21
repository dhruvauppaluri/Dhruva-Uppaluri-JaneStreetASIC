`timescale 1ns/1ps

module i2c_firmware_tb;

reg clk;
reg reset;
reg enable;
reg program_we;
reg [4:0] program_address;
reg [15:0] program_data;
wire [7:0] gpio_out;
wire [7:0] gpio_oe;
wire halted;
wire waiting;
wire [4:0] pc;

reg [15:0] firmware_words [0:31];
integer address;
integer transition_count;
integer cycles_since_transition;
integer errors;
reg [1:0] previous_lines;
wire [1:0] bus_lines;

// External I2C pull-ups make a released line high. Firmware keeps the output
// latch low and controls the bus exclusively through the output enables.
assign bus_lines[0] = gpio_oe[0] ? gpio_out[0] : 1'b1; // SDA
assign bus_lines[1] = gpio_oe[1] ? gpio_out[1] : 1'b1; // SCL

protocol_processor dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .program_we(program_we),
    .program_address(program_address),
    .program_data(program_data),
    .gpio_in({6'h00, bus_lines}),
    .gpio_out(gpio_out),
    .gpio_oe(gpio_oe),
    .halted(halted),
    .waiting(waiting),
    .pc(pc)
);

always #10 clk = ~clk; // 50 MHz

task step;
    begin
        @(posedge clk);
        #1;
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    enable = 1'b0;
    program_we = 1'b0;
    program_address = 5'd0;
    program_data = 16'h0000;
    transition_count = 0;
    cycles_since_transition = 0;
    errors = 0;
    previous_lines = 2'b11;

    $readmemh("firmware/i2c_start_stop.hex", firmware_words);

    for (address = 0; address < 32; address = address + 1) begin
        @(negedge clk);
        program_address = address[4:0];
        program_data = firmware_words[address];
        program_we = 1'b1;
        @(posedge clk);
        #1;
        program_we = 1'b0;
    end

    @(negedge clk);
    reset = 1'b0;
    enable = 1'b1;

    while (!halted) begin
        step();
        cycles_since_transition = cycles_since_transition + 1;

        if (gpio_out[1:0] !== 2'b00) begin
            $display("ERROR: I2C firmware attempted to drive a line high");
            errors = errors + 1;
        end

        if (bus_lines != previous_lines) begin
            // After the initial released state, every bus transition is ten
            // clocks after the preceding one (WAIT 8 plus two instructions).
            if (transition_count > 0 && cycles_since_transition != 10) begin
                $display(
                    "ERROR: I2C transitions were %0d clocks apart, expected 10",
                    cycles_since_transition
                );
                errors = errors + 1;
            end

            case (transition_count)
                0: if (bus_lines !== 2'b10) begin
                    $display("ERROR: first transition was not START (SDA low, SCL high)");
                    errors = errors + 1;
                end
                1: if (bus_lines !== 2'b00) begin
                    $display("ERROR: SCL was not pulled low after START");
                    errors = errors + 1;
                end
                2: if (bus_lines !== 2'b10) begin
                    $display("ERROR: SCL was not released before STOP");
                    errors = errors + 1;
                end
                3: if (bus_lines !== 2'b11) begin
                    $display("ERROR: final transition was not STOP");
                    errors = errors + 1;
                end
                default: begin
                    $display("ERROR: observed an extra I2C bus transition");
                    errors = errors + 1;
                end
            endcase

            transition_count = transition_count + 1;
            cycles_since_transition = 0;
            previous_lines = bus_lines;
        end
    end

    if (transition_count != 4) begin
        $display(
            "ERROR: observed %0d I2C transitions, expected START sequence and STOP",
            transition_count
        );
        errors = errors + 1;
    end

    if (bus_lines !== 2'b11 || gpio_oe[1:0] !== 2'b00) begin
        $display("ERROR: I2C firmware did not halt with both lines released");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: open-drain I2C START/STOP firmware timing verified");
    else
        $display("FAIL: I2C firmware errors=%0d", errors);

    $finish;
end

initial begin
    #30000;
    $display("FAIL: I2C firmware testbench timeout");
    $finish;
end

endmodule
