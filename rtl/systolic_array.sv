`timescale 1ns / 1ps
`include "params.vh"

module systolic_array #(
    parameter integer ARRAY_N = `DEFAULT_ARRAY_N,
    parameter integer DW      = `DEFAULT_DW,
    parameter integer ACCW    = `DEFAULT_ACCW,
    parameter integer OVERFLOW_THRESH = (1 << (ACCW - 1)) - 1
)(
    input  wire                                 clk,
    input  wire                                 rst_n,
    input  wire                                 clear_acc,
    input  wire                                 en,
    input  wire signed [DW-1:0]                 a_in [0:ARRAY_N-1],
    input  wire signed [DW-1:0]                 b_in [0:ARRAY_N-1],
    output wire signed [ACCW-1:0]               c_out [0:ARRAY_N-1][0:ARRAY_N-1],
    output reg                                  overflow_any
);

    wire signed [DW-1:0] a_bus [0:ARRAY_N-1][0:ARRAY_N-1];
    wire signed [DW-1:0] b_bus [0:ARRAY_N-1][0:ARRAY_N-1];
    wire                 pe_overflow [0:ARRAY_N-1][0:ARRAY_N-1];
    integer              overflow_row_idx;
    integer              overflow_col_idx;

    genvar row_idx;
    genvar col_idx;
    generate
        for (row_idx = 0; row_idx < ARRAY_N; row_idx = row_idx + 1) begin : gen_rows
            for (col_idx = 0; col_idx < ARRAY_N; col_idx = col_idx + 1) begin : gen_cols
                pe #(
                    .DW              (DW),
                    .ACCW            (ACCW),
                    .OVERFLOW_THRESH (OVERFLOW_THRESH)
                ) u_pe (
                    .clk           (clk),
                    .rst_n         (rst_n),
                    .clear_acc     (clear_acc),
                    .en            (en),
                    .a_in          ((col_idx == 0) ? a_in[row_idx] : a_bus[row_idx][col_idx-1]),
                    .b_in          ((row_idx == 0) ? b_in[col_idx] : b_bus[row_idx-1][col_idx]),
                    .a_out         (a_bus[row_idx][col_idx]),
                    .b_out         (b_bus[row_idx][col_idx]),
                    .acc           (c_out[row_idx][col_idx]),
                    .overflow_flag (pe_overflow[row_idx][col_idx])
                );
            end
        end
    endgenerate

    always @(*) begin
        overflow_any = 1'b0;
        for (overflow_row_idx = 0; overflow_row_idx < ARRAY_N; overflow_row_idx = overflow_row_idx + 1) begin
            for (overflow_col_idx = 0; overflow_col_idx < ARRAY_N; overflow_col_idx = overflow_col_idx + 1) begin
                overflow_any = overflow_any | pe_overflow[overflow_row_idx][overflow_col_idx];
            end
        end
    end

endmodule
