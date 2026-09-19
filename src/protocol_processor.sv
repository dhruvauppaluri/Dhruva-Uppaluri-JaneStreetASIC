`timescale 1ns/1ps
`default_nettype none

// Compact, cycle-deterministic protocol processor.
//
// Programs are loaded through the write port while enable is low. The program
// memory deliberately has no reset so an external reset restarts execution
// without erasing the loaded protocol firmware.
module protocol_processor #(
    parameter integer PROGRAM_WORDS = 32,
    parameter integer ADDRESS_WIDTH = 5
) (
    input  wire                     clk,
    input  wire                     reset,
    input  wire                     enable,

    input  wire                     program_we,
    input  wire [ADDRESS_WIDTH-1:0] program_address,
    input  wire [15:0]              program_data,

    input  wire [7:0]               gpio_in,
    output reg  [7:0]               gpio_out,
    output reg  [7:0]               gpio_oe,

    output reg                      halted,
    output wire                     waiting,
    output reg  [ADDRESS_WIDTH-1:0] pc
);

localparam [3:0] OP_NOP      = 4'h0;
localparam [3:0] OP_OUT      = 4'h1;
localparam [3:0] OP_DIR      = 4'h2;
localparam [3:0] OP_WAIT     = 4'h3;
localparam [3:0] OP_IN       = 4'h4;
localparam [3:0] OP_LDI      = 4'h5;
localparam [3:0] OP_ANDI     = 4'h6;
localparam [3:0] OP_XORI     = 4'h7;
localparam [3:0] OP_ADDI     = 4'h8;
localparam [3:0] OP_SHL      = 4'h9;
localparam [3:0] OP_SHR      = 4'hA;
localparam [3:0] OP_JMP      = 4'hB;
localparam [3:0] OP_JZ       = 4'hC;
localparam [3:0] OP_JNZ      = 4'hD;
localparam [3:0] OP_WAIT_PIN = 4'hE;
localparam [3:0] OP_HALT     = 4'hF;

reg [15:0] instruction_memory [0:PROGRAM_WORDS-1];
reg [7:0] registers [0:3];
reg [11:0] wait_count;
reg wait_active;

wire [15:0] instruction = instruction_memory[pc];
wire [3:0] opcode = instruction[15:12];
wire [11:0] operand = instruction[11:0];
wire [1:0] register_index = operand[9:8];
wire [ADDRESS_WIDTH-1:0] branch_address = operand[ADDRESS_WIDTH-1:0];
wire [2:0] pin_index = operand[2:0];
wire pin_level = operand[3];

assign waiting = wait_active;

always @(posedge clk) begin
    if (program_we)
        instruction_memory[program_address] <= program_data;

    if (reset) begin
        pc <= {ADDRESS_WIDTH{1'b0}};
        gpio_out <= 8'h00;
        gpio_oe <= 8'h00;
        registers[0] <= 8'h00;
        registers[1] <= 8'h00;
        registers[2] <= 8'h00;
        registers[3] <= 8'h00;
        wait_count <= 12'd0;
        wait_active <= 1'b0;
        halted <= 1'b0;
    end else if (enable && !halted) begin
        if (wait_active) begin
            if (wait_count <= 12'd1) begin
                wait_count <= 12'd0;
                wait_active <= 1'b0;
            end else begin
                wait_count <= wait_count - 12'd1;
            end
        end else begin
            case (opcode)
                OP_NOP: begin
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_OUT: begin
                    if (operand[11])
                        gpio_out <= registers[register_index];
                    else
                        gpio_out <= operand[7:0];
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_DIR: begin
                    gpio_oe <= operand[7:0];
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                // WAIT 0 advances immediately. WAIT N inserts N completely
                // idle enabled clock cycles before the next instruction.
                OP_WAIT: begin
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                    if (operand != 12'd0) begin
                        wait_count <= operand;
                        wait_active <= 1'b1;
                    end
                end

                OP_IN: begin
                    registers[register_index] <= gpio_in;
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_LDI: begin
                    registers[register_index] <= operand[7:0];
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_ANDI: begin
                    registers[register_index] <=
                        registers[register_index] & operand[7:0];
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_XORI: begin
                    registers[register_index] <=
                        registers[register_index] ^ operand[7:0];
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_ADDI: begin
                    registers[register_index] <=
                        registers[register_index] + operand[7:0];
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_SHL: begin
                    registers[register_index] <=
                        {registers[register_index][6:0], 1'b0};
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_SHR: begin
                    registers[register_index] <=
                        {1'b0, registers[register_index][7:1]};
                    pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_JMP: begin
                    pc <= branch_address;
                end

                OP_JZ: begin
                    if (registers[register_index] == 8'h00)
                        pc <= branch_address;
                    else
                        pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_JNZ: begin
                    if (registers[register_index] != 8'h00)
                        pc <= branch_address;
                    else
                        pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                // Stay on this instruction until the selected input pin has
                // the requested level. This makes edge/pin polling compact.
                OP_WAIT_PIN: begin
                    if (gpio_in[pin_index] == pin_level)
                        pc <= pc + {{(ADDRESS_WIDTH-1){1'b0}}, 1'b1};
                end

                OP_HALT: begin
                    halted <= 1'b1;
                end

                default: begin
                    halted <= 1'b1;
                end
            endcase
        end
    end
end

endmodule

`default_nettype wire
