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
// ui_in[7] : load: assist MMIO target; run: show PC[7:5] on uo_out[2:0]
// uio[7:0]: bidirectional protocol pins
//   uio[0] USB D+, uio[1] USB D-
//   uio[2:5] Ethernet SPI SCK/MOSI/MISO/CS
//   uio[6:7] Ethernet RST/INT
// uo_out[4:0] = PC[4:0] (or {2'b00, PC[7:5]} when ui_in[7] and run),
// uo_out[5] = halted, [6] = waiting, [7] = protocol classifier result
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

localparam integer PROGRAM_WORDS = 256;
localparam integer ADDRESS_WIDTH = $clog2(PROGRAM_WORDS);

wire reset = !rst_n;
wire run = ui_in[3];

wire loader_we;
wire [ADDRESS_WIDTH-1:0] program_address;
wire [15:0] program_data;
wire loader_target;
wire loader_assist;
wire [ADDRESS_WIDTH-1:0] loader_next_address;
wire [ADDRESS_WIDTH-1:0] pc;
wire halted;
wire waiting;
wire classifier_result;
wire classifier_valid;
wire [7:0] processor_gpio_in =
    {ui_in[6] ? classifier_result : uio_in[7], uio_in[6:0]};
wire [4:0] pc_vis = run && ui_in[7] ? {2'b00, pc[ADDRESS_WIDTH-1:5]}
                                    : pc[4:0];

serial_program_loader #(
    .ADDRESS_WIDTH(ADDRESS_WIDTH)
) loader (
    .clk(clk),
    .reset(reset),
    .load_enable(!run),
    .serial_data(ui_in[0]),
    .shift(ui_in[1]),
    .commit(ui_in[2]),
    .restart_address(ui_in[5]),
    .target_select(ui_in[4]),
    .assist_select(ui_in[7]),
    .program_we(loader_we),
    .program_address(program_address),
    .program_data(program_data),
    .write_target(loader_target),
    .write_assist(loader_assist),
    .next_address(loader_next_address)
);

protocol_processor #(
    .PROGRAM_WORDS(PROGRAM_WORDS),
    .ADDRESS_WIDTH(ADDRESS_WIDTH)
) processor (
    .clk(clk),
    .reset(reset),
    .enable(ena && run),
    .program_we(loader_we && !loader_target && !loader_assist),
    .program_address(program_address),
    .program_data(program_data),
    .assist_cfg_we(loader_we && loader_assist),
    .assist_cfg_address(program_address[1:0]),
    .assist_cfg_data(program_data[7:0]),
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

assign uo_out = {classifier_result, waiting, halted, pc_vis};

wire _unused = &{loader_next_address, classifier_valid, 1'b0};

endmodule

`default_nettype wire
