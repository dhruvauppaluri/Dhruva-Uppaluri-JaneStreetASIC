`timescale 1ns/1ps
`default_nettype none

// General-purpose pin assist used by firmware for tight bit timing.
//
// The engine is intentionally not USB- or Ethernet-named: it is a
// programmable bit ticker, optional NRZI differential driver, optional
// bit-stuffer, USB CRC-16 helper, and a small byte FIFO. Firmware decides
// how to use those primitives (low-speed USB on D+/D-, future protocols,
// etc.).
//
// Memory map (8-bit ports, written with AOUT / read with AIN):
//   0  W: control strobes and enables   R: status
//   1  W: bit-tick period (cycles/bit)  R: CRC-16 high byte (wire value)
//   2  W: push TX FIFO                  R: FIFO count
//   3  W: feed CRC-16                   R: CRC-16 low byte (wire value)
//
// Control write bits:
//   [0] TX_START (strobe)  [1] SOFT_RESET (strobe)
//   [2] STUFF_EN           [3] NRZI_EN
//   [4] CRC_RESET (strobe) [6] FORCE_SE0
//   [7] OVERLAY_EN
//
// Status bits:
//   [0] busy  [1] fifo_empty  [2] fifo_full  [3] se0
//   [4] tick  [5] line_k      [6] overlay    [7] stuff_pending
//
// NRZI: line 0 is the J state (pin A low, pin B high), line 1 is K.
// A data 0 toggles; a data 1 holds. Bytes shift LSB first. After six
// consecutive 1s a stuffed 0 is inserted when STUFF_EN is set.
//
// CRC-16 uses the USB polynomial (reflected 0xA001), init 0xFFFF, and
// reads return the complemented remainder ready to place on the wire.
module assist_engine #(
    parameter integer FIFO_BYTES = 32,
    parameter [2:0]   PIN_A      = 3'd0,
    parameter [2:0]   PIN_B      = 3'd1
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,

    input  wire       we,
    input  wire [1:0] wr_addr,
    input  wire [7:0] wr_data,

    input  wire [1:0] rd_addr,
    output reg  [7:0] rd_data,

    input  wire [7:0] gpio_in,
    output reg  [7:0] assist_out,
    output reg  [7:0] assist_oe
);

localparam integer FIFO_AW = $clog2(FIFO_BYTES);

reg [7:0] period;
reg       stuff_en;
reg       nrzi_en;
reg       force_se0;
reg       overlay_en;
reg       tx_active;
reg       line;
reg       stuff_pending;
reg [2:0] ones_count;
reg [3:0] bits_left;
reg [7:0] shift;
reg [7:0] tick_count;
reg [15:0] crc;

reg [7:0] fifo_mem [0:FIFO_BYTES-1];
reg [FIFO_AW-1:0] wr_ptr;
reg [FIFO_AW-1:0] rd_ptr;
reg [FIFO_AW:0] fifo_count;

