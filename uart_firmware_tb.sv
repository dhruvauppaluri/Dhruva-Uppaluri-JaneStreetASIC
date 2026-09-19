`timescale 1ns/1ps

module uart_firmware_tb;

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
reg [9:0] expected_frame;
integer address;
integer bit_number;
integer errors;

protocol_processor dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .program_we(program_we),
    .program_address(program_address),
    .program_data(program_data),
    .gpio_in(8'h00),
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
    expected_frame = {1'b1, 8'hA5, 1'b0};
    errors = 0;

    $readmemh("firmware/uart_tx_a5.hex", firmware_words);

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

    step(); // DIR
    step(); // idle OUT
    step(); // WAIT 2 starts
    step();
    step();
    step(); // start-bit OUT

    if (gpio_oe[0] !== 1'b1 || gpio_out[0] !== expected_frame[0]) begin
        $display("ERROR: UART start bit or output enable incorrect");
        errors = errors + 1;
    end

    // Every following UART bit begins exactly 50 clocks later.
    for (bit_number = 1; bit_number < 10; bit_number = bit_number + 1) begin
        repeat (50) step();
        if (gpio_out[0] !== expected_frame[bit_number]) begin
            $display(
                "ERROR: UART bit %0d expected %b observed %b",
                bit_number, expected_frame[bit_number], gpio_out[0]
            );
            errors = errors + 1;
        end
    end

    repeat (50) step();
    if (!halted || gpio_out[0] !== 1'b1) begin
        $display("ERROR: UART firmware did not halt in idle-high state");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: UART 0xA5 firmware timing verified at 1 Mbit/s");
    else
        $display("FAIL: UART firmware errors=%0d", errors);

    $finish;
end

initial begin
    #30000;
    $display("FAIL: UART firmware testbench timeout");
    $finish;
end

endmodule
