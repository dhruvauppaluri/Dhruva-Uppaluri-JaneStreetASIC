`timescale 1ns/1ps

// Host BFM: SE0 reset, SET_ADDRESS, GET_DESCRIPTOR device on D+/D-.
module usb_ls_enumerate_tb;

localparam integer PERIOD = 33;
localparam integer IPG    = 4;

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
integer watchdog;
integer i;

reg host_drive;
reg host_dp;
reg host_dm;
reg [2:0] tx_ones;
reg tx_line;

wire dev_oe = gpio_oe[0] && gpio_oe[1];
wire bus_dp = dev_oe ? gpio_out[0] : (host_drive ? host_dp : 1'b0);
wire bus_dm = dev_oe ? gpio_out[1] : (host_drive ? host_dm : 1'b1);
wire [7:0] gpio_in = {6'b000000, bus_dm, bus_dp};

reg [7:0] rx_bytes [0:31];
integer rx_count;

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

task idle_j;
    input integer bits;
    begin
        host_drive = 1'b1;
        host_dp = 1'b0;
        host_dm = 1'b1;
        tx_line = 1'b0;
        tx_ones = 3'd0;
        repeat (bits * PERIOD) step();
    end
endtask

task drive_se0;
    input integer bits;
    begin
        host_drive = 1'b1;
        host_dp = 1'b0;
        host_dm = 1'b0;
        repeat (bits * PERIOD) step();
    end
endtask

task emit_nrzi_bit;
    input nrzi_one;
    begin
        if (!nrzi_one)
            tx_line = ~tx_line;
        host_dp = tx_line;
        host_dm = ~tx_line;
        host_drive = 1'b1;
        if (nrzi_one)
            tx_ones = tx_ones + 3'd1;
        else
            tx_ones = 3'd0;
        repeat (PERIOD) step();
        if (tx_ones == 3'd6) begin
            tx_line = ~tx_line;
            host_dp = tx_line;
            host_dm = ~tx_line;
            tx_ones = 3'd0;
            repeat (PERIOD) step();
        end
    end
endtask

task send_byte;
    input [7:0] data;
    integer b;
    begin
        for (b = 0; b < 8; b = b + 1)
            emit_nrzi_bit(data[b]);
    end
endtask

task send_packet;
    input integer nbytes;
    integer n;
    begin
        idle_j(IPG);
        send_byte(8'h80);
        for (n = 0; n < nbytes; n = n + 1)
            send_byte(rx_bytes[n]);
        host_dp = 1'b0;
        host_dm = 1'b0;
        repeat (2 * PERIOD) step();
        host_drive = 1'b0;
        tx_line = 1'b0;
        tx_ones = 3'd0;
    end
endtask

task recv_packet;
    integer stuffed;
    integer decoded;
    integer ones;
    integer prev;
    integer cur;
    integer bits;
    integer complete;
    begin
        host_drive = 1'b0;
        watchdog = 0;
        while (!(bus_dp === 1'b1 && bus_dm === 1'b0) && watchdog < 20000) begin
            step();
            watchdog = watchdog + 1;
        end
        if (!(bus_dp === 1'b1 && bus_dm === 1'b0)) begin
            $display("ERROR: timed out waiting for device K");
            errors = errors + 1;
            rx_count = 0;
            disable recv_packet;
        end
        // First K is the SYNC NRZI 0. Sample here (bit start is still the
        // driven level) then step a full bit-time between samples.
        prev = 0;
        ones = 0;
        bits = 0;
        rx_count = 0;
        complete = 0;
        stuffed = 0;
        while (!complete && watchdog < 40000) begin
            cur = bus_dp;
            if (bus_dp === 1'b0 && bus_dm === 1'b0) begin
                repeat (PERIOD) step();
                complete = 1;
            end else begin
                decoded = (cur == prev);
                prev = cur;
                if (stuffed) begin
                    stuffed = 0;
                    ones = 0;
                end else begin
                    if (decoded) begin
                        if (ones == 5)
                            stuffed = 1;
                        ones = (ones == 5) ? 0 : (ones + 1);
                    end else
                        ones = 0;
                    rx_bytes[rx_count] = {(decoded != 0), rx_bytes[rx_count][7:1]};
                    bits = bits + 1;
                    if (bits == 8) begin
                        bits = 0;
                        rx_count = rx_count + 1;
                    end
                end
                repeat (PERIOD) step();
            end
            watchdog = watchdog + 1;
        end
        if (rx_count > 0 && rx_bytes[0] != 8'h80) begin
            $display("ERROR: device packet missing SYNC, first=%02h count=%0d",
                     rx_bytes[0], rx_count);
            errors = errors + 1;
        end
    end
endtask

task expect_pid;
    input [7:0] pid;
    begin
        if (rx_count < 2 || rx_bytes[1] !== pid) begin
            $display("ERROR: expected PID %02h observed %02h (count=%0d)",
                     pid, (rx_count > 1) ? rx_bytes[1] : 8'hxx, rx_count);
            errors = errors + 1;
        end
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    enable = 1'b0;
    program_we = 1'b0;
    program_address = 8'd0;
    program_data = 16'h0000;
    host_drive = 1'b0;
    host_dp = 1'b0;
    host_dm = 1'b1;
    tx_line = 1'b0;
    tx_ones = 3'd0;
    errors = 0;

    load_firmware("firmware/usb_ls_device_lite.hex");
    idle_j(4);
    drive_se0(24);
    idle_j(8);

    // SETUP + SET_ADDRESS(5) to address 0
    rx_bytes[0] = 8'h2D;
    rx_bytes[1] = 8'h00;
    rx_bytes[2] = 8'h10;
    send_packet(3);
    rx_bytes[0] = 8'hC3;
    rx_bytes[1] = 8'h00;
    rx_bytes[2] = 8'h05;
    rx_bytes[3] = 8'h05;
    rx_bytes[4] = 8'h00;
    rx_bytes[5] = 8'h00;
    rx_bytes[6] = 8'h00;
    rx_bytes[7] = 8'h00;
    rx_bytes[8] = 8'h00;
    rx_bytes[9] = 8'hEA;
    rx_bytes[10] = 8'hA1;
    send_packet(11);
    recv_packet();
    expect_pid(8'hD2);

    // Status IN (still address 0) -> DATA1 ZLP
    rx_bytes[0] = 8'h69;
    rx_bytes[1] = 8'h00;
    rx_bytes[2] = 8'h10;
    send_packet(3);
    recv_packet();
    expect_pid(8'h4B);
    if (rx_count < 4) begin
        $display("ERROR: SET_ADDRESS status DATA1 too short (%0d bytes)", rx_count);
        errors = errors + 1;
    end
    rx_bytes[0] = 8'hD2;
    send_packet(1);

    // GET_DESCRIPTOR device at address 5
    rx_bytes[0] = 8'h2D;
    rx_bytes[1] = 8'h05;
    rx_bytes[2] = 8'hD0;
    send_packet(3);
    rx_bytes[0] = 8'hC3;
    rx_bytes[1] = 8'h80;
    rx_bytes[2] = 8'h06;
    rx_bytes[3] = 8'h00;
    rx_bytes[4] = 8'h01;
    rx_bytes[5] = 8'h00;
    rx_bytes[6] = 8'h00;
    rx_bytes[7] = 8'h12;
    rx_bytes[8] = 8'h00;
    rx_bytes[9] = 8'hE0;
    rx_bytes[10] = 8'hF4;
    send_packet(11);
    recv_packet();
    expect_pid(8'hD2);

    rx_bytes[0] = 8'h69;
    rx_bytes[1] = 8'h05;
    rx_bytes[2] = 8'hD0;
    send_packet(3);
    recv_packet();
    expect_pid(8'h4B);
    if (rx_count < 22) begin
        $display("ERROR: descriptor packet too short (%0d bytes)", rx_count);
        errors = errors + 1;
    end else begin
        if (rx_bytes[2] !== 8'h12 || rx_bytes[3] !== 8'h01 ||
            rx_bytes[4] !== 8'h00 || rx_bytes[5] !== 8'h02) begin
            $display("ERROR: device descriptor header mismatch");
            errors = errors + 1;
        end
        if (rx_bytes[20] !== 8'h9F || rx_bytes[21] !== 8'h5C) begin
            $display("ERROR: descriptor CRC-16 mismatch %02h %02h",
                     rx_bytes[20], rx_bytes[21]);
            errors = errors + 1;
        end
        for (i = 0; i < 18; i = i + 1) begin
            // bytes 2..19 are descriptor
        end
    end
    rx_bytes[0] = 8'hD2;
    send_packet(1);

    rx_bytes[0] = 8'hE1;
    rx_bytes[1] = 8'h05;
    rx_bytes[2] = 8'hD0;
    send_packet(3);
    rx_bytes[0] = 8'hC3;
    rx_bytes[1] = 8'h00;
    rx_bytes[2] = 8'h00;
    send_packet(3);
    recv_packet();
    expect_pid(8'hD2);

    if (errors == 0)
        $display("PASS: USB LS SET_ADDRESS and GET_DESCRIPTOR device-lite verified");
    else
        $display("FAIL: USB LS enumerate errors=%0d", errors);
    $finish;
end

initial begin
    #30000000;
    $display("FAIL: USB LS enumerate testbench timeout");
    $finish;
end

endmodule
