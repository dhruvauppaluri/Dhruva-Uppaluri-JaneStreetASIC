`timescale 1ns/1ps

module uart_tx #(
    parameter CLKS_PER_BIT = 100
)(
    input wire       clk,
    input wire       reset,
    input wire       start,
    input wire [7:0] data,
    output reg        tx,
    output reg        busy,
    output reg        done
);

localparam [2:0] IDLE      = 3'd0;
localparam [2:0] START_BIT = 3'd1;
localparam [2:0] DATA_BITS = 3'd2;
localparam [2:0] STOP_BIT  = 3'd3;
localparam [2:0] DONE      = 3'd4;

reg [2:0]  state;
reg [15:0] clock_count;
reg [2:0]  bit_index;
reg [7:0]  data_shift;

always @(posedge clk)
begin
    if (reset)
    begin
        state       <= IDLE;
        clock_count <= 16'd0;
        bit_index   <= 3'd0;
        data_shift  <= 8'd0;
        tx          <= 1'b1;
        busy        <= 1'b0;
        done        <= 1'b0;
    end
    else
    begin
        // DONE overrides this for one clock when a frame completes.
        done <= 1'b0;

        case (state)
            IDLE:
            begin
                tx          <= 1'b1;
                busy        <= 1'b0;
                clock_count <= 16'd0;
                bit_index   <= 3'd0;

                if (start)
                begin
                    data_shift <= data;
                    busy       <= 1'b1;
                    state      <= START_BIT;
                end
            end

            START_BIT:
            begin
                tx   <= 1'b0;
                busy <= 1'b1;

                if (clock_count == CLKS_PER_BIT - 1)
                begin
                    clock_count <= 16'd0;
                    bit_index   <= 3'd0;
                    state       <= DATA_BITS;
                end
                else
                begin
                    clock_count <= clock_count + 1'b1;
                end
            end

            DATA_BITS:
            begin
                tx   <= data_shift[bit_index];
                busy <= 1'b1;

                if (clock_count == CLKS_PER_BIT - 1)
                begin
                    clock_count <= 16'd0;

                    if (bit_index == 3'd7)
                    begin
                        bit_index <= 3'd0;
                        state     <= STOP_BIT;
                    end
                    else
                    begin
                        bit_index <= bit_index + 1'b1;
                    end
                end
                else
                begin
                    clock_count <= clock_count + 1'b1;
                end
            end

            STOP_BIT:
            begin
                tx   <= 1'b1;
                busy <= 1'b1;

                if (clock_count == CLKS_PER_BIT - 1)
                begin
                    clock_count <= 16'd0;
                    state       <= DONE;
                end
                else
                begin
                    clock_count <= clock_count + 1'b1;
                end
            end

            DONE:
            begin
                tx    <= 1'b1;
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= IDLE;
            end

            default:
            begin
                state       <= IDLE;
                clock_count <= 16'd0;
                bit_index   <= 3'd0;
                data_shift  <= 8'd0;
                tx          <= 1'b1;
                busy        <= 1'b0;
                done        <= 1'b0;
            end
        endcase
    end
end

endmodule
