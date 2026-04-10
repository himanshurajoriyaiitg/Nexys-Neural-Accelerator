// =============================================================================
// systolic_array.sv  -  N×N grid of Processing Elements
//
// Data flow:
//   a_in[i]  → feeds the LEFT  edge of row i, propagates right
//   b_in[j]  → feeds the TOP   edge of col j, propagates downward
//   c_out[i][j] = accumulated dot-product at PE(i,j)
//
// clear_acc is broadcast globally to zero every PE before a new run.
// =============================================================================
module systolic_array #(
    parameter int N    = 4,
    parameter int DW   = 8,
    parameter int ACCW = 21
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     clear_acc,
    input  logic                     en,
    input  logic signed [DW-1:0]     a_in  [0:N-1],   // one value per row
    input  logic signed [DW-1:0]     b_in  [0:N-1],   // one value per col
    output logic signed [ACCW-1:0]   c_out [0:N-1][0:N-1]
);

    // Internal buses:
    //   a_bus[i][j] = a_out of PE(i,j)  →  a_in of PE(i,j+1)
    //   b_bus[i][j] = b_out of PE(i,j)  →  b_in of PE(i+1,j)
    logic signed [DW-1:0] a_bus [0:N-1][0:N-1];
    logic signed [DW-1:0] b_bus [0:N-1][0:N-1];

    genvar i, j;
    generate
        for (i = 0; i < N; i++) begin : row_gen
            for (j = 0; j < N; j++) begin : col_gen
                pe #(
                    .DW   (DW),
                    .ACCW (ACCW)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .clear_acc (clear_acc),
                    .en        (en),
                    .a_in      ((j == 0) ? a_in[i]       : a_bus[i][j-1]),
                    .b_in      ((i == 0) ? b_in[j]       : b_bus[i-1][j]),
                    .a_out     (a_bus[i][j]),
                    .b_out     (b_bus[i][j]),
                    .acc       (c_out[i][j])
                );
            end
        end
    endgenerate

endmodule