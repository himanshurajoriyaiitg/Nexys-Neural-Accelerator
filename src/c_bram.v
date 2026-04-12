`timescale 1ns / 1ps
`include "params.vh"

module c_bram #(
    parameter integer N      = `DEFAULT_MATRIX_N,
    parameter integer ACCW   = `DEFAULT_ACCW,
    parameter integer DEPTH  = N * N,
    parameter integer ADDRW  = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
)(
    input  wire                       clk,
    input  wire                       wr_en,
    input  wire [ADDRW-1:0]           wr_addr,
    input  wire signed [ACCW-1:0]     wr_data,
    input  wire [ADDRW-1:0]           rd_addr,
    output reg  signed [ACCW-1:0]     rd_data
);
    (* ram_style = "block" *) reg signed [ACCW-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            mem[i] = '0;
        end
    end

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        rd_data <= mem[rd_addr];
    end

endmodule