wire fifo_empty = (fifo_count == {(FIFO_AW+1){1'b0}});
wire fifo_full  = (fifo_count == FIFO_BYTES[FIFO_AW:0]);
wire se0_now    = (gpio_in[PIN_A] == 1'b0) && (gpio_in[PIN_B] == 1'b0);
wire overlay    = overlay_en || tx_active || force_se0;
wire tick_now   = tx_active && (tick_count == 8'd0);
wire [15:0] crc_wire = crc ^ 16'hFFFF;

wire start_strobe = we && (wr_addr == 2'd0) && wr_data[0] && !fifo_empty;
wire soft_reset   = we && (wr_addr == 2'd0) && wr_data[1];
wire crc_reset    = we && (wr_addr == 2'd0) && wr_data[4];

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

always @(*) begin
    case (rd_addr)
        2'd0: rd_data = {
            stuff_pending,
            overlay,
            line,
            tick_now,
            se0_now,
            fifo_full,
            fifo_empty,
            tx_active
        };
        2'd1: rd_data = crc_wire[15:8];
        2'd2: rd_data = {{(8 - FIFO_AW - 1){1'b0}}, fifo_count};
        default: rd_data = crc_wire[7:0];
    endcase
end

always @(*) begin
    assist_out = 8'h00;
    assist_oe  = 8'h00;
    if (overlay) begin
        assist_oe[PIN_A] = 1'b1;
        assist_oe[PIN_B] = 1'b1;
        if (force_se0) begin
            assist_out[PIN_A] = 1'b0;
            assist_out[PIN_B] = 1'b0;
        end else begin
            assist_out[PIN_A] = line;
            assist_out[PIN_B] = ~line;
        end
    end
end

always @(posedge clk) begin
    if (reset || soft_reset) begin
        period        <= 8'd33;
        stuff_en      <= 1'b0;
        nrzi_en       <= 1'b0;
        force_se0     <= 1'b0;
        overlay_en    <= 1'b0;
        tx_active     <= 1'b0;
        line          <= 1'b0;
        stuff_pending <= 1'b0;
        ones_count    <= 3'd0;
        bits_left     <= 4'd0;
        shift         <= 8'h00;
        tick_count    <= 8'd0;
        crc           <= 16'hFFFF;
        wr_ptr        <= {FIFO_AW{1'b0}};
        rd_ptr        <= {FIFO_AW{1'b0}};
        fifo_count    <= {(FIFO_AW+1){1'b0}};
    end else begin
        if (we) begin
            case (wr_addr)
                2'd0: begin
                    stuff_en   <= wr_data[2];
                    nrzi_en    <= wr_data[3];
                    force_se0  <= wr_data[6];
                    overlay_en <= wr_data[7] | wr_data[0];
                    if (crc_reset)
                        crc <= 16'hFFFF;
                    if (start_strobe) begin
                        tx_active     <= 1'b1;
                        stuff_pending <= 1'b0;
                        ones_count    <= 3'd0;
                        line          <= 1'b0;
                        shift         <= fifo_mem[rd_ptr];
                        rd_ptr        <= rd_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
                        fifo_count    <= fifo_count - {{FIFO_AW{1'b0}}, 1'b1};
                        bits_left     <= 4'd8;
                        tick_count    <= 8'd0;
                        overlay_en    <= 1'b1;
                    end
                end
                2'd1: period <= wr_data;
                2'd2: begin
                    if (!fifo_full) begin
                        fifo_mem[wr_ptr] <= wr_data;
                        wr_ptr <= wr_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
                        fifo_count <= fifo_count + {{FIFO_AW{1'b0}}, 1'b1};
                    end
                end
                default: crc <= crc16_usb_byte(crc, wr_data);
            endcase
        end else if (enable && tx_active) begin
            if (tick_count == 8'd0) begin
                if (stuff_pending) begin
                    stuff_pending <= 1'b0;
                    ones_count <= 3'd0;
                    if (nrzi_en)
                        line <= ~line;
                    else
                        line <= 1'b0;
                    if ((bits_left == 4'd0) && fifo_empty)
                        tx_active <= 1'b0;
                end else if (bits_left != 4'd0) begin
                    shift <= {1'b0, shift[7:1]};
                    bits_left <= bits_left - 4'd1;
                    if (shift[0]) begin
                        if (stuff_en && (ones_count == 3'd5)) begin
                            stuff_pending <= 1'b1;
                            ones_count <= 3'd0;
                        end else begin
                            ones_count <= ones_count + 3'd1;
                        end
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
                        if (!fifo_empty) begin
                            shift <= fifo_mem[rd_ptr];
                            rd_ptr <= rd_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
                            fifo_count <= fifo_count - {{FIFO_AW{1'b0}}, 1'b1};
                            bits_left <= 4'd8;
                        end else if (!(shift[0] && stuff_en && (ones_count == 3'd5))) begin
                            tx_active <= 1'b0;
                        end
                    end
                end else begin
                    tx_active <= 1'b0;
                end
                tick_count <= (period == 8'd0) ? 8'd0 : (period - 8'd1);
            end else begin
                tick_count <= tick_count - 8'd1;
            end
        end
    end
end

endmodule

`default_nettype wire
