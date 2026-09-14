module pin_generator (
    input wire       clk,
    input wire       reset,
    input wire       enable,
    input wire [3:0] cycles_per_toggle,
    output reg        pin_out
);

reg [3:0] counter;

always @(posedge clk)
begin
    if (reset)
    begin
        counter <= 4'd0;
        pin_out <= 1'b0;
    end
    else if (enable)
    begin
        if (cycles_per_toggle == 0)
            begin
                counter <= 4'd0;
                pin_out <= 1'b0;
            end
        else if (counter == cycles_per_toggle - 1'b1)
        begin
            counter <= 4'd0;
            pin_out <= ~pin_out;
        end
        else
        begin
            counter <= counter + 1'b1;
        end
    end
end
endmodule
