/*
 * 16-entry byte FIFO. A push when full is dropped unless a pop happens in the
 * same cycle. A pop when empty does nothing.
 * SPDX-License-Identifier: MIT
 */
`default_nettype none

module setl_fifo (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       push,
    input  wire [7:0] wdata,
    input  wire       pop,
    output wire [7:0] head,
    output reg  [4:0] level
);
    reg [7:0] mem [0:15];
    reg [3:0] rp, wp;
    wire do_pop  = pop & (level != 5'd0);
    wire do_push = push & ((level != 5'd16) | do_pop);
    assign head = mem[rp];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rp <= 4'd0; wp <= 4'd0; level <= 5'd0;
        end else begin
            if (do_pop) rp <= rp + 4'd1;
            if (do_push) wp <= wp + 4'd1;
            level <= level + {4'd0, do_push} - {4'd0, do_pop};
        end
    end

    always @(posedge clk)
        if (do_push) mem[wp] <= wdata;
endmodule
