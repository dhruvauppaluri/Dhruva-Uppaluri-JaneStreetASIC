`timescale 1ns/1ps

module protocol_processor_tb;

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

reg clk;
reg reset;
reg enable;
reg program_we;
reg [4:0] program_address;
reg [15:0] program_data;
reg [7:0] gpio_in;

wire [7:0] gpio_out;
wire [7:0] gpio_oe;
wire halted;
wire waiting;
wire [4:0] pc;

integer errors;

protocol_processor dut (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .program_we(program_we),
    .program_address(program_address),
    .program_data(program_data),
    .gpio_in(gpio_in),
    .gpio_out(gpio_out),
    .gpio_oe(gpio_oe),
    .halted(halted),
    .waiting(waiting),
    .pc(pc)
);

always #5 clk = ~clk;

function [15:0] insn;
    input [3:0] opcode;
    input [11:0] operand;
    begin
        insn = {opcode, operand};
    end
endfunction

function [11:0] reg_imm;
    input [1:0] register_number;
    input [7:0] immediate;
    begin
        reg_imm = {2'b00, register_number, immediate};
    end
endfunction

function [11:0] branch;
    input [1:0] register_number;
    input [4:0] address;
    begin
        branch = {2'b00, register_number, 3'b000, address};
    end
endfunction

task write_instruction;
    input [4:0] address;
    input [15:0] value;
    begin
        @(negedge clk);
        program_address = address;
        program_data = value;
        program_we = 1'b1;
        @(posedge clk);
        #1;
        program_we = 1'b0;
    end
endtask

task check_state;
    input [4:0] expected_pc;
    input [7:0] expected_output;
    input expected_waiting;
    begin
        if (pc !== expected_pc || gpio_out !== expected_output ||
            waiting !== expected_waiting) begin
            $display(
                "ERROR at %0t: pc=%0d/%0d out=0x%02h/0x%02h wait=%b/%b",
                $time, pc, expected_pc, gpio_out, expected_output,
                waiting, expected_waiting
            );
            errors = errors + 1;
        end
    end
endtask

task step;
    begin
        @(posedge clk);
        #1;
    end
endtask

initial begin
    clk = 1'b0;
    reset = 1'b1;
    enable = 1'b0;
    program_we = 1'b0;
    program_address = 5'd0;
    program_data = 16'h0000;
    gpio_in = 8'h00;
    errors = 0;

    // Exercise output, direction, wait/pause, register ALU, loop branches,
    // input sampling, pin waiting, shifts, XOR, zero wait, jump and halt.
    write_instruction(5'd0,  insn(OP_DIR,      12'h0FF));
    write_instruction(5'd1,  insn(OP_OUT,      12'h001));
    write_instruction(5'd2,  insn(OP_WAIT,     12'd3));
    write_instruction(5'd3,  insn(OP_OUT,      12'h000));
    write_instruction(5'd4,  insn(OP_LDI,      reg_imm(2'd0, 8'd3)));
    write_instruction(5'd5,  insn(OP_OUT,      12'h800)); // OUT r0
    write_instruction(5'd6,  insn(OP_ADDI,     reg_imm(2'd0, 8'hFF)));
    write_instruction(5'd7,  insn(OP_JNZ,      branch(2'd0, 5'd5)));
    write_instruction(5'd8,  insn(OP_IN,       reg_imm(2'd1, 8'h00)));
    write_instruction(5'd9,  insn(OP_ANDI,     reg_imm(2'd1, 8'h01)));
    write_instruction(5'd10, insn(OP_JZ,       branch(2'd1, 5'd8)));
    write_instruction(5'd11, insn(OP_OUT,      12'h0AA));
    write_instruction(5'd12, insn(OP_WAIT_PIN, 12'h00A)); // pin 2 == 1
    write_instruction(5'd13, insn(OP_LDI,      reg_imm(2'd2, 8'h81)));
    write_instruction(5'd14, insn(OP_SHL,      reg_imm(2'd2, 8'h00)));
    write_instruction(5'd15, insn(OP_SHR,      reg_imm(2'd2, 8'h00)));
    write_instruction(5'd16, insn(OP_XORI,     reg_imm(2'd2, 8'h01)));
    write_instruction(5'd17, insn(OP_OUT,      12'hA00)); // OUT r2
    write_instruction(5'd18, insn(OP_WAIT,     12'd0));
    write_instruction(5'd19, insn(OP_JMP,      12'd21));
    write_instruction(5'd20, insn(OP_OUT,      12'h0EE)); // must skip
    write_instruction(5'd21, insn(OP_HALT,     12'h000));

    @(negedge clk);
    reset = 1'b0;
    enable = 1'b1;

    step(); // DIR
    if (gpio_oe !== 8'hFF) begin
        $display("ERROR: DIR did not set all output enables");
        errors = errors + 1;
    end

    step(); // OUT 1
    check_state(5'd2, 8'h01, 1'b0);

    step(); // WAIT 3 starts
    check_state(5'd3, 8'h01, 1'b1);

    // Pausing the processor must also pause the wait counter.
    enable = 1'b0;
    repeat (2) begin
        step();
        check_state(5'd3, 8'h01, 1'b1);
    end
    enable = 1'b1;

    repeat (3) begin
        step();
    end
    check_state(5'd3, 8'h01, 1'b0);

    step(); // OUT 0
    check_state(5'd4, 8'h00, 1'b0);

    step(); // LDI r0, 3
    step(); // OUT r0
    if (gpio_out !== 8'd3) errors = errors + 1;
    step(); // ADDI -> 2
    step(); // JNZ -> 5
    step(); // OUT r0
    if (gpio_out !== 8'd2) errors = errors + 1;
    step(); // ADDI -> 1
    step(); // JNZ -> 5
    step(); // OUT r0
    if (gpio_out !== 8'd1) errors = errors + 1;
    step(); // ADDI -> 0
    step(); // JNZ falls through
    if (pc !== 5'd8) errors = errors + 1;

    // First input sample is zero, so the polling loop repeats.
    step(); // IN
    step(); // ANDI
    step(); // JZ -> 8
    if (pc !== 5'd8) errors = errors + 1;

    gpio_in = 8'h01;
    step(); // IN
    step(); // ANDI
    step(); // JZ falls through
    step(); // OUT AA
    if (gpio_out !== 8'hAA || pc !== 5'd12) errors = errors + 1;

    // WAIT_PIN targets pin 2 high and must hold the PC while it is low.
    repeat (3) begin
        step();
        if (pc !== 5'd12) errors = errors + 1;
    end
    gpio_in = 8'h05;
    step();
    if (pc !== 5'd13) errors = errors + 1;

    step(); // LDI r2, 81
    step(); // SHL -> 02
    step(); // SHR -> 01
    step(); // XORI -> 00
    step(); // OUT r2
    if (gpio_out !== 8'h00) errors = errors + 1;
    step(); // WAIT 0
    if (waiting !== 1'b0 || pc !== 5'd19) errors = errors + 1;
    step(); // JMP 21
    if (pc !== 5'd21) errors = errors + 1;
    step(); // HALT

    if (!halted || pc !== 5'd21 || gpio_out !== 8'h00) begin
        $display("ERROR: HALT state incorrect");
        errors = errors + 1;
    end

    repeat (3) begin
        step();
        if (!halted || pc !== 5'd21) errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: complete protocol processor ISA and timing verified");
    else
        $display("FAIL: protocol processor errors=%0d", errors);

    $finish;
end

initial begin
    #5000;
    $display("FAIL: protocol processor testbench timeout");
    $finish;
end

endmodule
