`timescale 1ns/1ps
`default_nettype none

// Tiny programmable linear classifier for protocol-activity signatures.
// It measures transitions and high cycles on protocol pins 0 and 1 over a
// fixed 32-clock window, then evaluates four signed INT8 weights plus a signed
// 16-bit bias using one time-multiplexed multiplier.
module protocol_classifier (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,
    input  wire [7:0]  gpio_in,
    input  wire        config_we,
    input  wire [2:0]  config_address,
    input  wire [15:0] config_data,
    output reg         class_result,
    output reg         class_valid
);

reg signed [7:0] weights [0:3];
reg signed [15:0] bias;
reg [7:0] features [0:3];

reg [4:0] window_count;
reg [7:0] edge_count_0;
reg [7:0] high_count_0;
reg [7:0] edge_count_1;
reg [7:0] high_count_1;
reg last_pin_0;
reg last_pin_1;

reg scoring;
reg [1:0] score_index;
reg signed [23:0] accumulator;

wire transition_0 = gpio_in[0] ^ last_pin_0;
wire transition_1 = gpio_in[1] ^ last_pin_1;
wire signed [8:0] selected_feature =
    $signed({1'b0, features[score_index]});
wire signed [7:0] selected_weight = weights[score_index];
wire signed [16:0] product = selected_feature * selected_weight;
wire signed [23:0] next_score =
    accumulator + {{7{product[16]}}, product};
wire _unused = &{gpio_in[7:2], 1'b0};

always @(posedge clk) begin
    if (config_we) begin
        case (config_address)
            3'd0: weights[0] <= config_data[7:0];
            3'd1: weights[1] <= config_data[7:0];
            3'd2: weights[2] <= config_data[7:0];
            3'd3: weights[3] <= config_data[7:0];
            3'd4: bias <= config_data;
            default: begin end
        endcase
    end

    if (reset) begin
        weights[0] <= 8'sd0;
        weights[1] <= 8'sd0;
        weights[2] <= 8'sd0;
        weights[3] <= 8'sd0;
        bias <= 16'sd0;
        features[0] <= 8'd0;
        features[1] <= 8'd0;
        features[2] <= 8'd0;
        features[3] <= 8'd0;
        window_count <= 5'd0;
        edge_count_0 <= 8'd0;
        high_count_0 <= 8'd0;
        edge_count_1 <= 8'd0;
        high_count_1 <= 8'd0;
        last_pin_0 <= 1'b0;
        last_pin_1 <= 1'b0;
        scoring <= 1'b0;
        score_index <= 2'd0;
        accumulator <= 24'sd0;
        class_result <= 1'b0;
        class_valid <= 1'b0;
    end else begin
        class_valid <= 1'b0;

        if (enable) begin
            last_pin_0 <= gpio_in[0];
            last_pin_1 <= gpio_in[1];

            if (window_count == 5'd31) begin
                features[0] <= edge_count_0 + {7'd0, transition_0};
                features[1] <= high_count_0 + {7'd0, gpio_in[0]};
                features[2] <= edge_count_1 + {7'd0, transition_1};
                features[3] <= high_count_1 + {7'd0, gpio_in[1]};
                window_count <= 5'd0;
                edge_count_0 <= 8'd0;
                high_count_0 <= 8'd0;
                edge_count_1 <= 8'd0;
                high_count_1 <= 8'd0;
                scoring <= 1'b1;
                score_index <= 2'd0;
                accumulator <= {{8{bias[15]}}, bias};
            end else begin
                window_count <= window_count + 5'd1;
                edge_count_0 <= edge_count_0 + {7'd0, transition_0};
                high_count_0 <= high_count_0 + {7'd0, gpio_in[0]};
                edge_count_1 <= edge_count_1 + {7'd0, transition_1};
                high_count_1 <= high_count_1 + {7'd0, gpio_in[1]};
            end

            if (scoring) begin
                if (score_index == 2'd3) begin
                    class_result <= !next_score[23];
                    class_valid <= 1'b1;
                    scoring <= 1'b0;
                end else begin
                    accumulator <= next_score;
                    score_index <= score_index + 2'd1;
                end
            end
        end
    end
end

endmodule

`default_nettype wire
