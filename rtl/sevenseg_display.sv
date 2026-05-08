`timescale 1ns / 1ps

module sevenseg_display #(
    parameter integer CLK_HZ = 25_000_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       value_valid,
    input  wire [7:0] value,
    output reg  [6:0] seg,
    output reg        dp,
    output reg  [7:0] an
);

    reg [15:0] refresh_ctr;
    localparam integer SCAN_COUNTER_BIT = (CLK_HZ >= 50_000_000) ? 15 : 14;
    wire       scan_hi;
    wire       show_high_digit;
    wire [3:0] low_nibble;
    wire [3:0] high_nibble;
    reg  [3:0] active_nibble;

    function automatic [6:0] decode_hex;
        input [3:0] nibble;
        begin
            case (nibble)
                4'h0: decode_hex = 7'b1000000;
                4'h1: decode_hex = 7'b1111001;
                4'h2: decode_hex = 7'b0100100;
                4'h3: decode_hex = 7'b0110000;
                4'h4: decode_hex = 7'b0011001;
                4'h5: decode_hex = 7'b0010010;
                4'h6: decode_hex = 7'b0000010;
                4'h7: decode_hex = 7'b1111000;
                4'h8: decode_hex = 7'b0000000;
                4'h9: decode_hex = 7'b0010000;
                4'hA: decode_hex = 7'b0001000;
                4'hB: decode_hex = 7'b0000011;
                4'hC: decode_hex = 7'b1000110;
                4'hD: decode_hex = 7'b0100001;
                4'hE: decode_hex = 7'b0000110;
                4'hF: decode_hex = 7'b0001110;
                default: decode_hex = 7'b1111111;
            endcase
        end
    endfunction

    assign scan_hi = refresh_ctr[SCAN_COUNTER_BIT];
    assign low_nibble = value[3:0];
    assign high_nibble = value[7:4];
    assign show_high_digit = value_valid && (value >= 8'd10);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_ctr <= 16'd0;
        end else begin
            refresh_ctr <= refresh_ctr + 16'd1;
        end
    end

    always @(*) begin
        seg = 7'b1111111;
        dp  = 1'b1;
        an  = 8'hFF;
        active_nibble = 4'h0;

        if (value_valid) begin
            if (!scan_hi) begin
                an = 8'b11111110;
                active_nibble = low_nibble;
                seg = decode_hex(active_nibble);
            end else if (show_high_digit) begin
                an = 8'b11111101;
                active_nibble = high_nibble;
                seg = decode_hex(active_nibble);
            end
        end
    end

endmodule
