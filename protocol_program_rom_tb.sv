`timescale 1ns/1ps

module protocol_program_rom_tb;

reg  [3:0]  address;
wire [15:0] instruction;

integer errors;

protocol_program_rom dut (
    .address(address),
    .instruction(instruction)
);

task check_instruction;
    input [3:0]  test_address;
    input [15:0] expected_instruction;
    begin
        address = test_address;

        // Allow the combinational ROM output to update.
        #1;

        if (instruction !== expected_instruction)
        begin
            $display(
                "ERROR: address=%0d expected=0x%04h observed=0x%04h",
                address,
                expected_instruction,
                instruction
            );
            errors = errors + 1;
        end
    end
endtask

initial
begin
    address = 4'd0;
    errors = 0;

    check_instruction(4'd0, 16'h0001); // SET 1
    check_instruction(4'd1, 16'h4003); // WAIT 3
    check_instruction(4'd2, 16'h0000); // SET 0
    check_instruction(4'd3, 16'h4002); // WAIT 2
    check_instruction(4'd4, 16'h0001); // SET 1
    check_instruction(4'd5, 16'h4000); // WAIT 0
    check_instruction(4'd6, 16'h0000); // SET 0
    check_instruction(4'd7, 16'h8000); // HALT

    // Verify that an unused address returns the safe HALT instruction.
    check_instruction(4'd15, 16'h8000);

    if (errors == 0)
        $display("PASS: protocol program ROM verified");
    else
        $display("FAIL: errors=%0d", errors);

    $finish;
end

endmodule
