/*
 * Host interface: SPI target (mode 0, MSB first), oversampled in the core
 * clock domain.  SCK must be at most clk/16.
 *
 *   byte 0      : command  [7:6] 00 WREG, 01 RREG, 10 WMEM, 11 RMEM; [5] no auto-increment
 *   REG         : byte 1 = register address, then data bytes
 *   MEM         : byte 1 = addr[11:8], byte 2 = addr[7:0] (byte address,
 *                 word = addr[11:3], byte 0 = bits 63:56), then data bytes
 *
 * Read data for byte n is shifted out during byte n+1.  Side effects of a
 * register read (RX FIFO pop) are committed only when the host clocks the
 * first bit of the byte carrying that data, so the final prefetch at the
 * end of a transaction never loses a byte.
 * SPDX-License-Identifier: MIT
 */
`default_nettype none

module setl_host (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sck,       // already synchronised
    input  wire        mosi,      // already synchronised
    input  wire        csn,       // already synchronised
    output wire        miso,
    // register port
    output reg         reg_we,
    output reg  [7:0]  reg_waddr,
    output reg  [7:0]  reg_wdata,
    output wire [7:0]  reg_raddr,
    input  wire [7:0]  reg_rdata,
    input  wire        reg_rside,  // reading reg_raddr has a side effect
    output reg         reg_commit, // commit the side effect of ...
    output reg  [7:0]  reg_caddr,  // ... this register
    // memory port
    output reg         mem_req,
    output reg         mem_we,
    output reg  [11:0] mem_baddr,
    output reg  [7:0]  mem_wbyte,
    input  wire        mem_gnt,
    input  wire        mem_rvalid,
    input  wire [63:0] mem_rdata
);
    reg       sck_d;
    reg [2:0] bitcnt;
    reg [6:0] rx_sh;
    reg [7:0] tx_sh;
    reg [7:0] resp;
    reg [1:0] bidx;
    reg [7:0] cmd;
    reg [11:0] addr;
    reg       pend_side;
    reg [7:0] side_addr;
    reg       rd_wait;      // waiting for memory read data
    reg [2:0] rd_byte;

    wire rise = sck & ~sck_d;
    wire fall = ~sck & sck_d;
    wire [7:0] b = {rx_sh, mosi};
    wire byte_done = rise & (bitcnt == 3'd7);
    wire noinc = cmd[5];
    wire [1:0] op = cmd[7:6];

    assign miso = tx_sh[7];
    assign reg_raddr = (bidx == 2'd1) ? b : addr[7:0];

    wire [63:0] rsh = mem_rdata << (8 * rd_byte);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_d <= 1'b0; bitcnt <= 3'd0; rx_sh <= 7'd0; tx_sh <= 8'd0; resp <= 8'd0;
            bidx <= 2'd0; cmd <= 8'd0; addr <= 12'd0; pend_side <= 1'b0; side_addr <= 8'd0;
            reg_we <= 1'b0; reg_waddr <= 8'd0; reg_wdata <= 8'd0; reg_commit <= 1'b0; reg_caddr <= 8'd0;
            mem_req <= 1'b0; mem_we <= 1'b0; mem_baddr <= 12'd0; mem_wbyte <= 8'd0;
            rd_wait <= 1'b0; rd_byte <= 3'd0;
        end else begin
            sck_d <= sck;
            reg_we <= 1'b0;
            reg_commit <= 1'b0;
            if (mem_gnt) mem_req <= 1'b0;
            if (mem_rvalid && rd_wait) begin
                resp <= rsh[63:56];
                rd_wait <= 1'b0;
            end
            if (csn) begin
                bitcnt <= 3'd0; bidx <= 2'd0; pend_side <= 1'b0; tx_sh <= 8'd0;
            end else begin
                if (fall) tx_sh <= (bitcnt == 3'd0) ? resp : {tx_sh[6:0], 1'b0};
                if (rise) begin
                    rx_sh <= b[6:0];
                    bitcnt <= bitcnt + 3'd1;
                    if (bitcnt == 3'd0 && pend_side) begin
                        reg_commit <= 1'b1; reg_caddr <= side_addr; pend_side <= 1'b0;
                    end
                end
                if (byte_done) begin
                    if (bidx != 2'd3) bidx <= bidx + 2'd1;
                    case (bidx)
                        2'd0: cmd <= b;
                        2'd1: begin
                            if (op[1] == 1'b0) begin           // register op: address byte
                                if (op[0]) begin               // RREG: fetch first value
                                    resp <= reg_rdata; pend_side <= reg_rside; side_addr <= b;
                                    addr <= {4'd0, b + {7'd0, ~noinc}};
                                end else
                                    addr <= {4'd0, b};
                            end else
                                addr[11:8] <= b[3:0];
                        end
                        default: begin
                            if (op == 2'b00) begin             // WREG data
                                reg_we <= 1'b1; reg_waddr <= addr[7:0]; reg_wdata <= b;
                                if (!noinc) addr <= addr + 12'd1;
                            end else if (op == 2'b01) begin    // RREG next value
                                resp <= reg_rdata; pend_side <= reg_rside; side_addr <= addr[7:0];
                                if (!noinc) addr <= addr + 12'd1;
                            end else if (op == 2'b10 && bidx == 2'd2) begin
                                addr[7:0] <= b;                // WMEM address low
                            end else if (op == 2'b10) begin    // WMEM data
                                mem_req <= 1'b1; mem_we <= 1'b1; mem_baddr <= addr; mem_wbyte <= b;
                                addr <= addr + 12'd1;
                            end else begin                     // RMEM: addr low or next byte
                                mem_req <= 1'b1; mem_we <= 1'b0; rd_wait <= 1'b1;
                                if (bidx == 2'd2) begin
                                    mem_baddr <= {addr[11:8], b}; rd_byte <= b[2:0];
                                    addr <= {addr[11:8], b} + 12'd1;
                                end else begin
                                    mem_baddr <= addr; rd_byte <= addr[2:0];
                                    addr <= addr + 12'd1;
                                end
                            end
                        end
                    endcase
                end
            end
        end
    end
endmodule
