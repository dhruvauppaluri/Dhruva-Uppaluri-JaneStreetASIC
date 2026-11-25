/*
 * SETL -- Sparse Event-Transition Lanes
 * A post-fabrication reprogrammable protocol emulator for Tiny Tapeout / IHP SG13CMOS5L.
 *
 * Pins
 *   ui[7] host SCK, ui[6] host MOSI, ui[5] host CS_n, uo[7] host MISO
 *   all other pins belong to the lanes (outputs through OMAP registers,
 *   inputs through the per-state ISEL field)
 *
 * SPDX-License-Identifier: MIT
 */
`default_nettype none

module tt_um_dhruvauppaluri_setl (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    localparam NL = 4;

    // ------------------------------------------------------------ sync
    reg [15:0] s1, s2;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin s1 <= 16'd0; s2 <= 16'd0; end
        else begin s1 <= {uio_in, ui_in}; s2 <= s1; end

    // ------------------------------------------------------- globals
    reg        mode4;
    reg [3:0]  run;
    reg [3:0]  hflag;
    reg [1:0]  slot;
    reg [3:0]  ev, ovf;

    // per-lane configuration
    reg  [7:0] c_ctrl  [0:NL-1];
    reg [15:0] c_poly  [0:NL-1];
    reg [15:0] c_cinit [0:NL-1];
    reg [15:0] c_cres  [0:NL-1];
    reg [8:0]  c_start [0:NL-1];
    reg [7:0]  c_div   [0:NL-1];
    reg [15:0] c_ta    [0:NL-1];
    reg [15:0] c_tb    [0:NL-1];
    reg [7:0]  c_omap  [0:4*NL-1];
    reg [3:0]  c_oinit [0:NL-1];
    reg [7:0]  c_match [0:NL-1];
    reg [7:0]  c_mask  [0:NL-1];

    // ------------------------------------------------------- host
    wire       reg_we, reg_commit, reg_rside;
    wire [7:0] reg_waddr, reg_wdata, reg_raddr, reg_caddr;
    reg  [7:0] reg_rdata;
    wire       hmem_req, hmem_we;
    wire [11:0] hmem_baddr;
    wire [7:0] hmem_wbyte;
    wire       hmem_gnt;
    reg        hmem_rvalid;
    wire       miso;
    wire       hmem_lost, hrd_late;
    wire [63:0] mem_rdata;

    setl_host host (
        .clk(clk), .rst_n(rst_n),
        .sck(s2[7]), .mosi(s2[6]), .csn(s2[5]), .miso(miso),
        .reg_we(reg_we), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata),
        .reg_raddr(reg_raddr), .reg_rdata(reg_rdata), .reg_rside(reg_rside),
        .reg_commit(reg_commit), .reg_caddr(reg_caddr),
        .mem_req(hmem_req), .mem_we(hmem_we), .mem_baddr(hmem_baddr), .mem_wbyte(hmem_wbyte),
        .mem_gnt(hmem_gnt), .mem_rvalid(hmem_rvalid), .mem_rdata(mem_rdata),
        .mem_lost(hmem_lost), .rd_late(hrd_late)
    );
    reg [1:0] hosterr;      // sticky: [0] a memory write/read request was lost, [1] read data late

    // ------------------------------------------------------- lanes
    wire [4*NL-1:0] slot_val_v;
    wire [NL-1:0] flag, ev_set, ovf_set, fetch_req;
    wire [9*NL-1:0] fetch_addr_v, pc_v;
    wire [8*NL-1:0] rx_head_v, sr_v, cnt_v;
    wire [5*NL-1:0] tx_level_v, rx_level_v;
    wire [NL-1:0] ta_we, tb_we;
    wire [16*NL-1:0] crc_v;
    wire [16*NL-1:0] t_wdata_v;
    wire [6:0]  uo_int;
    // the chip's own outputs are read back one clock late: registering them
    // takes the pin router off the lane's critical path
    reg  [6:0]  uo_q;            // registered pins: uo is also read back into the lanes
    reg  [7:0]  uio_q, oe_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            uo_q <= 7'd0; uio_q <= 8'd0; oe_q <= 8'd0;
        end else begin
            uo_q <= uo_int; uio_q <= uio_o; oe_q <= uio_e;
        end
    wire [31:0] in_vec = {1'b1, 3'b000, flag, 1'b0, uo_q, s2};

    reg         rd_valid;
    reg  [1:0]  rd_lane;
    wire [3:0]  start = (reg_we && reg_waddr == 8'h81) ? (reg_wdata[3:0] & ~run) : 4'd0;

    genvar i;
    generate
        for (i = 0; i < NL; i = i + 1) begin : g_lane
            wire slot_me = (slot == i) && (mode4 || i < 2);
            setl_lane #(.IDX(i)) lane (
                .clk(clk), .rst_n(rst_n),
                .start(start[i]), .run(run[i]), .slot_me(slot_me),
                .in_vec(in_vec), .hflag(hflag[i]),
                .cfg_msb(c_ctrl[i][0]), .cfg_ctrl(c_ctrl[i][7:1]),
                .cfg_poly(c_poly[i]), .cfg_crc_init(c_cinit[i]), .cfg_crc_res(c_cres[i]),
                .host_crc_we_lo(reg_we && reg_waddr == (8'hA6 + 8 * i)),
                .host_crc_we_hi(reg_we && reg_waddr == (8'hA7 + 8 * i)),
                .crc_o(crc_v[16*i +: 16]),
                .cfg_start(c_start[i]), .cfg_div(c_div[i]),
                .cfg_ta(c_ta[i]), .cfg_tb(c_tb[i]), .cfg_match(c_match[i]), .cfg_mask(c_mask[i]),
                .cfg_outinit(c_oinit[i]),
                .fetch_req(fetch_req[i]), .fetch_addr(fetch_addr_v[9*i +: 9]),
                .rd_me(rd_valid && rd_lane == i), .rd_data(mem_rdata),
                .host_push(reg_we && reg_waddr == (i * 16 + 15)), .host_wdata(reg_wdata),
                .host_pop(reg_commit && reg_caddr == (i * 16 + 15)),
                .host_oinit_we(reg_we && reg_waddr == (i * 16 + 12)),
                .rx_head(rx_head_v[8*i +: 8]), .tx_level(tx_level_v[5*i +: 5]),
                .rx_level(rx_level_v[5*i +: 5]),
                .slot_val(slot_val_v[4*i +: 4]), .flag(flag[i]),
                .event_set(ev_set[i]), .ovf_set(ovf_set[i]),
                .pc_o(pc_v[9*i +: 9]), .sr_o(sr_v[8*i +: 8]), .cnt_o(cnt_v[8*i +: 8]),
                .ta_we(ta_we[i]), .tb_we(tb_we[i]), .t_wdata(t_wdata_v[16*i +: 16])
            );
        end
    endgenerate

    // ------------------------------------------------------- memory
    wire        lane_req = |fetch_req;
    wire [8:0]  lane_addr = fetch_addr_v[9*slot +: 9];
    assign hmem_gnt = hmem_req & ~lane_req;
    wire        mem_en = lane_req | hmem_gnt;
    wire        mem_we = ~lane_req & hmem_we;
    wire [8:0]  mem_addr = lane_req ? lane_addr : hmem_baddr[11:3];
    wire [5:0]  bsh = {3'd7 - hmem_baddr[2:0], 3'd0};
    wire [63:0] mem_wdata = {56'd0, hmem_wbyte} << bsh;
    wire [63:0] mem_bmask = {56'd0, 8'hFF} << bsh;

    setl_mem mem (
        .clk(clk), .en(mem_en), .we(mem_we), .addr(mem_addr),
        .wdata(mem_wdata), .bmask(mem_bmask), .rdata(mem_rdata)
    );

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            rd_valid <= 1'b0; rd_lane <= 2'd0; hmem_rvalid <= 1'b0;
        end else begin
            rd_valid <= lane_req;
            rd_lane <= slot;
            hmem_rvalid <= hmem_gnt & ~hmem_we;
        end

    // ------------------------------------------------------- registers
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode4 <= 1'b0; run <= 4'd0; hflag <= 4'd0; slot <= 2'd0; hosterr <= 2'd0;
            ev <= 4'd0; ovf <= 4'd0;
            for (k = 0; k < NL; k = k + 1) begin
                c_ctrl[k] <= 8'd0; c_start[k] <= 9'd0; c_div[k] <= 8'd0;
                c_poly[k] <= 16'd0; c_cinit[k] <= 16'd0; c_cres[k] <= 16'd0;
                c_ta[k] <= 16'd0; c_tb[k] <= 16'd0; c_oinit[k] <= 4'hF;
                c_match[k] <= 8'd0; c_mask[k] <= 8'd0;
            end
            for (k = 0; k < 4 * NL; k = k + 1) c_omap[k] <= 8'h1F;
        end else begin
            slot <= mode4 ? slot + 2'd1 : {1'b0, ~slot[0]};
            ev  <= ev | ev_set;
            hosterr <= hosterr | {hrd_late, hmem_lost};
            ovf <= ovf | ovf_set;
            if (reg_we) begin
                if (reg_waddr < 8'h40) begin
                    case (reg_waddr[3:0])
                        4'h0: c_ctrl[reg_waddr[5:4]] <= reg_wdata;
                        4'h1: c_start[reg_waddr[5:4]][7:0] <= reg_wdata;
                        4'h2: c_start[reg_waddr[5:4]][8] <= reg_wdata[0];
                        4'h3: c_div[reg_waddr[5:4]] <= reg_wdata;
                        4'h4: c_ta[reg_waddr[5:4]][7:0] <= reg_wdata;
                        4'h5: c_ta[reg_waddr[5:4]][15:8] <= reg_wdata;
                        4'h6: c_tb[reg_waddr[5:4]][7:0] <= reg_wdata;
                        4'h7: c_tb[reg_waddr[5:4]][15:8] <= reg_wdata;
                        4'h8, 4'h9, 4'hA, 4'hB:
                              c_omap[{reg_waddr[5:4], reg_waddr[1:0]}] <= reg_wdata;
                        4'hC: c_oinit[reg_waddr[5:4]] <= reg_wdata[3:0];
                        4'hD: c_match[reg_waddr[5:4]] <= reg_wdata;
                        4'hE: c_mask[reg_waddr[5:4]] <= reg_wdata;
                        default: ;  // 4'hF: TX FIFO push (inside the lane)
                    endcase
                end else begin
                    case (reg_waddr)
                        8'h80: mode4 <= reg_wdata[0];
                        8'h81: run <= reg_wdata[3:0];
                        8'h85: hflag <= reg_wdata[3:0];
                        8'h86: hosterr <= (hosterr & ~reg_wdata[1:0]) | {hrd_late, hmem_lost};
                        8'hA0, 8'hA8, 8'hB0, 8'hB8: c_poly[reg_waddr[4:3]][7:0]   <= reg_wdata;
                        8'hA1, 8'hA9, 8'hB1, 8'hB9: c_poly[reg_waddr[4:3]][15:8]  <= reg_wdata;
                        8'hA2, 8'hAA, 8'hB2, 8'hBA: c_cinit[reg_waddr[4:3]][7:0]  <= reg_wdata;
                        8'hA3, 8'hAB, 8'hB3, 8'hBB: c_cinit[reg_waddr[4:3]][15:8] <= reg_wdata;
                        8'hA4, 8'hAC, 8'hB4, 8'hBC: c_cres[reg_waddr[4:3]][7:0]   <= reg_wdata;
                        8'hA5, 8'hAD, 8'hB5, 8'hBD: c_cres[reg_waddr[4:3]][15:8]  <= reg_wdata;
                        8'h88, 8'h89, 8'h8A, 8'h8B: begin
                            if (reg_wdata[6]) ev[reg_waddr[1:0]] <= ev_set[reg_waddr[1:0]];
                            if (reg_wdata[7]) ovf[reg_waddr[1:0]] <= ovf_set[reg_waddr[1:0]];
                        end
                        default: ;
                    endcase
                end
            end
            for (k = 0; k < NL; k = k + 1) begin
                if (ta_we[k]) c_ta[k] <= t_wdata_v[16*k +: 16];
                if (tb_we[k]) c_tb[k] <= t_wdata_v[16*k +: 16];
            end
        end
    end

    function [2:0] sat7;
        input [4:0] lv;
        sat7 = (lv > 5'd7) ? 3'd7 : lv[2:0];
    endfunction

    // register read mux
    wire [1:0] rl = reg_raddr[5:4];
    wire [1:0] gl = reg_raddr[1:0];
    assign reg_rside = (reg_raddr < 8'h40) && (reg_raddr[3:0] == 4'hF) && (rx_level_v[5*rl +: 5] != 5'd0);
    always @(*) begin
        reg_rdata = 8'h00;
        if (reg_raddr < 8'h40) begin
            case (reg_raddr[3:0])
                4'h0: reg_rdata = c_ctrl[rl];
                4'h1: reg_rdata = c_start[rl][7:0];
                4'h2: reg_rdata = {7'd0, c_start[rl][8]};
                4'h3: reg_rdata = c_div[rl];
                4'h4: reg_rdata = c_ta[rl][7:0];
                4'h5: reg_rdata = c_ta[rl][15:8];
                4'h6: reg_rdata = c_tb[rl][7:0];
                4'h7: reg_rdata = c_tb[rl][15:8];
                4'h8, 4'h9, 4'hA, 4'hB: reg_rdata = c_omap[{rl, reg_raddr[1:0]}];
                4'hC: reg_rdata = {4'd0, c_oinit[rl]};
                4'hD: reg_rdata = c_match[rl];
                4'hE: reg_rdata = c_mask[rl];
                4'hF: reg_rdata = (rx_level_v[5*rl +: 5] != 5'd0) ? rx_head_v[8*rl +: 8] : 8'h00;
            endcase
        end else begin
            case (reg_raddr)
                8'h80: reg_rdata = {7'd0, mode4};
                8'h81: reg_rdata = {4'd0, run};
                8'h82: reg_rdata = 8'h5E;
                8'h83: reg_rdata = 8'h01;
                8'h84: reg_rdata = {flag, ev};
                8'h85: reg_rdata = {4'd0, hflag};
                8'h86: reg_rdata = {5'd0, hmem_req, hosterr};   // [2] live: request still waiting
                8'h88, 8'h89, 8'h8A, 8'h8B:
                       reg_rdata = {ovf[gl], ev[gl], sat7(rx_level_v[5*gl +: 5]), sat7(tx_level_v[5*gl +: 5])};
                8'hC0, 8'hC2, 8'hC4, 8'hC6:
                       reg_rdata = {ovf[reg_raddr[2:1]], ev[reg_raddr[2:1]], 1'b0, tx_level_v[5*reg_raddr[2:1] +: 5]};
                8'hC1, 8'hC3, 8'hC5, 8'hC7:
                       reg_rdata = {3'd0, rx_level_v[5*reg_raddr[2:1] +: 5]};
                8'h8C, 8'h8D, 8'h8E, 8'h8F: reg_rdata = pc_v[9*gl +: 8];
                8'h90, 8'h91, 8'h92, 8'h93: reg_rdata = sr_v[8*gl +: 8];
                8'h94, 8'h95, 8'h96, 8'h97: reg_rdata = cnt_v[8*gl +: 8];
                8'h98: reg_rdata = {4'd0, pc_v[35], pc_v[26], pc_v[17], pc_v[8]};
                8'hA0, 8'hA8, 8'hB0, 8'hB8: reg_rdata = c_poly[reg_raddr[4:3]][7:0];
                8'hA1, 8'hA9, 8'hB1, 8'hB9: reg_rdata = c_poly[reg_raddr[4:3]][15:8];
                8'hA2, 8'hAA, 8'hB2, 8'hBA: reg_rdata = c_cinit[reg_raddr[4:3]][7:0];
                8'hA3, 8'hAB, 8'hB3, 8'hBB: reg_rdata = c_cinit[reg_raddr[4:3]][15:8];
                8'hA4, 8'hAC, 8'hB4, 8'hBC: reg_rdata = c_cres[reg_raddr[4:3]][7:0];
                8'hA5, 8'hAD, 8'hB5, 8'hBD: reg_rdata = c_cres[reg_raddr[4:3]][15:8];
                8'hA6, 8'hAE, 8'hB6, 8'hBE: reg_rdata = crc_v[16*reg_raddr[4:3] +: 8];
                8'hA7, 8'hAF, 8'hB7, 8'hBF: reg_rdata = crc_v[16*reg_raddr[4:3] + 8 +: 8];
                default: reg_rdata = 8'h00;
            endcase
        end
    end

    // ------------------------------------------------------- pins
    reg [6:0] uo_r;
    reg [7:0] uio_o, uio_e;
    integer l, s;
    always @(*) begin
        uo_r = 7'd0; uio_o = 8'd0; uio_e = 8'd0;
        for (l = 0; l < NL; l = l + 1)
            for (s = 0; s < 4; s = s + 1) begin : pinmux
                reg [7:0] m;
                reg v;
                m = c_omap[l * 4 + s];
                v = slot_val_v[l * 4 + s] ^ m[6];
                if (m[4:0] <= 5'd6)
                    uo_r[m[2:0]] = uo_r[m[2:0]] | v;
                else if (m[4:3] == 2'b01) begin
                    if (m[7]) begin
                        // tri-state: the next slot of the same lane is the output enable
                        uio_o[m[2:0]] = uio_o[m[2:0]] | v;
                        uio_e[m[2:0]] = uio_e[m[2:0]] | slot_val_v[l * 4 + ((s + 1) % 4)];
                    end else if (m[5]) uio_e[m[2:0]] = uio_e[m[2:0]] | ~v;
                    else begin
                        uio_o[m[2:0]] = uio_o[m[2:0]] | v;
                        uio_e[m[2:0]] = 1'b1;
                    end
                end
            end
    end
    assign uo_int  = uo_r;
    // every lane output leaves the chip through a flip-flop: glitch-free pins and
    // no pin-router logic in the pad timing paths
    assign uo_out  = {miso, uo_q};
    assign uio_out = uio_q;
    assign uio_oe  = oe_q;

    wire _unused = &{ena, 1'b0};

`ifdef FORMAL
    // Barrel properties (formal/barrel.sby proves them for any program and any
    // host behaviour): at most one lane fetches per clock, and every fetch is
    // answered on the very next clock, to the lane that asked.
    reg f_past = 1'b0;
    reg [NL-1:0] f_req_q;
    always @(posedge clk) begin
        f_past <= 1'b1;
        f_req_q <= fetch_req;
    end
    always @(*) if (rst_n) assert((fetch_req & (fetch_req - 1'b1)) == 0);
    always @(posedge clk) if (f_past && rst_n && $past(rst_n) && f_req_q != 0) begin
        assert(rd_valid);
        assert(f_req_q[rd_lane]);
    end
`ifdef FORMAL_REACH
    // must FAIL: lane 3 gets a record in 4-lane mode (the proof is not vacuous)
    always @(*) assert(!(mode4 && rd_valid && rd_lane == 2'd3 && fetch_req == 0));
`endif
`endif
endmodule
