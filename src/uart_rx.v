`timescale 1ns / 1ps
`include "params.vh"

module uart_rx #(
    parameter integer CLK_HZ      = `DEFAULT_CLK_HZ,
    parameter integer BAUD        = `DEFAULT_UART_BAUD,
    parameter integer CLKS_PER_BIT = CLK_HZ / BAUD
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx_i,
    output reg [7:0]  data_o,
    output reg        valid_o
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_START = 3'd1;
    localparam [2:0] ST_DATA  = 3'd2;
    localparam [2:0] ST_STOP  = 3'd3;

    reg [2:0] state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_shift;
    reg        rx_meta;
    reg        rx_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            clk_count  <= 16'd0;
            bit_index  <= 3'd0;
            data_shift <= 8'd0;
            data_o     <= 8'd0;
            valid_o    <= 1'b0;
            rx_meta    <= 1'b1;
            rx_sync    <= 1'b1;
        end else begin
            rx_meta <= rx_i;
            rx_sync <= rx_meta;
            valid_o <= 1'b0;

            case (state)
                ST_IDLE: begin
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    if (!rx_sync) begin
                        state <= ST_START;
                    end
                end

                ST_START: begin
                    if (clk_count == ((CLKS_PER_BIT - 1) >> 1)) begin
                        if (!rx_sync) begin
                            clk_count <= 16'd0;
                            state     <= ST_DATA;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_DATA: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count            <= 16'd0;
                        data_shift[bit_index] <= rx_sync;

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
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        state     <= ST_IDLE;
                        clk_count <= 16'd0;
                        data_o    <= data_shift;
                        valid_o   <= 1'b1;
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
