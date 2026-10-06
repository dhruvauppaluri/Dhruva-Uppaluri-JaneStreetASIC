`timescale 1ns/1ps

// Cycle-accurate vectors for the general assist: USB CRC-16, NRZI of
// SYNC+DATA0 PID, and bit stuffing of 0xFF.
module assist_engine_tb;

reg clk;
reg reset;
reg enable;
reg we;
reg [1:0] wr_addr;
reg [7:0] wr_data;
reg [1:0] rd_addr;
wire [7:0] rd_data;
reg [7:0] gpio_in;
wire [7:0] assist_out;
wire [7:0] assist_oe;

integer errors;
integer bit_number;
integer i;

// Expected NRZI line (K=1) for SYNC 0x80 then DATA0 PID 0xC3, LSB first.
reg expected_sync_pid [0:15];
// 0xFF LSB-first with stuffing: six 1s, stuffed 0, two 1s -> 9 NRZI bits
// starting from J: stay J for six 1s, toggle to K on stuffed 0, stay K.
reg expected_ff_stuff [0:8];

assist_engine dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .we(we),
    .wr_addr(wr_addr),
    .wr_data(wr_data),
    .rd_addr(rd_addr),
    .rd_data(rd_data),
    .gpio_in(gpio_in),
    .assist_out(assist_out),
    .assist_oe(assist_oe)
);

always #10 clk = ~clk;

task step;
    begin
        @(posedge clk);
        #1;
    end
endtask

task write_port;
    input [1:0] addr;
    input [7:0] data;
    begin
        @(negedge clk);
        wr_addr = addr;
        wr_data = data;
        we = 1'b1;
        @(posedge clk);
        #1;
        we = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    enable = 1'b0;
    we = 1'b0;
    wr_addr = 2'd0;
    wr_data = 8'h00;
    rd_addr = 2'd0;
    gpio_in = 8'h00;
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

    expected_ff_stuff[0] = 1'b0;
    expected_ff_stuff[1] = 1'b0;
    expected_ff_stuff[2] = 1'b0;
    expected_ff_stuff[3] = 1'b0;
    expected_ff_stuff[4] = 1'b0;
    expected_ff_stuff[5] = 1'b0;
    expected_ff_stuff[6] = 1'b1;
    expected_ff_stuff[7] = 1'b1;
    expected_ff_stuff[8] = 1'b1;

    repeat (2) step();
    reset = 1'b0;
    enable = 1'b1;
    step();

    // CRC-16 of 0xA5 is the USB wire value 0xC480.
    write_port(2'd0, 8'h10);
    write_port(2'd3, 8'hA5);
    rd_addr = 2'd3;
    #1;
    if (rd_data !== 8'h80) begin
        $display("ERROR: CRC low expected 80 observed %02h", rd_data);
        errors = errors + 1;
    end
    rd_addr = 2'd1;
    #1;
    if (rd_data !== 8'hC4) begin
        $display("ERROR: CRC high expected C4 observed %02h", rd_data);
        errors = errors + 1;
    end

    write_port(2'd0, 8'h02); // soft reset

    write_port(2'd1, 8'd4);
    write_port(2'd0, 8'h0C);
    write_port(2'd2, 8'h80);
    write_port(2'd2, 8'hC3);
    write_port(2'd0, 8'h0D); // start
    step(); // first bit issued

    for (bit_number = 0; bit_number < 16; bit_number = bit_number + 1) begin
        if (assist_out[0] !== expected_sync_pid[bit_number] ||
            assist_out[1] !== ~expected_sync_pid[bit_number] ||
            assist_oe[1:0] !== 2'b11) begin
            $display(
                "ERROR: NRZI bit %0d expected D+=%b D-=%b observed %b%b",
                bit_number, expected_sync_pid[bit_number],
                ~expected_sync_pid[bit_number], assist_out[0], assist_out[1]
            );
            errors = errors + 1;
        end
        if (bit_number != 15)
            repeat (4) step();
    end

    rd_addr = 2'd0;
    #1;
    for (i = 0; i < 8 && rd_data[0]; i = i + 1)
        step();
    if (rd_data[0]) begin
        $display("ERROR: assist stayed busy after SYNC+PID");
        errors = errors + 1;
    end

    write_port(2'd0, 8'h02);
    write_port(2'd1, 8'd2);
    write_port(2'd0, 8'h0C);
    write_port(2'd2, 8'hFF);
    write_port(2'd0, 8'h0D);
    step();

    for (bit_number = 0; bit_number < 9; bit_number = bit_number + 1) begin
        if (assist_out[0] !== expected_ff_stuff[bit_number]) begin
            $display(
                "ERROR: stuffed 0xFF bit %0d expected %b observed %b",
                bit_number, expected_ff_stuff[bit_number], assist_out[0]
            );
            errors = errors + 1;
        end
        if (bit_number != 8)
            repeat (2) step();
    end

    if (errors == 0)
        $display("PASS: assist NRZI, bit stuffing, and USB CRC-16 verified");
    else
        $display("FAIL: assist engine errors=%0d", errors);

    $finish;
end

initial begin
    #100000;
    $display("FAIL: assist engine testbench timeout");
    $finish;
end

endmodule
