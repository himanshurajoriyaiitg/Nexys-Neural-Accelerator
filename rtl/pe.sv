`timescale 1ns / 1ps
`include "params.vh"

module pe #(
    parameter integer DW   = `DEFAULT_DW,
    parameter integer ACCW = `DEFAULT_ACCW
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clear_acc,
    input  wire                     en,
    input  wire signed [DW-1:0]     a_in,
    input  wire signed [DW-1:0]     b_in,
    output reg  signed [DW-1:0]     a_out,
    output reg  signed [DW-1:0]     b_out,
    output reg  signed [ACCW-1:0]   acc
);

    (* use_dsp = "yes" *) reg signed [2*DW-1:0] mult_term;

    always @(*) begin
        if (a_in != 0 && b_in != 0) begin
            mult_term = a_in * b_in;
        end else begin
            mult_term = '0; 
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= '0;
            b_out <= '0;
            acc   <= '0;
        end else if (clear_acc) begin
            a_out <= '0;
            b_out <= '0;
            acc   <= '0;
        end else begin
            a_out <= a_in;
            b_out <= b_in;

            if (en) begin
                acc <= acc + $signed(mult_term);
            end
        end
    end

endmodule
