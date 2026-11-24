// Formal proof: programs/i2c_ctrl.setl on the setl_lane RTL never violates
// I2C framing.  The target side is unconstrained: it may stretch SCL for any
// time, ACK or NACK anything and drive any data.  Open-drain wired-AND bus.
`default_nettype none
module fv_i2c #(parameter [15:0] TA = 16'd0, parameter [15:0] TB = 16'd0) (
    input wire        clk,
    input wire        host_push,
    input wire [7:0]  host_wdata,
    input wire        host_pop,
    input wire        ext_scl,      // target pulls SCL low (stretching) when 0
    input wire        ext_sda,      // target drives SDA low when 0
    input wire [29:0] pins
);
`include "rom.vh"
`include "sym.vh"
    wire [3:0]  cfg_outinit = 4'hF;
    wire        cfg_msb = 1'b1;
    wire [8:0]  cfg_start = S_I2C;
    wire [15:0] cfg_ta = TA, cfg_tb = TB;
    wire [7:0]  cfg_match = 8'h01, cfg_mask = 8'h01;
    wire scl_bus = slot_val[0] & ext_scl;
    wire sda_bus = slot_val[1] & ext_sda;
    // uio0 = SCL (in_vec 8), uio1 = SDA (in_vec 9), lane flag 0 = in_vec 24
    wire [31:0] in_vec = {2'b10, pins[29:25], flag, pins[23:10], sda_bus, scl_bus, pins[7:0]};
`include "fv_env.vh"

    wire scl = slot_val[0], sda = slot_val[1];
    always @(posedge clk) if (started && $past(started)) begin
        // our SDA only changes while our SCL is low, except START and STOP
        if (sda != $past(sda) && scl && $past(scl))
            assert(($past(pc_o) == S_I_START && !sda) || ($past(pc_o) == S_ST4 && sda));
        // we never pull SCL low and change SDA in the same clock
        if (sda != $past(sda)) assert(scl == $past(scl));
    end
    always @(*) if (started) assert(!ovf_set || pc_o == S_RDONE);
`ifdef REACH
    // reachability: a read byte delivered and a STOP issued after it
    reg rd = 1'b0;
    always @(posedge clk) if (pc_o == S_RDONE) rd <= 1'b1;
    always @(*) assert(!(rd && pc_o == S_ST4));
`endif
endmodule
