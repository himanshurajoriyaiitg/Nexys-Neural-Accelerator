`timescale 1ns / 1ps
`include "params.vh"

module tpu_top #(
    parameter integer N       = `DEFAULT_MATRIX_N,
    parameter integer ARRAY_N = `DEFAULT_ARRAY_N,
    parameter integer DW      = `DEFAULT_DW,
    parameter integer DIM_W   = ((N + 1) <= 1) ? 1 : $clog2(N + 1),
    parameter integer ACCW    = 2*DW + $clog2(N),
    parameter integer ADDRW   = ((N*N) <= 1) ? 1 : $clog2(N*N),
    parameter integer RUN_W   = ((((3 * ARRAY_N) - 2) <= 1) ? 1 : $clog2((3 * ARRAY_N) - 2))
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    input  wire [DIM_W-1:0]         matrix_dim,
    output wire                     busy,
    output wire                     done,
    output reg  [31:0]              cycle_count,
    output wire                     debug_run_active,
    output wire [RUN_W-1:0]         debug_run_count,
    output wire [DIM_W-1:0]         active_matrix_dim,

    input  wire                     a_wr_en,
    input  wire                     b_wr_en,
    input  wire [ADDRW-1:0]         a_wr_addr,
    input  wire [ADDRW-1:0]         b_wr_addr,
    input  wire signed [DW-1:0]     a_wr_data,
    input  wire signed [DW-1:0]     b_wr_data,

    input  wire [ADDRW-1:0]         c_host_rd_addr,
    output reg  signed [ACCW-1:0]   c_host_rd_data
);

    function integer clog2_safe;
        input integer value;
        begin
            if (value <= 1) begin
                clog2_safe = 1;
            end else begin
                clog2_safe = $clog2(value);
            end
        end
    endfunction

    localparam integer TILE_COUNT_MAX = (N + ARRAY_N - 1) / ARRAY_N;
    localparam integer MATRIX_ELEMS   = N * N;
    localparam integer TILE_ELEMS     = ARRAY_N * ARRAY_N;
    localparam integer MATRIX_ADDRW   = clog2_safe(MATRIX_ELEMS);
    localparam integer TILE_IDX_W     = clog2_safe(TILE_COUNT_MAX);
    localparam integer LOCAL_IDX_W    = clog2_safe(ARRAY_N);
    localparam integer LOAD_W         = clog2_safe(TILE_ELEMS + 1);
    localparam integer WB_W           = clog2_safe(TILE_ELEMS + 1);

    wire clear_c_active;
    wire load_active;
    wire writeback_active;
    wire clear_acc;
    wire run_en;

    wire [DIM_W-1:0]       active_dim;
    wire [MATRIX_ADDRW-1:0] clear_c_addr;
    wire [TILE_IDX_W-1:0]  tile_row;
    wire [TILE_IDX_W-1:0]  tile_col;
    wire [TILE_IDX_W-1:0]  tile_k;
    wire [LOAD_W-1:0]      load_count;
    wire [RUN_W-1:0]       run_count;
    wire [WB_W-1:0]        wb_count;

    reg  [MATRIX_ADDRW-1:0] a_rd_addr;
    reg  [MATRIX_ADDRW-1:0] b_rd_addr;
    reg  [MATRIX_ADDRW-1:0] c_rd_addr;
    wire signed [DW-1:0]    a_rd_data;
    wire signed [DW-1:0]    b_rd_data;
    wire signed [ACCW-1:0]  c_rd_data;

    reg                     a_issue_valid;
    reg                     b_issue_valid;
    reg                     c_issue_valid;
    reg                     load_meta_valid;
    reg                     load_a_valid_d;
    reg                     load_b_valid_d;
    reg  [LOCAL_IDX_W-1:0]  load_row_d;
    reg  [LOCAL_IDX_W-1:0]  load_col_d;
    reg                     wb_meta_valid;
    reg  [LOCAL_IDX_W-1:0]  wb_row_d;
    reg  [LOCAL_IDX_W-1:0]  wb_col_d;
    reg  [MATRIX_ADDRW-1:0] wb_addr_d;

    reg                     c_wr_en;
    reg  [MATRIX_ADDRW-1:0] c_wr_addr;
    reg  signed [ACCW-1:0]  c_wr_data;

    reg  signed [DW-1:0]    a_tile [0:ARRAY_N-1][0:ARRAY_N-1];
    reg  signed [DW-1:0]    b_tile [0:ARRAY_N-1][0:ARRAY_N-1];
    reg  signed [DW-1:0]    a_feed [0:ARRAY_N-1];
    reg  signed [DW-1:0]    b_feed [0:ARRAY_N-1];
    wire signed [ACCW-1:0]  partial_tile [0:ARRAY_N-1][0:ARRAY_N-1];

    integer load_row_now;
    integer load_col_now;
    integer load_a_global_row;
    integer load_a_global_col;
    integer load_b_global_row;
    integer load_b_global_col;
    integer wb_row_now;
    integer wb_col_now;
    integer wb_global_row;
    integer wb_global_col;
    integer feed_idx;
    integer feed_delta;
    integer row_idx;
    integer col_idx;

    controller #(
        .N       (N),
        .ARRAY_N (ARRAY_N),
        .DIM_W   (DIM_W),
        .ADDRW   (MATRIX_ADDRW),
        .RUN_W   (RUN_W)
    ) u_controller (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .matrix_dim       (matrix_dim),
        .clear_c_active   (clear_c_active),
        .load_active      (load_active),
        .writeback_active (writeback_active),
        .clear_acc        (clear_acc),
        .run_en           (run_en),
        .busy             (busy),
        .done             (done),
        .active_dim       (active_dim),
        .clear_c_addr     (clear_c_addr),
        .tile_row         (tile_row),
        .tile_col         (tile_col),
        .tile_k           (tile_k),
        .load_count       (load_count),
        .run_count        (run_count),
        .wb_count         (wb_count)
    );

    assign active_matrix_dim = active_dim;
    assign debug_run_active  = run_en;
    assign debug_run_count   = run_count;

    a_bram #(
        .N     (N),
        .DW    (DW),
        .DEPTH (MATRIX_ELEMS),
        .ADDRW (MATRIX_ADDRW)
    ) u_a_bram (
        .clk     (clk),
        .wr_en   (a_wr_en),
        .wr_addr (a_wr_addr),
        .wr_data (a_wr_data),
        .rd_addr (a_rd_addr),
        .rd_data (a_rd_data)
    );

    b_bram #(
        .N     (N),
        .DW    (DW),
        .DEPTH (MATRIX_ELEMS),
        .ADDRW (MATRIX_ADDRW)
    ) u_b_bram (
        .clk     (clk),
        .wr_en   (b_wr_en),
        .wr_addr (b_wr_addr),
        .wr_data (b_wr_data),
        .rd_addr (b_rd_addr),
        .rd_data (b_rd_data)
    );

    c_bram #(
        .N     (N),
        .ACCW  (ACCW),
        .DEPTH (MATRIX_ELEMS),
        .ADDRW (MATRIX_ADDRW)
    ) u_c_bram (
        .clk     (clk),
        .wr_en   (c_wr_en),
        .wr_addr (c_wr_addr),
        .wr_data (c_wr_data),
        .rd_addr (c_rd_addr),
        .rd_data (c_rd_data)
    );

    systolic_array #(
        .ARRAY_N (ARRAY_N),
        .DW      (DW),
        .ACCW    (ACCW)
    ) u_systolic_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear_acc (clear_acc),
        .en        (run_en),
        .a_in      (a_feed),
        .b_in      (b_feed),
        .c_out     (partial_tile)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 32'd0;
        end else if (start && !busy) begin
            cycle_count <= 32'd0;
        end else if (busy) begin
            cycle_count <= cycle_count + 1'b1;
        end
    end

    always @(*) begin
        load_row_now      = 0;
        load_col_now      = 0;
        load_a_global_row = 0;
        load_a_global_col = 0;
        load_b_global_row = 0;
        load_b_global_col = 0;

        a_issue_valid = 1'b0;
        b_issue_valid = 1'b0;
        a_rd_addr     = '0;
        b_rd_addr     = '0;

        if (load_active && (load_count < TILE_ELEMS)) begin
            load_row_now = load_count / ARRAY_N;
            load_col_now = load_count % ARRAY_N;

            load_a_global_row = (tile_row * ARRAY_N) + load_row_now;
            load_a_global_col = (tile_k   * ARRAY_N) + load_col_now;
            load_b_global_row = (tile_k   * ARRAY_N) + load_row_now;
            load_b_global_col = (tile_col * ARRAY_N) + load_col_now;

            if ((load_a_global_row < active_dim) && (load_a_global_col < active_dim)) begin
                a_issue_valid = 1'b1;
                a_rd_addr     = (load_a_global_row * active_dim) + load_a_global_col;
            end

            if ((load_b_global_row < active_dim) && (load_b_global_col < active_dim)) begin
                b_issue_valid = 1'b1;
                b_rd_addr     = (load_b_global_row * active_dim) + load_b_global_col;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_meta_valid <= 1'b0;
            load_a_valid_d  <= 1'b0;
            load_b_valid_d  <= 1'b0;
            load_row_d      <= '0;
            load_col_d      <= '0;
            wb_meta_valid   <= 1'b0;
            wb_row_d        <= '0;
            wb_col_d        <= '0;
            wb_addr_d       <= '0;

            for (row_idx = 0; row_idx < ARRAY_N; row_idx = row_idx + 1) begin
                for (col_idx = 0; col_idx < ARRAY_N; col_idx = col_idx + 1) begin
                    a_tile[row_idx][col_idx] <= '0;
                    b_tile[row_idx][col_idx] <= '0;
                end
            end
        end else begin
            if (load_active && (load_count > 0) && load_meta_valid) begin
                a_tile[load_row_d][load_col_d] <= load_a_valid_d ? a_rd_data : '0;
                b_tile[load_row_d][load_col_d] <= load_b_valid_d ? b_rd_data : '0;
            end

            if (load_active && (load_count < TILE_ELEMS)) begin
                load_meta_valid <= 1'b1;
                load_a_valid_d  <= a_issue_valid;
                load_b_valid_d  <= b_issue_valid;
                load_row_d      <= load_row_now[LOCAL_IDX_W-1:0];
                load_col_d      <= load_col_now[LOCAL_IDX_W-1:0];
            end else begin
                load_meta_valid <= 1'b0;
                load_a_valid_d  <= 1'b0;
                load_b_valid_d  <= 1'b0;
            end

            if (writeback_active && (wb_count < TILE_ELEMS)) begin
                wb_meta_valid <= c_issue_valid;
                wb_row_d      <= wb_row_now[LOCAL_IDX_W-1:0];
                wb_col_d      <= wb_col_now[LOCAL_IDX_W-1:0];
                wb_addr_d     <= c_rd_addr;
            end else begin
                wb_meta_valid <= 1'b0;
            end
        end
    end

    always @(*) begin
        wb_row_now    = 0;
        wb_col_now    = 0;
        wb_global_row = 0;
        wb_global_col = 0;

        c_issue_valid = 1'b0;

        if (writeback_active) begin
            c_rd_addr = '0;
        end else begin
            c_rd_addr = c_host_rd_addr;
        end

        if (writeback_active && (wb_count < TILE_ELEMS)) begin
            wb_row_now    = wb_count / ARRAY_N;
            wb_col_now    = wb_count % ARRAY_N;
            wb_global_row = (tile_row * ARRAY_N) + wb_row_now;
            wb_global_col = (tile_col * ARRAY_N) + wb_col_now;

            if ((wb_global_row < active_dim) && (wb_global_col < active_dim)) begin
                c_issue_valid = 1'b1;
                c_rd_addr     = (wb_global_row * active_dim) + wb_global_col;
            end
        end
    end

    always @(*) begin
        c_wr_en        = 1'b0;
        c_wr_addr      = '0;
        c_wr_data      = '0;
        c_host_rd_data = c_rd_data;

        if (clear_c_active) begin
            c_wr_en   = 1'b1;
            c_wr_addr = clear_c_addr;
            c_wr_data = '0;
        end else if (wb_meta_valid) begin
            c_wr_en   = 1'b1;
            c_wr_addr = wb_addr_d;
            c_wr_data = (tile_k == '0)
                ? $signed(partial_tile[wb_row_d][wb_col_d])
                : c_rd_data + partial_tile[wb_row_d][wb_col_d];
        end
    end

    always @(*) begin
        for (feed_idx = 0; feed_idx < ARRAY_N; feed_idx = feed_idx + 1) begin
            feed_delta       = run_count - feed_idx;
            a_feed[feed_idx] = '0;
            b_feed[feed_idx] = '0;

            if (run_en) begin
                if ((run_count >= feed_idx) && (feed_delta < ARRAY_N)) begin
                    a_feed[feed_idx] = a_tile[feed_idx][feed_delta];
                    b_feed[feed_idx] = b_tile[feed_delta][feed_idx];
                end
            end
        end
    end

endmodule
