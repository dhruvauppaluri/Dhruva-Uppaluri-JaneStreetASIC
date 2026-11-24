/*
 * SETL lane: executes one 64-bit state record at a time.
 * Mirrors tools/setl/model.py (Chip._tick); that file is the specification.
 * SPDX-License-Identifier: MIT
 */
`default_nettype none

module setl_lane #(
    parameter IDX = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,       // run 0->1: restart at cfg_start
    input  wire        run,
    input  wire        slot_me,     // this cycle belongs to this lane
    input  wire [31:0] in_vec,
    input  wire        hflag,
    // configuration
    input  wire        cfg_msb,
    input  wire [7:1]  cfg_ctrl,      // [1] crc en, [2] crc bit = input, [3] crc left, [7:4] ones run
    input  wire [15:0] cfg_poly,
    input  wire [15:0] cfg_crc_init,
    input  wire [15:0] cfg_crc_res,
    input  wire        host_crc_we_lo,
    input  wire        host_crc_we_hi,
    output wire [15:0] crc_o,
    input  wire [8:0]  cfg_start,
    input  wire [7:0]  cfg_div,
    input  wire [15:0] cfg_ta,
    input  wire [15:0] cfg_tb,
    input  wire [7:0]  cfg_match,
    input  wire [7:0]  cfg_mask,
    input  wire [3:0]  cfg_outinit,
    // record memory
    output wire        fetch_req,
    output wire [8:0]  fetch_addr,
    input  wire        rd_me,
    input  wire [63:0] rd_data,
    // host side of the FIFOs
    input  wire        host_push,
    input  wire [7:0]  host_wdata,
    input  wire        host_pop,
    input  wire        host_oinit_we,   // OUTINIT written: a stopped lane takes it at once
    output wire [7:0]  rx_head,
    output wire [2:0]  tx_level,
    output wire [2:0]  rx_level,
    // results
    output reg  [3:0]  slot_val,
    output reg         flag,
    output wire        event_set,
    output wire        ovf_set,
    output wire [8:0]  pc_o,
    output wire [7:0]  sr_o,
    output wire [7:0]  cnt_o,
    // timing learning: the lane writes its own TA / TB from the stopwatch
    output wire        ta_we,
    output wire        tb_we,
    output wire [15:0] t_wdata
);
    reg [63:0] rec;
    reg [8:0]  pc;
    reg        valid, pending, first, last;
    reg [15:0] timer;
    reg [7:0]  cnt, sr, dcnt;
    reg [15:0] sw;          // stopwatch: lane ticks, saturating
    reg [15:0] crc;
    reg [3:0]  ones;
    reg        crc_hold;    // set by crc nlo/nhi, cleared by crc clr
    reg        run_bit;     // polarity of the current run (CTRL[7] mode)
    assign crc_o = crc;

    assign pc_o  = pc;
    assign sr_o  = sr;
    assign cnt_o = cnt;

    // ---- record fields (see tools/setl/isa.py) ----
    wire [8:0] f_t1    = rec[63:55];
    wire [8:0] f_t0    = rec[54:46];
    wire       f_winv  = rec[45];
    wire [3:0] f_wsel  = rec[44:41];
    wire       f_binv  = rec[40];
    wire [3:0] f_bsel  = rec[39:36];
    wire [4:0] f_isel  = rec[35:31];
    wire [3:0] f_omask = rec[30:27];
    wire [3:0] f_oval  = rec[26:23];
    wire       f_souten= rec[22];
    wire [1:0] f_sout  = rec[21:20];
    wire       f_sh    = rec[19];
    wire [1:0] f_fifo  = rec[18:17];
    wire [1:0] f_cnt   = rec[16:15];
    wire [1:0] f_tmr   = rec[14:13];
    wire [1:0] f_flag  = rec[12:11];
    wire [1:0] f_xop   = rec[10:9];
    wire [8:0] f_imm   = rec[8:0];

    // ---- FIFOs ----
    wire [7:0] tx_head;
    wire       lane_pop, lane_push;
    wire [7:0] sr_n;

    setl_fifo txf (
        .clk(clk), .rst_n(rst_n),
        .push(host_push), .wdata(host_wdata), .pop(lane_pop),
        .head(tx_head), .level(tx_level)
    );
    setl_fifo rxf (
        .clk(clk), .rst_n(rst_n),
        .push(lane_push), .wdata(sr_n), .pop(host_pop),
        .head(rx_head), .level(rx_level)
    );

    // ---- tick qualification ----
    wire eligible = slot_me & run & valid & ~pending;
    wire tick     = eligible & (dcnt == 8'd0);
    wire act      = first;

    wire cur = in_vec[f_isel];

    // SR pipeline: load -> out bit -> shift
    wire tx_avail = (tx_level != 3'd0);
    wire do_pop   = act & (f_fifo == 2'd1) & tx_avail;
    wire push_req = act & (f_fifo == 2'd2);
    wire push_ok  = push_req & (rx_level != 3'd4);
    wire ld      = act & (f_fifo == 2'd3);
    wire special = ld & f_imm[8];
    wire [7:0] sr0 = do_pop ? tx_head :
                     (ld & ~special) ? f_imm[7:0] :
                     (special & (f_imm[2:0] == 3'd0)) ? crc[7:0] :
                     (special & (f_imm[2:0] == 3'd1)) ? crc[15:8] :
                     (special & (f_imm[2:0] == 3'd4)) ? ~crc[7:0] :
                     (special & (f_imm[2:0] == 3'd5)) ? ~crc[15:8] : sr;
    wire outbit = cfg_msb ? sr0[7] : sr0[0];
    wire [7:0] shifted = cfg_msb ? {sr0[6:0], cur} : {cur, sr0[7:1]};
    assign sr_n = (act & f_sh) ? shifted : sr0;

    // ---- CRC / ones-run assist ----
    wire        crc_b    = cfg_ctrl[2] ? cur : outbit;
    wire        did_sh   = act & f_sh;
    wire [15:0] crc_pre  = (special & (f_imm[2:0] == 3'd2)) ? cfg_crc_init : crc;
    wire        hold_n   = (special & (f_imm[2:0] == 3'd2)) ? 1'b0 :
                           (special & ((f_imm[2:0] == 3'd4) | (f_imm[2:0] == 3'd5))) ? 1'b1 : crc_hold;
    wire        fb_r     = crc_pre[0] ^ crc_b;
    wire        fb_l     = crc_pre[15] ^ crc_b;
    wire [15:0] crc_upd  = cfg_ctrl[3] ? ({crc_pre[14:0], 1'b0} ^ (fb_l ? cfg_poly : 16'd0))
                                       : ({1'b0, crc_pre[15:1]} ^ (fb_r ? cfg_poly : 16'd0));
    wire [15:0] crc_n    = (did_sh & cfg_ctrl[1] & ~hold_n) ? crc_upd : crc_pre;
    // run counter: `ones clr` accounts for an inserted stuff bit of opposite polarity
    wire [2:0]  runlen   = cfg_ctrl[6:4];
    wire        any_pol  = cfg_ctrl[7];
    wire        clr_run  = special & (f_imm[2:0] == 3'd3);
    wire [3:0]  ones_pre = clr_run ? {3'd0, any_pol} : ones;
    wire        rb_pre   = clr_run ? ~run_bit : run_bit;
    wire [3:0]  ones_inc = (ones_pre == 4'd15) ? 4'd15 : ones_pre + 4'd1;
    wire        new_run  = (ones_pre == 4'd0) | (crc_b != rb_pre);
    wire [3:0]  ones_n   = !(did_sh && runlen != 3'd0) ? ones_pre :
                           any_pol ? (new_run ? 4'd1 : ones_inc) :
                           (crc_b ? ones_inc : 4'd0);
    wire        rb_n     = (did_sh && runlen != 3'd0 && any_pol && new_run) ? crc_b : rb_pre;
    wire c_crcok = (crc_n == cfg_crc_res);
    wire c_ones  = (runlen != 3'd0) && (ones_n == {1'b0, runlen});

    assign lane_pop  = tick & do_pop;
    assign lane_push = tick & push_ok;
    assign ovf_set   = tick & push_req & ~push_ok;
    assign event_set = tick & act & (f_flag == 2'd3);

    reg [7:0] cnt_n;
    always @(*) begin
        cnt_n = cnt;
        if (act) case (f_cnt)
            2'd1: cnt_n = cnt - 8'd1;
            2'd2: cnt_n = f_imm[7:0];
            2'd3: cnt_n = cnt + 8'd1;
            default: cnt_n = cnt;
        endcase
    end

    reg [15:0] timer_n;
    always @(*) begin
        if (act && f_tmr != 2'd0)
            timer_n = (f_tmr == 2'd1) ? cfg_ta : (f_tmr == 2'd2) ? cfg_tb : {7'd0, f_imm};
        else
            timer_n = (timer != 16'd0) ? timer - 16'd1 : 16'd0;
    end

    reg [3:0] slot_n;
    always @(*) begin
        slot_n = slot_val;
        if (act) begin
            slot_n = (slot_val & ~f_omask) | (f_oval & f_omask);
            if (f_souten) slot_n[f_sout] = outbit;
        end
    end

    wire flag_n = (act && f_flag == 2'd1) ? 1'b1 :
                  (act && f_flag == 2'd2) ? 1'b0 : flag;

    // ---- stopwatch / timing learning ----
    wire [15:0] sw_n = (act && f_xop == 2'd1) ? 16'd0 :
                       (sw == 16'hFFFF) ? sw : sw + 16'd1;
    assign ta_we   = tick & act & (f_xop == 2'd2);
    assign tb_we   = tick & act & (f_xop == 2'd3);
    assign t_wdata = (f_xop == 2'd2) ? sw : sw + {1'b0, sw[15:1]};

    // ---- conditions (post-action values) ----
    wire c_timer0 = (timer_n == 16'd0);
    wire c_cnt0   = (cnt_n == 8'd0);
    wire c_txrdy  = ((tx_level - {2'd0, do_pop}) != 3'd0);
    wire c_rxfull = ((rx_level + {2'd0, push_ok}) == 3'd4);
    wire c_rise   = ~first & ~last & cur;
    wire c_fall   = ~first & last & ~cur;
    wire c_match  = (((sr_n ^ cfg_match) & cfg_mask) == 8'd0);
    wire c_bit    = cfg_msb ? sr_n[7] : sr_n[0];

    wire [15:0] conds = {
        1'b0,                         // 15 reserved
        c_ones,                       // 14
        c_crcok,                      // 13
        hflag,                        // 12
        c_bit,                        // 11
        c_match,                      // 10
        c_rise | c_fall | c_timer0,   // 9
        c_rise | c_fall,              // 8
        c_fall,                       // 7
        c_rise,                       // 6
        cur,                          // 5
        c_rxfull,                     // 4
        c_txrdy,                      // 3
        c_cnt0,                       // 2
        c_timer0,                     // 1
        1'b1                          // 0
    };
    wire w_ok   = conds[f_wsel] ^ f_winv;
    wire br     = conds[f_bsel] ^ f_binv;
    wire [8:0] nxt = br ? f_t1 : f_t0;
    wire leave  = tick & w_ok;
    wire refetch = leave & (nxt != pc);

    wire init_fetch = slot_me & run & ~valid & ~pending;
    assign fetch_req  = init_fetch | refetch;
    assign fetch_addr = refetch ? nxt : pc;

    // ---- state ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 9'd0; valid <= 1'b0; pending <= 1'b0; first <= 1'b0; last <= 1'b0;
            timer <= 16'd0; cnt <= 8'd0; sr <= 8'd0; dcnt <= 8'd0;
            slot_val <= 4'hF; flag <= 1'b0; sw <= 16'd0; crc <= 16'd0; ones <= 4'd0;
            crc_hold <= 1'b0; run_bit <= 1'b0;
        end else if (start) begin
            pc <= cfg_start; valid <= 1'b0; pending <= 1'b0; first <= 1'b0; last <= 1'b0;
            timer <= 16'd0; cnt <= 8'd0; sr <= 8'd0; dcnt <= 8'd0;
            slot_val <= cfg_outinit; flag <= 1'b0; sw <= 16'd0; ones <= 4'd0;
            crc_hold <= 1'b0; run_bit <= 1'b0;
        end else begin
            if (host_oinit_we & ~run) slot_val <= host_wdata[3:0];
            if (rd_me & pending) begin
                valid <= 1'b1; pending <= 1'b0; first <= 1'b1;
            end
            if (init_fetch) pending <= 1'b1;
            if (eligible) dcnt <= (dcnt == 8'd0) ? cfg_div : dcnt - 8'd1;
            if (tick) begin
                sr <= sr_n; cnt <= cnt_n; timer <= timer_n;
                slot_val <= slot_n; flag <= flag_n; last <= cur; sw <= sw_n;
                crc <= crc_n; ones <= ones_n; crc_hold <= hold_n; run_bit <= rb_n;
                if (w_ok) begin
                    if (refetch) begin
                        first <= 1'b0; valid <= 1'b0; pending <= 1'b1; pc <= nxt;
                    end else
                        first <= 1'b1;
                end else
                    first <= 1'b0;
            end
            if (host_crc_we_lo) crc[7:0]  <= host_wdata;
            if (host_crc_we_hi) crc[15:8] <= host_wdata;
        end
    end

    // record register has no reset (always loaded before use)
    always @(posedge clk)
        if (rd_me & pending) rec <= rd_data;

`ifdef FORMAL
    // Determinism of the barrel: a lane never owns its slot while it is still
    // waiting for record data, so it never has to stall.
    always @(*) if (rst_n) assert(!(slot_me && pending));
`endif
endmodule
