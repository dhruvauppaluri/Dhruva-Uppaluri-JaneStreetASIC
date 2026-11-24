// Unbounded proof of the barrel properties on the complete chip: free host
// SPI pins (any register / memory / FIFO traffic, any lane starts and stops,
// barrel-width changes), free protocol pins, and arbitrary record data.
`default_nettype none
module fv_barrel (
    input wire       clk,
    input wire [7:0] ui_in,
    input wire [7:0] uio_in
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire [7:0] uo_out, uio_out, uio_oe;
    tt_um_dhruvauppaluri_setl dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
        .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(~init)
    );
endmodule
