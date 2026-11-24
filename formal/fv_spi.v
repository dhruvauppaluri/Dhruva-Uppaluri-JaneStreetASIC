// Formal proof: programs/spi_ctrl.setl (CPHA=0, mode 0) on the setl_lane RTL.
`default_nettype none
module fv_spi #(parameter [15:0] TA = 16'd0) (
    input wire        clk,
    input wire        host_push,
    input wire [7:0]  host_wdata,
    input wire        host_pop,
    input wire        miso,
    input wire [28:0] pins
);
`include "rom.vh"
`include "sym.vh"
    wire [3:0]  cfg_outinit = 4'b1100;   // SCK=0 (CPOL 0), MOSI=0, CS_n=1
    wire        cfg_msb = 1'b1;
    wire [8:0]  cfg_start = S_SPI_CPHA0;
    wire [15:0] cfg_ta = TA, cfg_tb = 16'd0;
    wire [7:0]  cfg_match = 8'd0, cfg_mask = 8'd0;
    // MISO is in_vec[1] (ui1)
    wire [31:0] in_vec = {2'b10, pins[28:1], miso, pins[0]};
`include "fv_env.vh"
    always @(*) assume(!host_pop);     // the host leaves the RX FIFO alone

    wire sck = slot_val[0], mosi = slot_val[1], cs = slot_val[2];
    reg  [7:0] exp;
    reg  [3:0] bitn = 4'd8;
    reg  [7:0] rxbits;
    reg        first_byte_done = 1'b0;
    reg sck_q = 1'b0, miso_q = 1'b0, started_q = 1'b0;
    always @(posedge clk) begin sck_q <= sck; miso_q <= miso; started_q <= started; end
    wire rise = started && started_q && sck && !sck_q;

    always @(posedge clk) if (started && $past(started)) begin
        // SCK only moves inside a frame
        if (sck != $past(sck)) assert(!cs && !$past(cs));
        // MOSI is stable while SCK is high and across the rising edge
        if ($past(sck) && mosi != $past(mosi)) assert(!sck);
        if (rise) assert(mosi == $past(mosi));
        // a new byte only starts after the previous one finished (8 edges)
        if (did_pop) assert(bitn == 4'd8);
        // each rising edge carries the next bit of the popped byte, MSB first
        if (rise) begin
            assert(bitn < 4'd8);
            assert(mosi == exp[3'd7 - bitn[2:0]]);
        end
        // CS only rises on a byte boundary
        if (cs && !$past(cs)) assert(bitn == 4'd8);
    end
    always @(posedge clk) if (started) begin
        if (did_pop) begin exp <= popped; bitn <= 4'd0; end
        else if (rise) bitn <= bitn + 4'd1;
        if (rise && !first_byte_done) rxbits <= {rxbits[6:0], miso_q};
        if (rx_level != 5'd0) first_byte_done <= 1'b1;
    end
    // the first byte pushed to RX is exactly the MISO bits seen at the 8 rising edges
    always @(posedge clk) if (started && $past(started) && $past(rx_level) == 5'd0 && rx_level == 5'd1)
        assert(rx_head == rxbits);
`ifdef REACH
    // reachability: a received byte, then CS released after a multi-byte frame
    reg got = 1'b0;
    always @(posedge clk) if (first_byte_done && did_pop) got <= 1'b1;
    always @(*) assert(!(got && cs && rx_level == 5'd2));
`endif
endmodule
