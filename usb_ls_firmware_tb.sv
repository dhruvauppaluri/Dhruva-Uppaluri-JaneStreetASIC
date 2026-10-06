`timescale 1ns/1ps

module usb_ls_firmware_tb;

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

reg expected_sync_pid [0:15];
reg expected_data0 [0:39];

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

task wait_for_k;
    begin
        watchdog = 0;
        while (gpio_out[1:0] !== 2'b01 && watchdog < 4000) begin
            step();
            watchdog = watchdog + 1;
        end
        if (gpio_out[1:0] !== 2'b01) begin
            $display("ERROR: USB packet did not start with a K state");
            errors = errors + 1;
        end
    end
endtask

task check_nrzi_bits;
    input integer length;
    integer idx;
    begin
        for (idx = 0; idx < length; idx = idx + 1) begin
            if (gpio_oe[1:0] !== 2'b11) begin
                $display("ERROR: USB D+/D- were not driven during bit %0d", idx);
                errors = errors + 1;
            end
            if (idx < 16) begin
                if (gpio_out[0] !== expected_sync_pid[idx] ||
                    gpio_out[1] !== ~expected_sync_pid[idx]) begin
                    $display(
                        "ERROR: bit %0d expected D+=%b observed %b",
                        idx, expected_sync_pid[idx], gpio_out[0]
                    );
                    errors = errors + 1;
                end
            end
            if (length == 40) begin
                if (gpio_out[0] !== expected_data0[idx] ||
                    gpio_out[1] !== ~expected_data0[idx]) begin
                    $display(
                        "ERROR: DATA0 bit %0d expected D+=%b observed %b",
                        idx, expected_data0[idx], gpio_out[0]
                    );
                    errors = errors + 1;
                end
            end
            if (idx != length - 1)
                repeat (33) step();
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
    errors = 0;

    expected_sync_pid[0]  = 1'b1;
    expected_sync_pid[1]  = 1'b0;
    expected_sync_pid[2]  = 1'b1;
    expected_sync_pid[3]  = 1'b0;
    expected_sync_pid[4]  = 1'b1;
    expected_sync_pid[5]  = 1'b0;
    expected_sync_pid[6]  = 1'b1;
    expected_sync_pid[7]  = 1'b1;
    expected_sync_pid[8]  = 1'b1;
    expected_sync_pid[9]  = 1'b1;
    expected_sync_pid[10] = 1'b0;
    expected_sync_pid[11] = 1'b1;
    expected_sync_pid[12] = 1'b0;
    expected_sync_pid[13] = 1'b1;
    expected_sync_pid[14] = 1'b1;
    expected_sync_pid[15] = 1'b1;

    expected_data0[0]  = 1'b1;
    expected_data0[1]  = 1'b0;
    expected_data0[2]  = 1'b1;
    expected_data0[3]  = 1'b0;
    expected_data0[4]  = 1'b1;
    expected_data0[5]  = 1'b0;
    expected_data0[6]  = 1'b1;
    expected_data0[7]  = 1'b1;
    expected_data0[8]  = 1'b1;
    expected_data0[9]  = 1'b1;
    expected_data0[10] = 1'b0;
    expected_data0[11] = 1'b1;
    expected_data0[12] = 1'b0;
    expected_data0[13] = 1'b1;
    expected_data0[14] = 1'b1;
    expected_data0[15] = 1'b1;
    expected_data0[16] = 1'b1;
    expected_data0[17] = 1'b0;
    expected_data0[18] = 1'b0;
    expected_data0[19] = 1'b1;
    expected_data0[20] = 1'b0;
    expected_data0[21] = 1'b0;
    expected_data0[22] = 1'b1;
    expected_data0[23] = 1'b1;
    expected_data0[24] = 1'b0;
    expected_data0[25] = 1'b1;
    expected_data0[26] = 1'b0;
    expected_data0[27] = 1'b1;
    expected_data0[28] = 1'b0;
    expected_data0[29] = 1'b1;
    expected_data0[30] = 1'b0;
    expected_data0[31] = 1'b0;
    expected_data0[32] = 1'b1;
    expected_data0[33] = 1'b0;
    expected_data0[34] = 1'b0;
    expected_data0[35] = 1'b1;
    expected_data0[36] = 1'b0;
    expected_data0[37] = 1'b1;
    expected_data0[38] = 1'b1;
    expected_data0[39] = 1'b1;

    load_firmware("firmware/usb_ls_sync_pid.hex");
    wait_for_k();
    check_nrzi_bits(16);
    watchdog = 0;
    while (!halted && watchdog < 4000) begin
        step();
        watchdog = watchdog + 1;
    end
    if (!halted) begin
        $display("ERROR: SYNC+PID firmware did not halt");
        errors = errors + 1;
    end

    load_firmware("firmware/usb_ls_data0_crc.hex");
    wait_for_k();
    check_nrzi_bits(40);
    repeat (33) step();
    if (gpio_out[1:0] !== 2'b00) begin
        $display("ERROR: DATA0 firmware did not drive SE0 after CRC");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: USB LS SYNC/PID and DATA0 CRC firmware verified");
    else
        $display("FAIL: USB LS firmware errors=%0d", errors);

    $finish;
end

initial begin
    #4000000;
    $display("FAIL: USB LS firmware testbench timeout");
    $finish;
end

endmodule
