/*
 * 512 x 64 record memory, one access per cycle, registered read data
 * (read data appears after the clock edge that samples the address and holds
 * until the next read) -- the IHP 1P SRAM macro behaviour.
 *
 * `define SETL_IHP_SRAM    -> two RM_IHPSG13_1P_512x32_c2_bm_bist macros (512 words)
 * `define SETL_SIM_FULLMEM -> 512-word behavioural array (RTL simulation, FPGA)
 * otherwise               -> 64-word flip-flop array (stock-flow fallback)
 * SPDX-License-Identifier: MIT
 */
`default_nettype none

module setl_mem (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire [8:0]  addr,
    input  wire [63:0] wdata,
    input  wire [63:0] bmask,
    output wire [63:0] rdata
);
`ifdef SETL_IHP_SRAM
    genvar h;
    generate
        for (h = 0; h < 2; h = h + 1) begin : g_sram
            RM_IHPSG13_1P_512x32_c2_bm_bist sram (
                .A_CLK(clk),
                .A_MEN(en),
                .A_WEN(we),
                .A_REN(~we),
                .A_ADDR(addr),
                .A_DIN(wdata[32*h +: 32]),
                .A_DLY(1'b1),
                .A_DOUT(rdata[32*h +: 32]),
                .A_BM(bmask[32*h +: 32]),
                .A_BIST_CLK(1'b0),
                .A_BIST_EN(1'b0),
                .A_BIST_MEN(1'b0),
                .A_BIST_WEN(1'b0),
                .A_BIST_REN(1'b0),
                .A_BIST_ADDR(9'd0),
                .A_BIST_DIN(32'd0),
                .A_BIST_BM(32'd0)
            );
        end
    endgenerate
`elsif SETL_SIM_FULLMEM
    // simulation: full 512-word behavioural array
    reg [63:0] ram [0:511];
    reg [63:0] q;
    assign rdata = q;
`ifdef SETL_SIM_BACKDOOR
    // simulation only: the random co-simulation test loads programs here
    reg bd_load = 1'b0;
    always @(posedge bd_load) $readmemh("backdoor.hex", ram);
`endif
    always @(posedge clk) begin
        if (en) begin
            if (we)
                ram[addr] <= (ram[addr] & ~bmask) | (wdata & bmask);
            else
                q <= ram[addr];
        end
    end
`else
    // Fallback for the stock Tiny Tapeout flow (no SRAM macro): a 64-word
    // flip-flop array.  Addresses alias modulo 64.  Same timing contract.
    reg [63:0] ram [0:63];
    reg [63:0] q;
    assign rdata = q;
    always @(posedge clk) begin
        if (en) begin
            if (we)
                ram[addr[5:0]] <= (ram[addr[5:0]] & ~bmask) | (wdata & bmask);
            else
                q <= ram[addr[5:0]];
        end
    end
`endif
endmodule
