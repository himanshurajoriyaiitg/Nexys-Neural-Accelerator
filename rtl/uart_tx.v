`timescale 1ns / 1ps
`include "params.vh"

module uart_tx #(
    parameter integer CLK_HZ      = `DEFAULT_CLK_HZ,
    parameter integer BAUD        = `DEFAULT_UART_BAUD,
    parameter integer CLKS_PER_BIT = CLK_HZ / BAUD
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data_i,
    input  wire       start_i,
    output reg        tx_o,
    output reg        busy_o
);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_latched;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            clk_count   <= 16'd0;
            bit_index   <= 3'd0;
            data_latched <= 8'd0;
            tx_o        <= 1'b1;
            busy_o      <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    tx_o   <= 1'b1;
                    busy_o <= 1'b0;
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;

                    if (start_i) begin
                        data_latched <= data_i;
                        busy_o       <= 1'b1;
                        state        <= ST_START;
                    end
                end

                ST_START: begin
                    tx_o <= 1'b0;
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 16'd0;
                        state     <= ST_DATA;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_DATA: begin
                    tx_o <= data_latched[bit_index];
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 16'd0;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state     <= ST_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_STOP: begin
                    tx_o <= 1'b1;
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 16'd0;
                        state     <= ST_IDLE;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
