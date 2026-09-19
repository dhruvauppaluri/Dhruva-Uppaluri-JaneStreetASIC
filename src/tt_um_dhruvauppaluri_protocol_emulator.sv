`timescale 1ns/1ps
`default_nettype none

// Tiny Tapeout wrapper.
//
// ui_in[0] : serial program bit (MSB first)
// ui_in[1] : shift strobe
// ui_in[2] : commit strobe after sixteen shifts
// ui_in[3] : run (0 = load/paused, 1 = execute)
// ui_in[4] : loader target (0 = program, 1 = classifier configuration)
// ui_in[5] : restart loader address at zero
// ui_in[6] : route classifier result to processor input bit 7
// uio[7:0]: bidirectional protocol pins
// uo_out[4:0] = program counter, [5] = halted, [6] = waiting,
// uo_out[7] = protocol classifier result
module tt_um_dhruvauppaluri_protocol_emulator (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

wire reset = !rst_n;
wire run = ui_in[3];

wire loader_we;
wire [4:0] program_address;
wire [15:0] program_data;
wire loader_target;
wire [4:0] loader_next_address;
wire [4:0] pc;
wire halted;
wire waiting;
wire classifier_result;
wire classifier_valid;
wire [7:0] processor_gpio_in =
    {ui_in[6] ? classifier_result : uio_in[7], uio_in[6:0]};

serial_program_loader loader (
    .clk(clk),
    .reset(reset),
    .load_enable(!run),
    .serial_data(ui_in[0]),
    .shift(ui_in[1]),
    .commit(ui_in[2]),
    .restart_address(ui_in[5]),
    .target_select(ui_in[4]),
    .program_we(loader_we),
    .program_address(program_address),
    .program_data(program_data),
    .write_target(loader_target),
    .next_address(loader_next_address)
);

protocol_processor processor (
    .clk(clk),
    .reset(reset),
    .enable(ena && run),
    .program_we(loader_we && !loader_target),
    .program_address(program_address),
    .program_data(program_data),
    .gpio_in(processor_gpio_in),
    .gpio_out(uio_out),
    .gpio_oe(uio_oe),
    .halted(halted),
    .waiting(waiting),
    .pc(pc)
);

protocol_classifier classifier (
    .clk(clk),
    .reset(reset),
    .enable(ena && run),
    .gpio_in(uio_in),
    .config_we(loader_we && loader_target),
    .config_address(program_address[2:0]),
    .config_data(program_data),
    .class_result(classifier_result),
    .class_valid(classifier_valid)
);

assign uo_out = {classifier_result, waiting, halted, pc};

wire _unused = &{ui_in[7], loader_next_address, classifier_valid, 1'b0};

endmodule

`default_nettype wire
