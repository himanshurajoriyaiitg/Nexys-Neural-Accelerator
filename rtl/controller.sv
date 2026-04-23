`timescale 1ns / 1ps
`include "params.vh"

module controller #(
    parameter integer N              = `DEFAULT_MATRIX_N,
    parameter integer ARRAY_N        = `DEFAULT_ARRAY_N,
    parameter integer DIM_W          = ((N + 1) <= 1) ? 1 : $clog2(N + 1),
    parameter integer TILE_COUNT_MAX = (N + ARRAY_N - 1) / ARRAY_N,
    parameter integer MATRIX_ELEMS   = N * N,
    parameter integer TILE_ELEMS     = ARRAY_N * ARRAY_N,
    parameter integer RUN_LAST       = (3 * ARRAY_N) - 3,
    parameter integer ADDRW          = (MATRIX_ELEMS <= 1) ? 1 : $clog2(MATRIX_ELEMS),
    parameter integer TILE_IDX_W     = (TILE_COUNT_MAX <= 1) ? 1 : $clog2(TILE_COUNT_MAX),
    parameter integer TILE_COUNT_W   = ((TILE_COUNT_MAX + 1) <= 1) ? 1 : $clog2(TILE_COUNT_MAX + 1),
    parameter integer LOAD_W         = ((TILE_ELEMS + 1) <= 1) ? 1 : $clog2(TILE_ELEMS + 1),
    parameter integer RUN_W          = ((RUN_LAST + 1) <= 1) ? 1 : $clog2(RUN_LAST + 1),
    parameter integer WB_W           = ((TILE_ELEMS + 1) <= 1) ? 1 : $clog2(TILE_ELEMS + 1)
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire [DIM_W-1:0]        matrix_dim,

    output reg                     clear_c_active,
    output reg                     load_active,
    output reg                     writeback_active,
    output reg                     clear_acc,
    output reg                     run_en,
    output reg                     busy,
    output reg                     done,

    output reg [DIM_W-1:0]         active_dim,
    output reg [TILE_IDX_W-1:0]    tile_row,
    output reg [TILE_IDX_W-1:0]    tile_col,
    output reg [TILE_IDX_W-1:0]    tile_k,
    output reg [LOAD_W-1:0]        load_count,
    output reg [RUN_W-1:0]         run_count,
    output reg [WB_W-1:0]          wb_count
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_LOAD      = 3'd2;
    localparam [2:0] ST_CLEAR_ACC = 3'd3;
    localparam [2:0] ST_RUN       = 3'd4;
    localparam [2:0] ST_WRITEBACK = 3'd5;
    localparam [2:0] ST_DONE      = 3'd6;

    reg [2:0] state;
    reg [ADDRW:0] active_matrix_elems;
    reg [TILE_COUNT_W-1:0] active_tile_count;

    wire start_valid;
    wire [TILE_IDX_W-1:0] tile_last;

    assign start_valid = (matrix_dim >= 1) && (matrix_dim <= N);
    assign tile_last = active_tile_count - 1'b1;

    always @(*) begin
        clear_c_active   = 1'b0;
        load_active      = (state == ST_LOAD);
        writeback_active = (state == ST_WRITEBACK);
        clear_acc        = (state == ST_CLEAR_ACC);
        run_en           = (state == ST_RUN);
        busy             = (state != ST_IDLE) && (state != ST_DONE);
        done             = (state == ST_DONE);
    end

    // Active-low asynchronous reset returns the controller to IDLE from any state.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            active_dim          <= '0;
            active_tile_count   <= '0;
            tile_row            <= '0;
            tile_col            <= '0;
            tile_k              <= '0;
            load_count          <= '0;
            run_count           <= '0;
            wb_count            <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    tile_row     <= '0;
                    tile_col     <= '0;
                    tile_k       <= '0;
                    load_count   <= '0;
                    run_count    <= '0;
                    wb_count     <= '0;

                    if (start && start_valid) begin
                        active_dim          <= matrix_dim;
                        active_matrix_elems <= matrix_dim * matrix_dim;
                        active_tile_count   <= (matrix_dim + ARRAY_N - 1) / ARRAY_N;
                        state               <= ST_LOAD;
                    end
                end


                ST_LOAD: begin
                    if (load_count == TILE_ELEMS) begin
                        load_count <= '0;
                        state      <= ST_CLEAR_ACC;
                    end else begin
                        load_count <= load_count + 1'b1;
                    end
                end

                ST_CLEAR_ACC: begin
                    run_count <= '0;
                    state     <= ST_RUN;
                end

                ST_RUN: begin
                    if (run_count == RUN_LAST) begin
                        run_count <= '0;
                        wb_count  <= '0;
                        state     <= ST_WRITEBACK;
                    end else begin
                        run_count <= run_count + 1'b1;
                    end
                end

                ST_WRITEBACK: begin
                    if (wb_count == TILE_ELEMS) begin
                        wb_count <= '0;

                        if (tile_k == tile_last) begin
                            tile_k <= '0;

                            if (tile_col == tile_last) begin
                                tile_col <= '0;

                                if (tile_row == tile_last) begin
                                    state <= ST_DONE;
                                end else begin
                                    tile_row   <= tile_row + 1'b1;
                                    load_count <= '0;
                                    state      <= ST_LOAD;
                                end
                            end else begin
                                tile_col   <= tile_col + 1'b1;
                                load_count <= '0;
                                state      <= ST_LOAD;
                            end
                        end else begin
                            tile_k     <= tile_k + 1'b1;
                            load_count <= '0;
                            state      <= ST_LOAD;
                        end
                    end else begin
                        wb_count <= wb_count + 1'b1;
                    end
                end

                ST_DONE: begin
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
