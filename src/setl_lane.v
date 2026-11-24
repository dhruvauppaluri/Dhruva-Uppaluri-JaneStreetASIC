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
    output wire [7:0]  cnt_o
);
    reg [63:0] rec;
    reg [8:0]  pc;
    reg        valid, pending, first, last;
    reg [15:0] timer;
    reg [7:0]  cnt, sr, dcnt;

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
    wire [7:0] sr0 = do_pop ? tx_head :
                     (act & (f_fifo == 2'd3)) ? f_imm[7:0] : sr;
    wire outbit = cfg_msb ? sr0[7] : sr0[0];
    wire [7:0] shifted = cfg_msb ? {sr0[6:0], cur} : {cur, sr0[7:1]};
    assign sr_n = (act & f_sh) ? shifted : sr0;

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
        3'b000,                       // 15..13 reserved
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
            slot_val <= 4'hF; flag <= 1'b0;
        end else if (start) begin
            pc <= cfg_start; valid <= 1'b0; pending <= 1'b0; first <= 1'b0; last <= 1'b0;
            timer <= 16'd0; cnt <= 8'd0; sr <= 8'd0; dcnt <= 8'd0;
            slot_val <= cfg_outinit; flag <= 1'b0;
        end else begin
            if (rd_me & pending) begin
                valid <= 1'b1; pending <= 1'b0; first <= 1'b1;
            end
            if (init_fetch) pending <= 1'b1;
            if (eligible) dcnt <= (dcnt == 8'd0) ? cfg_div : dcnt - 8'd1;
            if (tick) begin
                sr <= sr_n; cnt <= cnt_n; timer <= timer_n;
                slot_val <= slot_n; flag <= flag_n; last <= cur;
                if (w_ok) begin
                    if (refetch) begin
                        first <= 1'b0; valid <= 1'b0; pending <= 1'b1; pc <= nxt;
                    end else
                        first <= 1'b1;
                end else
                    first <= 1'b0;
            end
        end
    end

    // record register has no reset (always loaded before use)
    always @(posedge clk)
        if (rd_me & pending) rec <= rd_data;

endmodule
