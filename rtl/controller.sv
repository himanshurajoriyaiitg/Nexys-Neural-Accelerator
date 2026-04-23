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
    output reg [ADDRW-1:0]         clear_c_addr,
    output reg [TILE_IDX_W-1:0]    tile_row,
    output reg [TILE_IDX_W-1:0]    tile_col,
    output reg [TILE_IDX_W-1:0]    tile_k,
    output reg [TILE_IDX_W-1:0]    load_tile_k,
    output reg                     ping_pong_flag,
    output reg                     load_buf_sel,
    output reg [LOAD_W-1:0]        load_count,
    output reg [RUN_W-1:0]         run_count,
    output reg [WB_W-1:0]          wb_count
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_CLEAR_C   = 3'd1;
    localparam [2:0] ST_PRELOAD   = 3'd2;
    localparam [2:0] ST_CLEAR_ACC = 3'd3;
    localparam [2:0] ST_RUN       = 3'd4;
    localparam [2:0] ST_WRITEBACK = 3'd5;
    localparam [2:0] ST_DONE      = 3'd6;
    localparam [2:0] ST_WAIT_LOAD = 3'd7;

    reg [2:0] state;
    reg [ADDRW:0] active_matrix_elems;
    reg [TILE_COUNT_W-1:0] active_tile_count;
    reg [TILE_IDX_W-1:0] next_load_k;
    reg                  load_pending;
    reg [1:0]            buffer_ready;

    wire start_valid;
    wire [ADDRW:0] clear_c_last_ext;
    wire [ADDRW-1:0] clear_c_last;
    wire [TILE_IDX_W-1:0] tile_last;
    wire other_buf_ready;
    wire other_buf_will_be_ready;

    assign start_valid = (matrix_dim >= 1) && (matrix_dim <= N);
    assign clear_c_last_ext = active_matrix_elems - 1'b1;
    assign clear_c_last = clear_c_last_ext[ADDRW-1:0];
    assign tile_last = active_tile_count - 1'b1;
    assign other_buf_ready = ping_pong_flag ? buffer_ready[0] : buffer_ready[1];
    assign other_buf_will_be_ready =
        other_buf_ready || (load_pending && (load_count == TILE_ELEMS) && (load_buf_sel == ~ping_pong_flag));

    always @(*) begin
        clear_c_active   = (state == ST_CLEAR_C);
        load_active      = (state == ST_PRELOAD) || (((state == ST_RUN) || (state == ST_WAIT_LOAD)) && load_pending);
        writeback_active = (state == ST_WRITEBACK);
        clear_acc        = (state == ST_CLEAR_ACC);
        run_en           = (state == ST_RUN);
        busy             = (state != ST_IDLE) && (state != ST_DONE);
        done             = (state == ST_DONE);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            active_dim          <= '0;
            active_matrix_elems <= '0;
            active_tile_count   <= '0;
            clear_c_addr        <= '0;
            tile_row            <= '0;
            tile_col            <= '0;
            tile_k              <= '0;
            load_tile_k         <= '0;
            ping_pong_flag      <= 1'b0;
            load_buf_sel        <= 1'b0;
            load_count          <= '0;
            run_count           <= '0;
            wb_count            <= '0;
            next_load_k         <= '0;
            load_pending        <= 1'b0;
            buffer_ready        <= 2'b00;
        end else begin
            case (state)
                ST_IDLE: begin
                    clear_c_addr   <= '0;
                    tile_row       <= '0;
                    tile_col       <= '0;
                    tile_k         <= '0;
                    load_tile_k    <= '0;
                    ping_pong_flag <= 1'b0;
                    load_buf_sel   <= 1'b0;
                    load_count     <= '0;
                    run_count      <= '0;
                    wb_count       <= '0;
                    next_load_k    <= '0;
                    load_pending   <= 1'b0;
                    buffer_ready   <= 2'b00;

                    if (start && start_valid) begin
                        active_dim          <= matrix_dim;
                        active_matrix_elems <= matrix_dim * matrix_dim;
                        active_tile_count   <= (matrix_dim + ARRAY_N - 1) / ARRAY_N;
                        state               <= ST_CLEAR_C;
                    end
                end

                ST_CLEAR_C: begin
                    if (clear_c_addr == clear_c_last) begin
                        clear_c_addr   <= '0;
                        tile_row       <= '0;
                        tile_col       <= '0;
                        tile_k         <= '0;
                        load_tile_k    <= '0;
                        ping_pong_flag <= 1'b0;
                        load_buf_sel   <= 1'b0;
                        load_count     <= '0;
                        run_count      <= '0;
                        wb_count       <= '0;
                        next_load_k    <= 1;
                        load_pending   <= 1'b0;
                        buffer_ready   <= 2'b00;
                        state          <= ST_PRELOAD;
                    end else begin
                        clear_c_addr <= clear_c_addr + 1'b1;
                    end
                end

                ST_PRELOAD: begin
                    if (load_count == TILE_ELEMS) begin
                        buffer_ready[load_buf_sel] <= 1'b1;
                        load_count                 <= '0;
                        state                      <= ST_CLEAR_ACC;
                    end else begin
                        load_count <= load_count + 1'b1;
                    end
                end

                ST_CLEAR_ACC: begin
                    tile_k         <= '0;
                    ping_pong_flag <= 1'b0;
                    run_count      <= '0;

                    if (active_tile_count > 1) begin
                        load_pending    <= 1'b1;
                        load_buf_sel    <= 1'b1;
                        load_tile_k     <= 1;
                        load_count      <= '0;
                        buffer_ready[1] <= 1'b0;
                        if (active_tile_count > 2) begin
                            next_load_k <= 2;
                        end else begin
                            next_load_k <= active_tile_count[TILE_IDX_W-1:0];
                        end
                    end else begin
                        load_pending <= 1'b0;
                        load_count   <= '0;
                    end

                    state <= ST_RUN;
                end

                ST_RUN: begin
                    if (load_pending) begin
                        if (load_count == TILE_ELEMS) begin
                            buffer_ready[load_buf_sel] <= 1'b1;
                            load_count                 <= '0;
                            load_pending               <= 1'b0;
                        end else begin
                            load_count <= load_count + 1'b1;
                        end
                    end

                    if (run_count == RUN_LAST) begin
                        run_count <= '0;

                        if (tile_k == tile_last) begin
                            wb_count <= '0;
                            state    <= ST_WRITEBACK;
                        end else if (other_buf_will_be_ready) begin
                            if (ping_pong_flag) begin
                                ping_pong_flag <= 1'b0;
                            end else begin
                                ping_pong_flag <= 1'b1;
                            end

                            tile_k <= tile_k + 1'b1;

                            if (next_load_k <= tile_last) begin
                                load_pending <= 1'b1;
                                load_buf_sel <= ping_pong_flag;
                                load_tile_k  <= next_load_k;
                                load_count   <= '0;
                                buffer_ready[ping_pong_flag] <= 1'b0;
                                next_load_k  <= next_load_k + 1'b1;
                            end else begin
                                load_pending <= 1'b0;
                                load_count   <= '0;
                            end

                            if (ping_pong_flag) begin
                                buffer_ready[0] <= 1'b1;
                            end else begin
                                buffer_ready[1] <= 1'b1;
                            end
                        end else begin
                            state <= ST_WAIT_LOAD;
                        end
                    end else begin
                        run_count <= run_count + 1'b1;
                    end
                end

                ST_WAIT_LOAD: begin
                    if (load_pending) begin
                        if (load_count == TILE_ELEMS) begin
                            buffer_ready[load_buf_sel] <= 1'b1;
                            load_count                 <= '0;
                            load_pending               <= 1'b0;

                            if (ping_pong_flag) begin
                                ping_pong_flag <= 1'b0;
                                buffer_ready[0] <= 1'b1;
                            end else begin
                                ping_pong_flag <= 1'b1;
                                buffer_ready[1] <= 1'b1;
                            end

                            tile_k <= tile_k + 1'b1;

                            if (next_load_k <= tile_last) begin
                                load_pending <= 1'b1;
                                load_buf_sel <= ping_pong_flag;
                                load_tile_k  <= next_load_k;
                                buffer_ready[ping_pong_flag] <= 1'b0;
                                next_load_k  <= next_load_k + 1'b1;
                            end

                            state <= ST_RUN;
                        end else begin
                            load_count <= load_count + 1'b1;
                        end
                    end
                end

                ST_WRITEBACK: begin
                    if (wb_count == TILE_ELEMS) begin
                        wb_count       <= '0;
                        tile_k         <= '0;
                        load_tile_k    <= '0;
                        ping_pong_flag <= 1'b0;
                        load_buf_sel   <= 1'b0;
                        load_count     <= '0;
                        run_count      <= '0;
                        next_load_k    <= 1;
                        load_pending   <= 1'b0;
                        buffer_ready   <= 2'b00;

                        if (tile_col == tile_last) begin
                            tile_col <= '0;

                            if (tile_row == tile_last) begin
                                state <= ST_DONE;
                            end else begin
                                tile_row <= tile_row + 1'b1;
                                state    <= ST_PRELOAD;
                            end
                        end else begin
                            tile_col <= tile_col + 1'b1;
                            state    <= ST_PRELOAD;
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
