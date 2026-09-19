`timescale 1ns/1ps

module tiny_tapeout_wrapper_tb;

reg [7:0] ui_in;
wire [7:0] uo_out;
reg [7:0] uio_in;
wire [7:0] uio_out;
wire [7:0] uio_oe;
reg ena;
reg clk;
reg rst_n;

integer errors;
integer bit_index;
integer activity_cycle;

tt_um_dhruvauppaluri_protocol_emulator dut (
    .ui_in(ui_in),
    .uo_out(uo_out),
    .uio_in(uio_in),
    .uio_out(uio_out),
    .uio_oe(uio_oe),
    .ena(ena),
    .clk(clk),
    .rst_n(rst_n)
);

always #5 clk = ~clk;

task step;
    begin
        @(posedge clk);
        #1;
    end
endtask

task load_word;
    input [15:0] word;
    begin
        for (bit_index = 15; bit_index >= 0; bit_index = bit_index - 1) begin
            @(negedge clk);
            ui_in[0] = word[bit_index];
            ui_in[1] = 1'b1;
            @(posedge clk);
            #1;
            ui_in[1] = 1'b0;
        end

        @(negedge clk);
        ui_in[2] = 1'b1;
        @(posedge clk);
        #1;
        ui_in[2] = 1'b0;

        // The loader registers the memory write request on commit; this
        // following edge performs the actual instruction-memory write.
        @(posedge clk);
        #1;
    end
endtask

initial begin
    ui_in = 8'h00;
    uio_in = 8'h00;
    ena = 1'b1;
    clk = 1'b0;
    rst_n = 1'b0;
    errors = 0;

    repeat (3) step();
    rst_n = 1'b1;

    // DIR FF; OUT A5; WAIT 2; OUT 5A; HALT
    load_word(16'h20FF);
    load_word(16'h10A5);
    load_word(16'h3002);
    load_word(16'h105A);
    load_word(16'hF000);

    // Restart the loader address and target classifier configuration.
    @(negedge clk);
    ui_in[5] = 1'b1;
    @(posedge clk);
    #1;
    ui_in[5] = 1'b0;
    ui_in[4] = 1'b1;

    // score = 4*pin0_edges - pin0_high_cycles - 8
    load_word(16'h0004);
    load_word(16'h00FF);
    load_word(16'h0000);
    load_word(16'h0000);
    load_word(16'hFFF8);

    @(negedge clk);
    ui_in[4] = 1'b0;
    ui_in[3] = 1'b1;

    step(); // DIR
    if (uio_oe !== 8'hFF || uo_out[4:0] !== 5'd1) errors = errors + 1;

    step(); // OUT A5
    if (uio_out !== 8'hA5 || uo_out[4:0] !== 5'd2) errors = errors + 1;

    step(); // WAIT 2
    if (!uo_out[6] || uo_out[4:0] !== 5'd3) errors = errors + 1;

    step(); // idle 1
    if (uio_out !== 8'hA5 || !uo_out[6]) errors = errors + 1;
    step(); // idle 2
    if (uio_out !== 8'hA5 || uo_out[6]) errors = errors + 1;

    step(); // OUT 5A
    if (uio_out !== 8'h5A || uo_out[4:0] !== 5'd4) errors = errors + 1;
    step(); // HALT
    if (!uo_out[5] || uo_out[4:0] !== 5'd4) errors = errors + 1;

    // The first 32-cycle window is idle and must classify as zero.
    repeat (25) step();
    repeat (4) step();
    if (uo_out[7] !== 1'b0) errors = errors + 1;

    // A full window of pin-zero transitions must classify as active.
    repeat (28) step(); // align to the next 32-cycle window
    for (activity_cycle = 0; activity_cycle < 32;
         activity_cycle = activity_cycle + 1) begin
        @(negedge clk);
        uio_in[0] = ~uio_in[0];
        step();
    end
    repeat (4) step();
    if (uo_out[7] !== 1'b1) begin
        $display("ERROR: serially configured classifier did not detect activity");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: Tiny Tapeout serial loading and execution verified");
    else
        $display("FAIL: Tiny Tapeout wrapper errors=%0d", errors);

    $finish;
end

initial begin
    #10000;
    $display("FAIL: Tiny Tapeout wrapper testbench timeout");
    $finish;
end

endmodule
