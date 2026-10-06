`timescale 1ns/1ps
`default_nettype none

// Shared serial engine: tick, 1- or 2-bit shifter, NRZI+stuff or NRZ,
// CRC-16 or CRC-32, 64-byte packet RAM, TX and RX, pin overlay.
// Programmed by firmware through AOUT/AIN; not USB- or Ethernet-named IP.
//
//   0 W control   R status
//   1 W period    R CRC[15:8]
//   2 W push RAM  R pop RAM[rx_idx] (AIN increments rx_idx)
//   3 W CRC feed, or MODE if data[7:6]==2'b11
//     R CRC[7:0]
//
// Control: [0] TX_START [1] SOFT_RESET [2] STUFF [3] NRZI
//          [4] CRC_RESET [5] RX_START [6] SE0 [7] USB overlay
// Mode 0xC0|f: [0] width2 [1] crc32 [2] rmii [3] append_crc
//              [4] auto_eop [5] preamble
// Status: [0] busy [1] empty [2] full [3] se0
//         [4] rx_ready [5] crc_ok [6] overlay [7] tx_active
module serial_engine #(
    parameter integer RAM_BYTES = 64,
    parameter [2:0]   PIN_A     = 3'd0,
    parameter [2:0]   PIN_B     = 3'd1
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,
    input  wire       we,
    input  wire [1:0] wr_addr,
    input  wire [7:0] wr_data,
    input  wire [1:0] rd_addr,
    input  wire       rd_inc,
    output reg  [7:0] rd_data,
    input  wire [7:0] gpio_in,
    output reg  [7:0] assist_out,
    output reg  [7:0] assist_oe
);

localparam integer RAM_AW = $clog2(RAM_BYTES);
localparam [2:0] PH_PRE  = 3'd0;
localparam [2:0] PH_DATA = 3'd1;
localparam [2:0] PH_CRC  = 3'd2;
localparam [2:0] PH_EOP  = 3'd3;
localparam [2:0] PH_IFG  = 3'd4;

reg [7:0] period;
reg stuff_en, nrzi_en, force_se0, overlay_en;
reg width_2, crc32_en, rmii_en, append_crc, auto_eop, preamble_en;
reg tx_active, rx_active, rx_ready, crc_ok;
reg line, stuff_pending;
reg [2:0] ones_count;
reg [3:0] bits_left;
reg [7:0] shift;
reg [7:0] tick_count;
reg [31:0] crc;
reg [7:0] ram [0:RAM_BYTES-1];
reg [RAM_AW-1:0] wr_ptr, rd_ptr, rx_idx;
reg [RAM_AW:0] byte_count, sent_count;
reg txd0, txd1, tx_en;
reg [2:0] tx_phase;
reg [3:0] preamble_left;
reg [5:0] ifg_left;
reg [2:0] crc_bytes_left;
reg [31:8] crc_latched;
reg [1:0] eop_left;
reg rx_prev, rx_hunt, rx_aligned, rx_skip_stuff;
reg [7:0] rx_shift;
reg [3:0] rx_bits;
reg [1:0] rx_se0;
reg [7:0] sample_wait;

