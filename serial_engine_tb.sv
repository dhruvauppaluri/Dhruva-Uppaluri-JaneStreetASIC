`timescale 1ns/1ps

// CRC-32 and RMII-10 dibit hold on the shared serial engine.
module serial_engine_tb;

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
integer i;

serial_engine dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .we(we),
    .wr_addr(wr_addr),
    .wr_data(wr_data),
    .rd_addr(rd_addr),
    .rd_inc(1'b0),
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
    rd_addr = 2'd3;
    gpio_in = 8'h00;
    errors = 0;

    repeat (2) step();
    reset = 1'b0;
    enable = 1'b1;
    step();

    write_port(2'd3, 8'hC2);
    write_port(2'd0, 8'h10);
    write_port(2'd3, 8'h00);
    rd_addr = 2'd3;
    #1;
    if (rd_data !== 8'h8D) begin
        $display("ERROR: CRC32 low expected 8D observed %02h", rd_data);
        errors = errors + 1;
    end
    rd_addr = 2'd1;
    #1;
    if (rd_data !== 8'hEF) begin
        $display("ERROR: CRC32[15:8] expected EF observed %02h", rd_data);
        errors = errors + 1;
    end

    write_port(2'd0, 8'h02);
    write_port(2'd3, 8'hEF);
    write_port(2'd1, 8'd10);
    write_port(2'd2, 8'h00);
    write_port(2'd0, 8'h01);
    step();

    for (i = 0; i < 10; i = i + 1) begin
        if (assist_out[2] !== 1'b1 || assist_out[3] !== 1'b0 ||
            assist_out[4] !== 1'b1 || assist_oe[4:2] !== 3'b111) begin
            $display(
                "ERROR: RMII hold clock %0d expected TXD=01 TX_EN=1 observed %b%b en=%b",
                i, assist_out[3], assist_out[2], assist_out[4]
            );
            errors = errors + 1;
        end
        if (i != 9)
            step();
    end

    rd_addr = 2'd0;
    #1;
    for (i = 0; i < 20000 && rd_data[7]; i = i + 1)
        step();
    if (rd_data[7]) begin
        $display("ERROR: RMII TX stayed active");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: serial engine CRC-32 and RMII-10 hold verified");
    else
        $display("FAIL: serial engine errors=%0d", errors);
    $finish;
end

initial begin
    #2000000;
    $display("FAIL: serial engine testbench timeout");
    $finish;
end

endmodule
