// Formal proof: programs/uart_tx.setl on the setl_lane RTL produces exactly
// 8N1 frames carrying the bytes the host pushed, in order, with every bit
// 2*(TA+1) clocks long, for every host push timing and data.
`default_nettype none
module fv_uart_tx #(parameter [15:0] TA = 16'd0) (
    input wire        clk,
    input wire        host_push,
    input wire [7:0]  host_wdata,
    input wire        host_pop,
    input wire [29:0] pins
);
`include "rom.vh"
`include "sym.vh"
    wire [3:0]  cfg_outinit = 4'hF;
    wire        cfg_msb = 1'b0;
    wire [8:0]  cfg_start = S_UART_TX;
    wire [15:0] cfg_ta = TA, cfg_tb = 16'd0;
    wire [7:0]  cfg_match = 8'd0, cfg_mask = 8'd0;
    wire [31:0] in_vec = {2'b10, pins};
`include "fv_env.vh"

    localparam integer BITC = 2 * (TA + 1);   // clocks per bit (2-lane barrel)
    wire tx = slot_val[0];

    reg        in_frame = 1'b0;
    reg [7:0]  c = 8'd0;
    reg [3:0]  b = 4'd0;
    reg [7:0]  exp;
    wire frame_start = started && !in_frame && !tx;
    wire [7:0] cur = frame_start ? popped : exp;

    always @(posedge clk) if (started) begin
        if (frame_start) begin
            in_frame <= 1'b1; c <= 8'd1; b <= 4'd0; exp <= popped;
        end else if (in_frame) begin
            if (c == BITC - 1) begin
                c <= 8'd0;
                b <= b + 4'd1;
                if (b == 4'd9) in_frame <= 1'b0;
            end else
                c <= c + 8'd1;
        end
    end

    always @(posedge clk) if (started) begin
        // a frame only starts by taking a byte from the FIFO
        if (frame_start) assert(did_pop);
        // between frames the line idles high
        if (!in_frame && !frame_start) assert(tx);
        if (in_frame) begin
            if (b == 4'd0) assert(tx == 1'b0);                 // start bit
            else if (b <= 4'd8) assert(tx == exp[b - 4'd1]);    // data, LSB first
            else assert(tx == 1'b1);                            // stop bit
        end
    end
    // the line never changes except on a bit boundary (no glitches, exact timing)
    always @(posedge clk) if (in_frame && c != 8'd0) assert(tx == $past(tx));
    // no FIFO overflow ever reported
    always @(*) if (started) assert(!ovf_set);
`ifdef REACH
    // reachability: two complete frames must be possible within the bound
    reg [1:0] frames = 2'd0;
    always @(posedge clk) if (in_frame && b == 4'd9 && c == BITC - 1) frames <= frames + 2'd1;
    always @(*) assert(frames < 2'd2);
`endif
endmodule