wire ram_empty = (byte_count == {(RAM_AW+1){1'b0}});
wire ram_full  = (byte_count == RAM_BYTES[RAM_AW:0]);
wire se0_now   = (gpio_in[PIN_A] == 1'b0) && (gpio_in[PIN_B] == 1'b0);
wire usb_line  = gpio_in[PIN_A];
wire overlay_usb  = overlay_en || (tx_active && !rmii_en) || force_se0;
wire overlay_rmii = rmii_en && (tx_active || overlay_en);
wire busy = tx_active || rx_active;
wire [15:0] crc16_wire = crc[15:0] ^ 16'hFFFF;
wire [31:0] crc32_wire = crc ^ 32'hFFFFFFFF;
wire start_tx   = we && (wr_addr == 2'd0) && wr_data[0] && !ram_empty;
wire soft_reset = we && (wr_addr == 2'd0) && wr_data[1];
wire crc_reset  = we && (wr_addr == 2'd0) && wr_data[4];
wire start_rx   = we && (wr_addr == 2'd0) && wr_data[5];
wire mode_wr    = we && (wr_addr == 2'd3) && (wr_data[7:6] == 2'b11);
wire [7:0] rx_dibit = {6'b00, gpio_in[6], gpio_in[5]};
wire [7:0] rx_byte_now = rx_shift | (rx_dibit << rx_bits);
wire [7:0] period_half = {1'b0, period[7:1]};
wire [7:0] period_m1 = (period == 8'd0) ? 8'd0 : (period - 8'd1);
wire [1:0] tx_crc_skip = crc32_en ? 2'd0 : 2'd2;
wire [1:0] rx_crc_skip = crc32_en ? 2'd0 : 2'd1;
wire rx_decoded = nrzi_en ? (usb_line == rx_prev) : usb_line;

function automatic [15:0] crc16_usb_byte;
    input [15:0] crc_in;
    input [7:0]  data;
    reg   [15:0] c;
    begin
        c = crc_in ^ {8'h00, data};
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        crc16_usb_byte = c;
    end
endfunction

function automatic [31:0] crc32_eth_byte;
    input [31:0] crc_in;
    input [7:0]  data;
    reg   [31:0] c;
    begin
        c = crc_in ^ {24'h0, data};
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        crc32_eth_byte = c;
    end
endfunction

always @(*) begin
    case (rd_addr)
        2'd0: rd_data = {tx_active, overlay_usb || overlay_rmii, crc_ok,
                         rx_ready, se0_now, ram_full, ram_empty, busy};
        2'd1: rd_data = crc32_en ? crc32_wire[15:8] : crc16_wire[15:8];
        2'd2: rd_data = ram[rx_idx];
        default: rd_data = crc32_en ? crc32_wire[7:0] : crc16_wire[7:0];
    endcase
end

always @(*) begin
    assist_out = 8'h00;
    assist_oe  = 8'h00;
    if (overlay_usb) begin
        assist_oe[PIN_A] = 1'b1;
        assist_oe[PIN_B] = 1'b1;
        if (force_se0 || (tx_active && (tx_phase == PH_EOP))) begin
            assist_out[PIN_A] = 1'b0;
            assist_out[PIN_B] = 1'b0;
        end else begin
            assist_out[PIN_A] = line;
            assist_out[PIN_B] = ~line;
        end
    end
    if (overlay_rmii) begin
        assist_oe[2] = 1'b1;
        assist_oe[3] = 1'b1;
        assist_oe[4] = 1'b1;
        assist_out[2] = txd0;
        assist_out[3] = txd1;
        assist_out[4] = tx_en;
    end
end

always @(posedge clk) begin
    if (reset || soft_reset) begin
        period <= 8'd33;
        stuff_en <= 1'b0;
        nrzi_en <= 1'b0;
        force_se0 <= 1'b0;
        overlay_en <= 1'b0;
        width_2 <= 1'b0;
        crc32_en <= 1'b0;
        rmii_en <= 1'b0;
        append_crc <= 1'b0;
        auto_eop <= 1'b0;
        preamble_en <= 1'b0;
        tx_active <= 1'b0;
        rx_active <= 1'b0;
        rx_ready <= 1'b0;
        crc_ok <= 1'b0;
        line <= 1'b0;
        stuff_pending <= 1'b0;
        ones_count <= 3'd0;
        bits_left <= 4'd0;
        shift <= 8'h00;
        tick_count <= 8'd0;
        crc <= 32'h0000FFFF;
        wr_ptr <= {RAM_AW{1'b0}};
        rd_ptr <= {RAM_AW{1'b0}};
        rx_idx <= {RAM_AW{1'b0}};
        byte_count <= {(RAM_AW+1){1'b0}};
        sent_count <= {(RAM_AW+1){1'b0}};
        txd0 <= 1'b0;
        txd1 <= 1'b0;
        tx_en <= 1'b0;
        tx_phase <= PH_DATA;
        preamble_left <= 4'd0;
        ifg_left <= 6'd0;
        crc_bytes_left <= 3'd0;
        crc_latched <= 24'h0;
        eop_left <= 2'd0;
        rx_prev <= 1'b0;
        rx_hunt <= 1'b1;
        rx_aligned <= 1'b0;
        rx_skip_stuff <= 1'b0;
        rx_shift <= 8'h00;
        rx_bits <= 4'd0;
        rx_se0 <= 2'd0;
        sample_wait <= 8'd0;
    end else begin
        if (rd_inc)
            rx_idx <= rx_idx + {{(RAM_AW-1){1'b0}}, 1'b1};

        if (we) begin
            case (wr_addr)
                2'd0: begin
                    stuff_en   <= wr_data[2];
                    nrzi_en    <= wr_data[3];
                    force_se0  <= wr_data[6];
                    overlay_en <= wr_data[7] | wr_data[0];
                    if (crc_reset)
                        crc <= crc32_en ? 32'hFFFFFFFF : 32'h0000FFFF;
                    if (start_rx) begin
                        rx_active <= 1'b1;
                        rx_ready <= 1'b0;
                        crc_ok <= 1'b0;
                        wr_ptr <= {RAM_AW{1'b0}};
                        byte_count <= {(RAM_AW+1){1'b0}};
                        rx_idx <= {RAM_AW{1'b0}};
                        rx_hunt <= 1'b1;
                        rx_aligned <= rmii_en;
                        rx_prev <= 1'b0;
                        rx_bits <= 4'd0;
                        rx_shift <= 8'h00;
                        rx_se0 <= 2'd0;
                        ones_count <= 3'd0;
                        rx_skip_stuff <= 1'b0;
                        sample_wait <= 8'd0;
                        tick_count <= 8'd0;
                        crc <= crc32_en ? 32'hFFFFFFFF : 32'h0000FFFF;
                    end
                    if (start_tx) begin
                        tx_active <= 1'b1;
                        rx_active <= 1'b0;
                        stuff_pending <= 1'b0;
                        ones_count <= 3'd0;
                        line <= 1'b0;
                        rd_ptr <= {RAM_AW{1'b0}};
                        sent_count <= {(RAM_AW+1){1'b0}};
                        tick_count <= 8'd0;
                        overlay_en <= 1'b1;
                        tx_en <= 1'b0;
                        txd0 <= 1'b0;
                        txd1 <= 1'b0;
                        if (preamble_en) begin
                            crc <= crc32_en ? 32'hFFFFFFFF : 32'h0000FFFF;
                            tx_phase <= PH_PRE;
                            preamble_left <= 4'd6;
                            shift <= 8'h55;
                            bits_left <= 4'd8;
                        end else begin
                            tx_phase <= PH_DATA;
                            shift <= ram[{RAM_AW{1'b0}}];
                            bits_left <= 4'd8;
                            rd_ptr <= {{(RAM_AW-1){1'b0}}, 1'b1};
                            sent_count <= {{RAM_AW{1'b0}}, 1'b1};
                            if (append_crc && (tx_crc_skip == 2'd0)) begin
                                if (crc32_en)
                                    crc <= crc32_eth_byte(32'hFFFFFFFF, ram[{RAM_AW{1'b0}}]);
                                else
                                    crc <= {16'h0, crc16_usb_byte(16'hFFFF, ram[{RAM_AW{1'b0}}])};
                            end else
                                crc <= crc32_en ? 32'hFFFFFFFF : 32'h0000FFFF;
                        end
                    end
                end
                2'd1: period <= wr_data;
                2'd2: begin
                    if (!ram_full) begin
                        ram[wr_ptr] <= wr_data;
                        wr_ptr <= wr_ptr + {{(RAM_AW-1){1'b0}}, 1'b1};
                        byte_count <= byte_count + {{RAM_AW{1'b0}}, 1'b1};
                    end
                    rx_ready <= 1'b0;
                end
                default: begin
                    if (mode_wr) begin
                        width_2     <= wr_data[0];
                        crc32_en    <= wr_data[1];
                        rmii_en     <= wr_data[2];
                        append_crc  <= wr_data[3];
                        auto_eop    <= wr_data[4];
                        preamble_en <= wr_data[5];
                    end else if (crc32_en)
                        crc <= crc32_eth_byte(crc, wr_data);
                    else
                        crc <= {16'h0, crc16_usb_byte(crc[15:0], wr_data)};
                end
            endcase
        end else if (enable && tx_active) begin
            if (tick_count == 8'd0) begin
                tick_count <= period_m1;
                if (tx_phase == PH_EOP) begin
                    if (eop_left <= 2'd1) begin
                        tx_active <= 1'b0;
                        overlay_en <= 1'b0;
                        line <= 1'b0;
                        wr_ptr <= {RAM_AW{1'b0}};
                        byte_count <= {(RAM_AW+1){1'b0}};
                    end else
                        eop_left <= eop_left - 2'd1;
                end else if (tx_phase == PH_IFG) begin
                    tx_en <= 1'b0;
                    txd0 <= 1'b0;
                    txd1 <= 1'b0;
                    if (ifg_left <= 6'd1) begin
                        tx_active <= 1'b0;
                        overlay_en <= 1'b0;
                        wr_ptr <= {RAM_AW{1'b0}};
                        byte_count <= {(RAM_AW+1){1'b0}};
                    end else
                        ifg_left <= ifg_left - 6'd1;
                end else if (width_2) begin
                    txd0 <= shift[0];
                    txd1 <= shift[1];
                    tx_en <= 1'b1;
                    shift <= {2'b00, shift[7:2]};
                    bits_left <= bits_left - 4'd2;
                    if (bits_left <= 4'd2) begin
                        if (tx_phase == PH_PRE) begin
                            if (preamble_left != 4'd0) begin
                                preamble_left <= preamble_left - 4'd1;
                                shift <= 8'h55;
                                bits_left <= 4'd8;
                            end else begin
                                shift <= 8'hD5;
                                bits_left <= 4'd8;
                                tx_phase <= PH_DATA;
                                rd_ptr <= {RAM_AW{1'b0}};
                                sent_count <= {(RAM_AW+1){1'b0}};
                            end
                        end else if (tx_phase == PH_DATA) begin
                            if (sent_count < byte_count) begin
                                shift <= ram[rd_ptr];
                                bits_left <= 4'd8;
                                if (append_crc && (sent_count >= {{(RAM_AW-1){1'b0}}, tx_crc_skip})) begin
                                    if (crc32_en)
                                        crc <= crc32_eth_byte(crc, ram[rd_ptr]);
                                    else
                                        crc <= {16'h0, crc16_usb_byte(crc[15:0], ram[rd_ptr])};
                                end
                                rd_ptr <= rd_ptr + {{(RAM_AW-1){1'b0}}, 1'b1};
                                sent_count <= sent_count + {{RAM_AW{1'b0}}, 1'b1};
                            end else if (append_crc) begin
                                crc_latched <= crc32_en ? crc32_wire[31:8] : {16'h0, crc16_wire[15:8]};
                                shift <= crc32_en ? crc32_wire[7:0] : crc16_wire[7:0];
                                bits_left <= 4'd8;
                                crc_bytes_left <= crc32_en ? 3'd3 : 3'd1;
                                tx_phase <= PH_CRC;
                            end else begin
                                tx_phase <= PH_IFG;
                                ifg_left <= 6'd48;
                            end
                        end else if (tx_phase == PH_CRC) begin
                            if (crc_bytes_left != 3'd0) begin
                                case (crc_bytes_left)
                                    3'd3: shift <= crc_latched[15:8];
                                    3'd2: shift <= crc_latched[23:16];
                                    default: shift <= crc_latched[31:24];
                                endcase
                                bits_left <= 4'd8;
                                crc_bytes_left <= crc_bytes_left - 3'd1;
                            end else begin
                                tx_phase <= PH_IFG;
                                ifg_left <= 6'd48;
                            end
                        end
                    end
                end else begin
                    // 1-bit NRZI / NRZ path (USB LS and legacy TX tests)
                    if (stuff_pending) begin
                        stuff_pending <= 1'b0;
                        ones_count <= 3'd0;
                        if (nrzi_en)
                            line <= ~line;
                        else
                            line <= 1'b0;
                        if ((bits_left == 4'd0) && (sent_count >= byte_count) &&
                            (tx_phase != PH_CRC) && !append_crc && !auto_eop) begin
                            tx_active <= 1'b0;
                            wr_ptr <= {RAM_AW{1'b0}};
                            byte_count <= {(RAM_AW+1){1'b0}};
                        end
                    end else if (bits_left != 4'd0) begin
                        shift <= {1'b0, shift[7:1]};
                        bits_left <= bits_left - 4'd1;
                        if (shift[0]) begin
                            if (stuff_en && (ones_count == 3'd5)) begin
                                stuff_pending <= 1'b1;
                                ones_count <= 3'd0;
                            end else
                                ones_count <= ones_count + 3'd1;
                            if (!nrzi_en)
                                line <= 1'b1;
                        end else begin
                            ones_count <= 3'd0;
                            if (nrzi_en)
                                line <= ~line;
                            else
                                line <= 1'b0;
                        end
                        if (bits_left == 4'd1) begin
                            if ((tx_phase == PH_DATA) && (sent_count < byte_count)) begin
                                shift <= ram[rd_ptr];
                                bits_left <= 4'd8;
                                if (append_crc && (sent_count >= {{(RAM_AW-1){1'b0}}, tx_crc_skip})) begin
                                    if (crc32_en)
                                        crc <= crc32_eth_byte(crc, ram[rd_ptr]);
                                    else
                                        crc <= {16'h0, crc16_usb_byte(crc[15:0], ram[rd_ptr])};
                                end
                                rd_ptr <= rd_ptr + {{(RAM_AW-1){1'b0}}, 1'b1};
                                sent_count <= sent_count + {{RAM_AW{1'b0}}, 1'b1};
                            end else if ((tx_phase == PH_DATA) && append_crc) begin
                                crc_latched <= {16'h0, crc16_wire[15:8]};
                                shift <= crc16_wire[7:0];
                                bits_left <= 4'd8;
                                crc_bytes_left <= 3'd1;
                                tx_phase <= PH_CRC;
                            end else if ((tx_phase == PH_CRC) && (crc_bytes_left != 3'd0)) begin
                                shift <= crc_latched[15:8];
                                bits_left <= 4'd8;
                                crc_bytes_left <= 3'd0;
                            end else if (!(shift[0] && stuff_en && (ones_count == 3'd5))) begin
                                if (!auto_eop) begin
                                    tx_active <= 1'b0;
                                    wr_ptr <= {RAM_AW{1'b0}};
                                    byte_count <= {(RAM_AW+1){1'b0}};
                                end
                            end
                        end
                    end else if (auto_eop && (tx_phase != PH_EOP)) begin
                        tx_phase <= PH_EOP;
                        eop_left <= 2'd2;
                    end else begin
                        tx_active <= 1'b0;
                        wr_ptr <= {RAM_AW{1'b0}};
                        byte_count <= {(RAM_AW+1){1'b0}};
                    end
                end
            end else
                tick_count <= tick_count - 8'd1;
        end else if (enable && rx_active) begin
            if (rmii_en) begin
                if (gpio_in[7]) begin
                    if (tick_count == 8'd0) begin
                        tick_count <= period_m1;
                        rx_shift <= rx_byte_now;
                        if (rx_bits == 4'd6) begin
                            if (rx_hunt) begin
                                if (rx_byte_now == 8'hD5)
                                    rx_hunt <= 1'b0;
                            end else if (!ram_full) begin
                                ram[wr_ptr] <= rx_byte_now;
                                crc <= crc32_eth_byte(crc, rx_byte_now);
                                wr_ptr <= wr_ptr + {{(RAM_AW-1){1'b0}}, 1'b1};
                                byte_count <= byte_count + {{RAM_AW{1'b0}}, 1'b1};
                            end
                            rx_bits <= 4'd0;
                            rx_shift <= 8'h00;
                        end else
                            rx_bits <= rx_bits + 4'd2;
                    end else
                        tick_count <= tick_count - 8'd1;
                end else if (byte_count != {(RAM_AW+1){1'b0}}) begin
                    rx_active <= 1'b0;
                    rx_ready <= 1'b1;
                    rx_idx <= {RAM_AW{1'b0}};
                    // Reflected CRC-32 remainder after data+FCS (same
                    // algorithm as TX). IEEE texts often quote 0xC704DD7B
                    // for a different bit order; this datapath is 0xDEBB20E3.
                    crc_ok <= (crc == 32'hDEBB20E3);
                end
            end else begin
                // USB LS RX: NRZI unstuff, SYNC hunt, EOP = 2 SE0 bits
                if (se0_now && rx_aligned) begin
                    if (tick_count == 8'd0) begin
                        tick_count <= period_m1;
                        rx_se0 <= rx_se0 + 2'd1;
                        if (rx_se0 >= 2'd1) begin
                            rx_active <= 1'b0;
                            rx_ready <= 1'b1;
                            rx_idx <= {RAM_AW{1'b0}};
                            crc_ok <= (crc[15:0] == 16'hB001) ||
                                      (byte_count < {{(RAM_AW-1){1'b0}}, 2'd2});
                        end
                    end else
                        tick_count <= tick_count - 8'd1;
                end else if (!rx_aligned) begin
                    if (usb_line && !rx_prev) begin
                        rx_aligned <= 1'b1;
                        sample_wait <= period_half;
                        rx_hunt <= 1'b1;
                        rx_bits <= 4'd0;
                        rx_shift <= 8'h00;
                        ones_count <= 3'd0;
                    end else
                        rx_prev <= usb_line;
                end else if (sample_wait != 8'd0) begin
                    sample_wait <= sample_wait - 8'd1;
                end else begin
                    rx_prev <= usb_line;
                    sample_wait <= period_m1;
                    rx_se0 <= 2'd0;
                    tick_count <= 8'd0;
                    if (rx_skip_stuff) begin
                        rx_skip_stuff <= 1'b0;
                        ones_count <= 3'd0;
                    end else begin
                        if (rx_decoded) begin
                            if (stuff_en && (ones_count == 3'd5))
                                rx_skip_stuff <= 1'b1;
                            ones_count <= (stuff_en && (ones_count == 3'd5)) ? 3'd0
                                                                           : (ones_count + 3'd1);
                        end else
                            ones_count <= 3'd0;
                        rx_shift <= {rx_decoded, rx_shift[7:1]};
                        if (rx_hunt) begin
                            if ({rx_decoded, rx_shift[7:1]} == 8'h80) begin
                                rx_hunt <= 1'b0;
                                rx_bits <= 4'd0;
                            end
                        end else begin
                            rx_bits <= rx_bits + 4'd1;
                            if (rx_bits == 4'd7) begin
                                rx_bits <= 4'd0;
                                if (!ram_full) begin
                                    ram[wr_ptr] <= {rx_decoded, rx_shift[7:1]};
                                    if (byte_count >= {{(RAM_AW-1){1'b0}}, rx_crc_skip})
                                        crc <= {16'h0, crc16_usb_byte(
                                            crc[15:0], {rx_decoded, rx_shift[7:1]})};
                                    wr_ptr <= wr_ptr + {{(RAM_AW-1){1'b0}}, 1'b1};
                                    byte_count <= byte_count + {{RAM_AW{1'b0}}, 1'b1};
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

endmodule

`default_nettype wire
