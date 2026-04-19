`timescale 1ns / 1ps
`include "params.vh"

module systolic_array #(
    parameter integer ARRAY_N = `DEFAULT_ARRAY_N,
    parameter integer DW      = `DEFAULT_DW,
    parameter integer ACCW    = `DEFAULT_ACCW
)(
    input  wire                                 clk,
    input  wire                                 rst_n,
    input  wire                                 clear_acc,
    input  wire                                 en,
    input  wire signed [DW-1:0]                 a_in [0:ARRAY_N-1],
    input  wire signed [DW-1:0]                 b_in [0:ARRAY_N-1],
    output wire signed [ACCW-1:0]               c_out [0:ARRAY_N-1][0:ARRAY_N-1]
);

    wire signed [DW-1:0] a_bus [0:ARRAY_N-1][0:ARRAY_N-1];
    wire signed [DW-1:0] b_bus [0:ARRAY_N-1][0:ARRAY_N-1];

    genvar row_idx;
    genvar col_idx;
    generate
        for (row_idx = 0; row_idx < ARRAY_N; row_idx = row_idx + 1) begin : gen_rows
            for (col_idx = 0; col_idx < ARRAY_N; col_idx = col_idx + 1) begin : gen_cols
                pe #(
                    .DW   (DW),
                    .ACCW (ACCW)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .clear_acc (clear_acc),
                    .en        (en),
                    .a_in      ((col_idx == 0) ? a_in[row_idx] : a_bus[row_idx][col_idx-1]),
                    .b_in      ((row_idx == 0) ? b_in[col_idx] : b_bus[row_idx-1][col_idx]),
                    .a_out     (a_bus[row_idx][col_idx]),
                    .b_out     (b_bus[row_idx][col_idx]),
                    .acc       (c_out[row_idx][col_idx])
                );
            end
        end
    endgenerate

endmodule
