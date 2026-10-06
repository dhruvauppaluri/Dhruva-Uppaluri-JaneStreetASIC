`timescale 1ns/1ps

module spi_eth_firmware_tb;

reg clk;
reg reset;
reg enable;
reg program_we;
reg [7:0] program_address;
reg [15:0] program_data;
wire [7:0] gpio_out;
wire [7:0] gpio_oe;
wire halted;
wire waiting;
wire [7:0] pc;

reg [15:0] firmware_words [0:255];
integer address;
integer errors;
integer bit_count;
integer byte_count;
reg [7:0] shifter;
reg [7:0] captured [0:7];
reg previous_sclk;
reg previous_cs;
reg [7:0] expected [0:6];

wire sclk = gpio_out[2];
wire mosi = gpio_out[3];
wire cs_n = gpio_out[5];
wire rst_n = gpio_out[6];

protocol_processor dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .program_we(program_we),
    .program_address(program_address),
    .program_data(program_data),
    .assist_cfg_we(1'b0),
    .assist_cfg_address(2'd0),
    .assist_cfg_data(8'h00),
    .gpio_in(8'h00),
    .gpio_out(gpio_out),
    .gpio_oe(gpio_oe),
    .halted(halted),
    .waiting(waiting),
    .pc(pc)
);

always #10 clk = ~clk;

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
    program_address = 8'd0;
    program_data = 16'h0000;
    errors = 0;
    bit_count = 0;
    byte_count = 0;
    shifter = 8'h00;
    previous_sclk = 1'b0;
    previous_cs = 1'b1;

    expected[0] = 8'h7A;
    expected[1] = 8'hFF;
    expected[2] = 8'hFF;
    expected[3] = 8'hFF;
    expected[4] = 8'hFF;
    expected[5] = 8'hFF;
    expected[6] = 8'hFF;

    $readmemh("firmware/enc28j60_min_frame.hex", firmware_words);

    for (address = 0; address < 256; address = address + 1) begin
        @(negedge clk);
        program_address = address[7:0];
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

        if (pc != 8'd0 && gpio_oe[6:5] !== 2'b11) begin
            $display("ERROR: CS/RST were not configured as outputs");
            errors = errors + 1;
        end
        if (pc > 8'd1 && rst_n !== 1'b1) begin
            $display("ERROR: ENC28J60 RST was not held deasserted");
            errors = errors + 1;
        end

        if (previous_cs && !cs_n) begin
            bit_count = 0;
            byte_count = 0;
            shifter = 8'h00;
        end

        if (!cs_n && !previous_sclk && sclk) begin
            shifter = {shifter[6:0], mosi};
            bit_count = bit_count + 1;
            if (bit_count == 8) begin
                captured[byte_count] = shifter;
                byte_count = byte_count + 1;
                bit_count = 0;
                shifter = 8'h00;
            end
        end

        previous_sclk = sclk;
        previous_cs = cs_n;
    end

    if (byte_count != 7) begin
        $display("ERROR: captured %0d SPI bytes, expected 7", byte_count);
        errors = errors + 1;
    end else begin
        for (address = 0; address < 7; address = address + 1) begin
            if (captured[address] !== expected[address]) begin
                $display(
                    "ERROR: SPI byte %0d expected %02h observed %02h",
                    address, expected[address], captured[address]
                );
                errors = errors + 1;
            end
        end
    end

    if (cs_n !== 1'b1) begin
        $display("ERROR: firmware did not halt with CS high");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: ENC28J60 SPI min-frame firmware verified");
    else
        $display("FAIL: SPI Ethernet firmware errors=%0d", errors);

    $finish;
end

initial begin
    #2000000;
    $display("FAIL: SPI Ethernet firmware testbench timeout");
    $finish;
end

endmodule
