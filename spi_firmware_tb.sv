`timescale 1ns/1ps

module spi_firmware_tb;

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
integer edge_count;
integer cycles_since_edge;
integer errors;
reg previous_sclk;

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
    edge_count = 0;
    cycles_since_edge = 0;
    errors = 0;
    previous_sclk = 1'b0;

    $readmemh("firmware/spi_mode0_nibble.hex", firmware_words);

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

    // Observe all four SPI mode-0 sampling edges. MOSI must be stable when
    // SCLK rises, and each half-period must be ten 50 MHz clocks.
    while (!halted) begin
        step();

        if (pc != 5'd0 && gpio_oe[1:0] !== 2'b11) begin
            $display("ERROR: SPI pins were not both configured as outputs");
            errors = errors + 1;
        end

        cycles_since_edge = cycles_since_edge + 1;

        if (!previous_sclk && gpio_out[1]) begin
            if (edge_count > 0 && cycles_since_edge != 20) begin
                $display(
                    "ERROR: SPI rising edges were %0d clocks apart, expected 20",
                    cycles_since_edge
                );
                errors = errors + 1;
            end

            case (edge_count)
                0: if (gpio_out[0] !== 1'b1) errors = errors + 1;
                1: if (gpio_out[0] !== 1'b0) errors = errors + 1;
                2: if (gpio_out[0] !== 1'b1) errors = errors + 1;
                3: if (gpio_out[0] !== 1'b0) errors = errors + 1;
                default: begin
                    $display("ERROR: observed an extra SPI rising edge");
                    errors = errors + 1;
                end
            endcase

            edge_count = edge_count + 1;
            cycles_since_edge = 0;
        end

        previous_sclk = gpio_out[1];
    end

    if (edge_count != 4) begin
        $display("ERROR: observed %0d SPI rising edges, expected 4", edge_count);
        errors = errors + 1;
    end

    if (gpio_out[1:0] !== 2'b00 || gpio_oe[1:0] !== 2'b11) begin
        $display("ERROR: SPI firmware did not halt with SCLK and MOSI low");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: SPI mode-0 firmware transmitted 0xA with exact timing");
    else
        $display("FAIL: SPI firmware errors=%0d", errors);

    $finish;
end

initial begin
    #30000;
    $display("FAIL: SPI firmware testbench timeout");
    $finish;
end

endmodule
