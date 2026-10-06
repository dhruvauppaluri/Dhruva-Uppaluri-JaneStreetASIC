`timescale 1ns/1ps

// LAN8720-class RMII-10 loopback: capture MAC TX dibits, replay on RX.
module eth_rmii_loopback_tb;

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
integer i;
integer cap_n;
integer hold;
integer play;
reg [1:0] cap [0:2047];
reg phy_rxd0;
reg phy_rxd1;
reg phy_crs;

wire [7:0] gpio_in = {phy_crs, phy_rxd1, phy_rxd0, 5'b00000};

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
    .gpio_in(gpio_in),
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

task load_firmware;
    input [1023:0] path;
    integer word;
    begin
        for (word = 0; word < 256; word = word + 1)
            firmware_words[word] = 16'hF000;
        $readmemh(path, firmware_words);
        reset = 1'b1;
        enable = 1'b0;
        program_we = 1'b0;
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
    end
endtask

always @(posedge clk) begin
    if (reset) begin
        hold <= 0;
        cap_n <= 0;
    end else if (enable && gpio_out[4]) begin
        if (hold == 0) begin
            cap[cap_n] <= {gpio_out[3], gpio_out[2]};
            cap_n <= cap_n + 1;
            hold <= 9;
        end else
            hold <= hold - 1;
    end else
        hold <= 0;
end

initial begin
    clk = 1'b0;
    reset = 1'b1;
    enable = 1'b0;
    program_we = 1'b0;
    program_address = 8'd0;
    program_data = 16'h0000;
    phy_rxd0 = 1'b0;
    phy_rxd1 = 1'b0;
    phy_crs = 1'b0;
    errors = 0;

    load_firmware("firmware/eth_rmii_loopback.hex");

    i = 0;
    while (!dut.engine.tx_active && i < 5000) begin
        step();
        i = i + 1;
    end
    if (!dut.engine.tx_active) begin
        $display("ERROR: RMII TX never started");
        errors = errors + 1;
    end

    i = 0;
    while (dut.engine.tx_active && i < 20000) begin
        step();
        i = i + 1;
    end
    if (dut.engine.tx_active) begin
        $display("ERROR: RMII TX never finished");
        errors = errors + 1;
    end

    if (cap_n < (8 + 60 + 4) * 4) begin
        $display("ERROR: captured %0d dibits, expected at least %0d",
                 cap_n, (8 + 60 + 4) * 4);
        errors = errors + 1;
    end
    if (cap[0] !== 2'b01) begin
        $display("ERROR: first preamble dibit expected 01 observed %b", cap[0]);
        errors = errors + 1;
    end

    i = 0;
    while (!dut.engine.rx_active && i < 5000) begin
        step();
        i = i + 1;
    end
    if (!dut.engine.rx_active) begin
        $display("ERROR: RMII RX never started");
        errors = errors + 1;
    end

    for (play = 0; play < cap_n; play = play + 1) begin
        phy_crs = 1'b1;
        phy_rxd0 = cap[play][0];
        phy_rxd1 = cap[play][1];
        repeat (10) step();
    end
    phy_crs = 1'b0;
    phy_rxd0 = 1'b0;
    phy_rxd1 = 1'b0;

    i = 0;
    while (!dut.engine.rx_ready && i < 2000) begin
        step();
        i = i + 1;
    end
    if (!dut.engine.rx_ready) begin
        $display("ERROR: RMII RX did not complete");
        errors = errors + 1;
    end
    if (!dut.engine.crc_ok) begin
        $display("ERROR: RMII loopback CRC-32 check failed");
        errors = errors + 1;
    end
    if (dut.engine.byte_count !== 7'd64) begin
        $display("ERROR: RX byte count expected 64 observed %0d",
                 dut.engine.byte_count);
        errors = errors + 1;
    end
    for (i = 0; i < 60; i = i + 1) begin
        if (dut.engine.ram[i] !== 8'h00) begin
            $display("ERROR: payload byte %0d expected 00 observed %02h",
                     i, dut.engine.ram[i]);
            errors = errors + 1;
        end
    end
    if (dut.engine.ram[60] !== 8'h08 || dut.engine.ram[61] !== 8'h89 ||
        dut.engine.ram[62] !== 8'h12 || dut.engine.ram[63] !== 8'h04) begin
        $display("ERROR: FCS bytes %02h %02h %02h %02h",
                 dut.engine.ram[60], dut.engine.ram[61],
                 dut.engine.ram[62], dut.engine.ram[63]);
        errors = errors + 1;
    end

    i = 0;
    while (!halted && i < 2000) begin
        step();
        i = i + 1;
    end

    if (errors == 0)
        $display("PASS: RMII-10 MAC loopback preamble, payload, CRC-32 verified");
    else
        $display("FAIL: RMII loopback errors=%0d", errors);
    $finish;
end

initial begin
    #8000000;
    $display("FAIL: RMII loopback testbench timeout");
    $finish;
end

endmodule
