`timescale 1ns/1ps
`default_nettype none

// Serial loader for the protocol processor's PROGRAM_WORDS x 16 instruction
// memory. Shift sixteen bits MSB-first, then pulse commit for one clock. Each
// commit writes one instruction and advances the write address.
//
// target_select (ui_in[4]) chooses classifier configuration.
// assist_select (ui_in[7]) chooses the assist MMIO (wins over classifier).
module serial_program_loader #(
    parameter integer ADDRESS_WIDTH = 8
) (
    input  wire                     clk,
    input  wire                     reset,
    input  wire                     load_enable,
    input  wire                     serial_data,
    input  wire                     shift,
    input  wire                     commit,
    input  wire                     restart_address,
    input  wire                     target_select,
    input  wire                     assist_select,
    output reg                      program_we,
    output reg  [ADDRESS_WIDTH-1:0] program_address,
    output reg  [15:0]              program_data,
    output reg                      write_target,
    output reg                      write_assist,
    output reg  [ADDRESS_WIDTH-1:0] next_address
);

reg [15:0] shift_register;

always @(posedge clk) begin
    if (reset) begin
        shift_register <= 16'h0000;
        program_we <= 1'b0;
        program_address <= {ADDRESS_WIDTH{1'b0}};
        program_data <= 16'h0000;
        write_target <= 1'b0;
        write_assist <= 1'b0;
        next_address <= {ADDRESS_WIDTH{1'b0}};
    end else begin
        program_we <= 1'b0;

        if (load_enable) begin
            if (restart_address)
                next_address <= {ADDRESS_WIDTH{1'b0}};

            if (shift)
                shift_register <= {shift_register[14:0], serial_data};

            if (commit) begin
                program_we <= 1'b1;
                program_address <= next_address;
                program_data <= shift_register;
                write_assist <= assist_select;
                write_target <= target_select && !assist_select;
                next_address <=
                    next_address + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
            end
        end
    end
end

endmodule

`default_nettype wire
