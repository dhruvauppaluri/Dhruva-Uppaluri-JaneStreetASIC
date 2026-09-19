`timescale 1ns/1ps

module protocol_classifier_tb;

reg clk;
reg reset;
reg enable;
reg [7:0] gpio_in;
reg config_we;
reg [2:0] config_address;
reg [15:0] config_data;
wire class_result;
wire class_valid;

integer errors;
integer cycle;

protocol_classifier dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .gpio_in(gpio_in),
    .config_we(config_we),
    .config_address(config_address),
    .config_data(config_data),
    .class_result(class_result),
    .class_valid(class_valid)
);

always #5 clk = ~clk;

task step;
    begin
        @(posedge clk);
        #1;
    end
endtask

task write_config;
    input [2:0] address;
    input [15:0] data;
    begin
        @(negedge clk);
        config_address = address;
        config_data = data;
        config_we = 1'b1;
        step();
        config_we = 1'b0;
    end
endtask

task wait_for_valid;
    begin
        while (!class_valid)
            step();
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    enable = 1'b0;
    gpio_in = 8'h00;
    config_we = 1'b0;
    config_address = 3'd0;
    config_data = 16'h0000;
    errors = 0;

    repeat (2) step();
    reset = 1'b0;

    // score = 4*pin0_edges - pin0_high_cycles - 8
    write_config(3'd0, 16'h0004);
    write_config(3'd1, 16'h00FF);
    write_config(3'd2, 16'h0000);
    write_config(3'd3, 16'h0000);
    write_config(3'd4, 16'hFFF8);

    enable = 1'b1;

    // An idle-low window has score -8 and belongs to class zero.
    wait_for_valid();
    if (class_result !== 1'b0) begin
        $display("ERROR: idle signature classified as active");
        errors = errors + 1;
    end

    // Toggle pin zero every cycle. The many transitions produce class one.
    for (cycle = 0; cycle < 32; cycle = cycle + 1) begin
        @(negedge clk);
        gpio_in[0] = ~gpio_in[0];
        step();
    end
    wait_for_valid();
    if (class_result !== 1'b1) begin
        $display("ERROR: active signature classified as idle");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: programmable protocol signature classifier verified");
    else
        $display("FAIL: protocol classifier errors=%0d", errors);

    $finish;
end

initial begin
    #5000;
    $display("FAIL: protocol classifier testbench timeout");
    $finish;
end

endmodule
