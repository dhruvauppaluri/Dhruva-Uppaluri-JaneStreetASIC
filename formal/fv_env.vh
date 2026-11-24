// Shared formal environment: one SETL lane (lane 0 of a 2-lane barrel) running
// a program from a ROM, with the record-memory timing of the real chip
// (fetch in the lane's slot, registered data one clock later).
// The including module provides: clk, setl_rom(), the S_* symbols, cfg_outinit and the
// cfg_* / in_vec / host_* signals before including this file.
    reg init = 1'b1;
    reg started = 1'b0;
    always @(posedge clk) begin
        init <= 1'b0;
        if (!init) started <= 1'b1;
    end
    wire rst_n = ~init;
    wire start = rst_n & ~started;
    reg  slot = 1'b0;
    always @(posedge clk) slot <= ~slot;

    wire        fetch_req;
    wire [8:0]  fetch_addr;
    reg         rd_me = 1'b0;
    reg  [63:0] q;
    always @(posedge clk) begin
        rd_me <= fetch_req;
        if (fetch_req) q <= setl_rom(fetch_addr);
    end

    wire [7:0] rx_head, sr_o, cnt_o;
    wire [4:0] tx_level, rx_level;
    wire [3:0] slot_val;
    wire [8:0] pc_o;
    wire       flag, event_set, ovf_set, ta_we, tb_we;
    wire [15:0] t_wdata;

    setl_lane lane (
        .clk(clk), .rst_n(rst_n), .start(start), .run(started), .slot_me(slot == 1'b0),
        .in_vec(in_vec), .hflag(1'b0),
        .cfg_msb(cfg_msb), .cfg_ctrl(7'd0), .cfg_poly(16'd0), .cfg_crc_init(16'd0), .cfg_crc_res(16'd0),
        .host_crc_we_lo(1'b0), .host_crc_we_hi(1'b0), .crc_o(),
        .cfg_start(cfg_start), .cfg_div(8'd0),
        .cfg_ta(cfg_ta), .cfg_tb(cfg_tb), .cfg_match(cfg_match), .cfg_mask(cfg_mask),
        .cfg_outinit(cfg_outinit),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .rd_me(rd_me), .rd_data(q),
        .host_push(host_push), .host_wdata(host_wdata), .host_pop(host_pop), .host_oinit_we(1'b0),
        .rx_head(rx_head), .tx_level(tx_level), .rx_level(rx_level),
        .slot_val(slot_val), .flag(flag), .event_set(event_set), .ovf_set(ovf_set),
        .pc_o(pc_o), .sr_o(sr_o), .cnt_o(cnt_o),
        .ta_we(ta_we), .tb_we(tb_we), .t_wdata(t_wdata)
    );

    // the host never overfills the TX FIFO (the driver checks the level) and
    // is quiet while the chip is in reset
    // the shadow below models four queued bytes: the proofs cover hosts that keep
    // at most four bytes in the (16-deep) TX FIFO
    always @(*) assume(!(host_push && tx_level >= 5'd4));
    always @(*) if (init) assume(!host_push && !host_pop);

    // Shadow of the TX FIFO, one clock behind: pushes are seen from the host
    // inputs, pops are inferred from the level.  The shadow must always agree
    // with the real level, and `popped` is the byte the lane just took.
    reg  [4:0] p_lvl = 5'd0;
    reg        p_push = 1'b0;
    reg  [7:0] p_wd;
    reg  [7:0] sq0, sq1, sq2, sq3;
    reg  [2:0] scount = 3'd0;
    always @(posedge clk) begin
        p_lvl <= tx_level; p_push <= host_push; p_wd <= host_wdata;
    end
    wire did_pop = started && ({1'b0, p_lvl} + {5'd0, p_push} - {1'b0, tx_level} == 6'd1);
    wire [7:0] popped = sq0;
    always @(posedge clk) if (rst_n) begin
        if (did_pop) begin
            {sq0, sq1, sq2} <= {sq1, sq2, sq3};
            case (scount - 3'd1 + {2'd0, p_push})
                3'd1: if (p_push) sq0 <= p_wd;
                3'd2: if (p_push) sq1 <= p_wd;
                3'd3: if (p_push) sq2 <= p_wd;
                3'd4: if (p_push) sq3 <= p_wd;
                default: ;
            endcase
            scount <= scount - 3'd1 + {2'd0, p_push};
        end else if (p_push) begin
            case (scount)
                3'd0: sq0 <= p_wd;
                3'd1: sq1 <= p_wd;
                3'd2: sq2 <= p_wd;
                3'd3: sq3 <= p_wd;
                default: ;
            endcase
            scount <= scount + 3'd1;
        end
    end
    always @(posedge clk) if (started && $past(started)) assert({2'd0, scount} == p_lvl);   // shadow lags the FIFO by one clock
    // guard against harness wiring mistakes: the input vector constants are in place
    always @(*) assert(in_vec[31] && !in_vec[30]);
