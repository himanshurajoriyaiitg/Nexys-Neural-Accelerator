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
    input  wire [1:0]               act_mode,
    input  wire                     enable_bias,
    input  wire                     enable_pool,
    input  wire [DIM_W-1:0]         matrix_dim,
    output wire                     busy,
    output wire                     done,
    output reg  [31:0]              cycle_count,
    output wire                     debug_run_active,
    output wire [RUN_W-1:0]         debug_run_count,
    output wire                     debug_clear_c_active,
    output wire                     debug_load_active,
    output wire                     debug_writeback_active,
    output wire                     debug_clear_acc,
    output wire [2:0]               debug_state,
    output wire                     debug_buf_sel,
    output wire                     debug_load_buf_sel,
    output wire [15:0]              debug_load_count,
    output wire [15:0]              debug_wb_count,
    output wire [15:0]              debug_clear_c_addr,
    output reg                      overflow_flag,
    output wire [DIM_W-1:0]         active_matrix_dim,
    output reg  [31:0]              profile_clear_c_cycles,
    output reg  [31:0]              profile_preload_cycles,
    output reg  [31:0]              profile_clear_acc_cycles,
    output reg  [31:0]              profile_run_cycles,
    output reg  [31:0]              profile_wait_load_cycles,
    output reg  [31:0]              profile_writeback_cycles,
    output reg  [31:0]              profile_load_overlap_cycles,
    output reg  [31:0]              profile_buffer_swap_count,
    output reg  [31:0]              profile_output_tile_count,
    output reg  [31:0]              profile_k_pass_count,
    output reg  [31:0]              profile_result_signature,

    input  wire                     a_wr_en,
    input  wire                     b_wr_en,
    input  wire                     bias_wr_en,
    input  wire [ADDRW-1:0]         a_wr_addr,
    input  wire [ADDRW-1:0]         b_wr_addr,
    input  wire [DIM_W-1:0]         bias_wr_addr,
    input  wire signed [DW-1:0]     a_wr_data,
    input  wire signed [DW-1:0]     b_wr_data,
    input  wire signed [DW-1:0]     bias_wr_data,

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

    function automatic signed [ACCW-1:0] apply_activation_fn;
        input signed [ACCW-1:0] value;
        input [1:0] mode;
        begin
            case (mode)
                2'b01: begin
                    if (value > $signed(0)) begin
                        apply_activation_fn = value;
                    end else begin
                        apply_activation_fn = $signed({(ACCW){1'b0}});
                    end
                end

                2'b10: begin
                    if (value > $signed(0)) begin
                        apply_activation_fn = value;
                    end else begin
                        apply_activation_fn = value >>> 2;
                    end
                end

                default: begin
                    apply_activation_fn = value;
                end
            endcase
        end
    endfunction

    localparam integer TILE_COUNT_MAX = (N + ARRAY_N - 1) / ARRAY_N;
    localparam integer MATRIX_ELEMS   = N * N;
    localparam integer TILE_ELEMS     = ARRAY_N * ARRAY_N;
    localparam integer HALF_ARRAY_N   = ((ARRAY_N / 2) > 0) ? (ARRAY_N / 2) : 1;
    localparam integer POOL_TILE_ELEMS = (TILE_ELEMS / 4) > 0 ? (TILE_ELEMS / 4) : 1;
    localparam integer MATRIX_ADDRW   = clog2_safe(MATRIX_ELEMS);
    localparam integer TILE_IDX_W     = clog2_safe(TILE_COUNT_MAX);
    localparam integer LOCAL_IDX_W    = clog2_safe(ARRAY_N);
    localparam integer LOAD_W         = clog2_safe(TILE_ELEMS + 1);
    localparam integer WB_W           = clog2_safe(TILE_ELEMS + 1);
    localparam integer RUN_LAST       = (3 * ARRAY_N) - 3;
    localparam [2:0] ST_IDLE          = 3'd0;
    localparam [2:0] ST_CLEAR_C       = 3'd1;
    localparam [2:0] ST_PRELOAD       = 3'd2;
    localparam [2:0] ST_CLEAR_ACC     = 3'd3;
    localparam [2:0] ST_RUN           = 3'd4;
    localparam [2:0] ST_WAIT_LOAD     = 3'd5;
    localparam [2:0] ST_WRITEBACK     = 3'd6;
    localparam [2:0] ST_DONE          = 3'd7;

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
    wire [TILE_IDX_W-1:0]  load_tile_row;
    wire [TILE_IDX_W-1:0]  load_tile_col;
    wire [TILE_IDX_W-1:0]  load_tile_k;
    wire                   buf_sel;
    wire                   load_buf_sel;
    wire [LOAD_W-1:0]      load_count;
    wire [RUN_W-1:0]       run_count;
    wire [WB_W-1:0]        wb_count;
    wire [2:0]             controller_state;

    reg  [MATRIX_ADDRW-1:0] a_rd_addr;
    reg  [MATRIX_ADDRW-1:0] b_rd_addr;
    reg  [MATRIX_ADDRW-1:0] c_rd_addr;
    wire signed [DW-1:0]    a_rd_data;
    wire signed [DW-1:0]    b_rd_data;
    wire signed [ACCW-1:0]  c_rd_data;

    reg                     a_issue_valid;
    reg                     b_issue_valid;
    reg                     load_meta_valid;
    reg                     load_a_valid_d;
    reg                     load_b_valid_d;
    reg                     load_buf_sel_d;
    reg  [LOCAL_IDX_W-1:0]  load_row_d;
    reg  [LOCAL_IDX_W-1:0]  load_col_d;

    reg                     c_wr_en;
    reg  [MATRIX_ADDRW-1:0] c_wr_addr;
    reg  signed [ACCW-1:0]  c_wr_data;

    reg  signed [DW-1:0]    a_tile [0:1][0:ARRAY_N-1][0:ARRAY_N-1];
    reg  signed [DW-1:0]    b_tile [0:1][0:ARRAY_N-1][0:ARRAY_N-1];
    reg  signed [DW-1:0]    bias_mem [0:N-1];
    reg  signed [DW-1:0]    a_feed [0:ARRAY_N-1];
    reg  signed [DW-1:0]    b_feed [0:ARRAY_N-1];
    wire signed [ACCW-1:0]  partial_tile [0:ARRAY_N-1][0:ARRAY_N-1];
    wire                    array_overflow_any;
    wire signed [31:0]      c_wr_data_ext;

    integer pool_row_now;
    integer pool_col_now;
    wire [LOCAL_IDX_W-1:0] base_r;
    wire [LOCAL_IDX_W-1:0] base_c;
    wire [LOCAL_IDX_W-1:0] base_r_next;
    wire [LOCAL_IDX_W-1:0] base_c_next;
    wire [DIM_W-1:0] global_c_base;
    wire [DIM_W-1:0] global_c_base_next;
    wire signed [ACCW-1:0] pool_elems [0:3];
    wire signed [DW-1:0]   pool_bias  [0:3];
    wire signed [ACCW-1:0] pool_pre   [0:3];
    wire signed [ACCW-1:0] pool_post  [0:3];
    wire signed [ACCW-1:0] max_01;
    wire signed [ACCW-1:0] max_23;
    wire signed [ACCW-1:0] max_all;
    wire signed [ACCW-1:0] final_wr_data;
    wire                   mode_passthrough;
    integer out_dim;
    integer out_global_row;
    integer out_global_col;

    reg                     buf_sel_prev;

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
    integer buf_idx;
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
        .debug_state      (controller_state),
        .active_dim       (active_dim),
        .clear_c_addr     (clear_c_addr),
        .tile_row         (tile_row),
        .tile_col         (tile_col),
        .tile_k           (tile_k),
        .load_tile_row    (load_tile_row),
        .load_tile_col    (load_tile_col),
        .load_tile_k      (load_tile_k),
        .buf_sel          (buf_sel),
        .load_buf_sel     (load_buf_sel),
        .load_count       (load_count),
        .run_count        (run_count),
        .wb_count         (wb_count)
    );

    assign active_matrix_dim = active_dim;
    assign debug_run_active  = run_en;
    assign debug_run_count   = run_count;
    assign debug_clear_c_active = clear_c_active;
    assign debug_load_active = load_active;
    assign debug_writeback_active = writeback_active;
    assign debug_clear_acc = clear_acc;
    assign debug_state = controller_state;
    assign debug_buf_sel = buf_sel;
    assign debug_load_buf_sel = load_buf_sel;
    assign debug_load_count = load_count;
    assign debug_wb_count = wb_count;
    assign debug_clear_c_addr = clear_c_addr;
    assign c_wr_data_ext = {{(32-ACCW){c_wr_data[ACCW-1]}}, c_wr_data};
    assign mode_passthrough = !enable_bias && !enable_pool && (act_mode == 2'b00);

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
        .c_out     (partial_tile),
        .overflow_any(array_overflow_any)
    );

    always @(posedge clk) begin
        if (bias_wr_en) begin
            bias_mem[bias_wr_addr] <= bias_wr_data;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count                  <= 32'd0;
            overflow_flag                <= 1'b0;
            profile_clear_c_cycles       <= 32'd0;
            profile_preload_cycles       <= 32'd0;
            profile_clear_acc_cycles     <= 32'd0;
            profile_run_cycles           <= 32'd0;
            profile_wait_load_cycles     <= 32'd0;
            profile_writeback_cycles     <= 32'd0;
            profile_load_overlap_cycles  <= 32'd0;
            profile_buffer_swap_count    <= 32'd0;
            profile_output_tile_count    <= 32'd0;
            profile_k_pass_count         <= 32'd0;
            profile_result_signature     <= 32'd0;
            buf_sel_prev                 <= 1'b0;
        end else begin
            buf_sel_prev <= buf_sel;

            if (start && !busy) begin
                cycle_count                  <= 32'd0;
                overflow_flag                <= 1'b0;
                profile_clear_c_cycles       <= 32'd0;
                profile_preload_cycles       <= 32'd0;
                profile_clear_acc_cycles     <= 32'd0;
                profile_run_cycles           <= 32'd0;
                profile_wait_load_cycles     <= 32'd0;
                profile_writeback_cycles     <= 32'd0;
                profile_load_overlap_cycles  <= 32'd0;
                profile_buffer_swap_count    <= 32'd0;
                profile_output_tile_count    <= 32'd0;
                profile_k_pass_count         <= 32'd0;
                profile_result_signature     <= 32'd0;
                buf_sel_prev                 <= buf_sel;
            end else begin
                if (busy) begin
                    cycle_count <= cycle_count + 1'b1;

                    case (controller_state)
                        ST_CLEAR_C: begin
                            profile_clear_c_cycles <= profile_clear_c_cycles + 1'b1;
                        end

                        ST_PRELOAD: begin
                            profile_preload_cycles <= profile_preload_cycles + 1'b1;
                        end

                        ST_CLEAR_ACC: begin
                            profile_clear_acc_cycles <= profile_clear_acc_cycles + 1'b1;
                        end

                        ST_RUN: begin
                            profile_run_cycles <= profile_run_cycles + 1'b1;
                        end

                        ST_WAIT_LOAD: begin
                            profile_wait_load_cycles <= profile_wait_load_cycles + 1'b1;
                        end

                        ST_WRITEBACK: begin
                            profile_writeback_cycles <= profile_writeback_cycles + 1'b1;
                        end

                        default: begin
                        end
                    endcase

                    if (load_active &&
                        ((controller_state == ST_RUN) || (controller_state == ST_WRITEBACK))) begin
                        profile_load_overlap_cycles <= profile_load_overlap_cycles + 1'b1;
                    end

                    if (buf_sel != buf_sel_prev) begin
                        profile_buffer_swap_count <= profile_buffer_swap_count + 1'b1;
                    end

                    if (run_en && (run_count == RUN_LAST)) begin
                        profile_k_pass_count <= profile_k_pass_count + 1'b1;
                    end

                    if (writeback_active && (wb_count == (TILE_ELEMS - 1))) begin
                        profile_output_tile_count <= profile_output_tile_count + 1'b1;
                    end
                end

                if (writeback_active && c_wr_en) begin
                    profile_result_signature <=
                        {profile_result_signature[26:0], profile_result_signature[31:27]} ^
                        c_wr_data_ext ^
                        {16'd0, c_wr_addr};
                end

                if (array_overflow_any) begin
                    overflow_flag <= 1'b1;
                end
            end
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

            load_a_global_row = (load_tile_row * ARRAY_N) + load_row_now;
            load_a_global_col = (load_tile_k * ARRAY_N) + load_col_now;
            load_b_global_row = (load_tile_k * ARRAY_N) + load_row_now;
            load_b_global_col = (load_tile_col * ARRAY_N) + load_col_now;

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
            load_buf_sel_d  <= 1'b0;
            load_row_d      <= '0;
            load_col_d      <= '0;

            for (buf_idx = 0; buf_idx < 2; buf_idx = buf_idx + 1) begin
                for (row_idx = 0; row_idx < ARRAY_N; row_idx = row_idx + 1) begin
                    for (col_idx = 0; col_idx < ARRAY_N; col_idx = col_idx + 1) begin
                        a_tile[buf_idx][row_idx][col_idx] <= '0;
                        b_tile[buf_idx][row_idx][col_idx] <= '0;
                    end
                end
            end
        end else begin
            if (load_active && (load_count > 0) && load_meta_valid) begin
                a_tile[load_buf_sel_d][load_row_d][load_col_d] <= load_a_valid_d ? a_rd_data : $signed({(DW){1'b0}});
                b_tile[load_buf_sel_d][load_row_d][load_col_d] <= load_b_valid_d ? b_rd_data : $signed({(DW){1'b0}});
            end

            if (load_active && (load_count < TILE_ELEMS)) begin
                load_meta_valid <= 1'b1;
                load_a_valid_d  <= a_issue_valid;
                load_b_valid_d  <= b_issue_valid;
                load_buf_sel_d  <= load_buf_sel;
                load_row_d      <= load_row_now[LOCAL_IDX_W-1:0];
                load_col_d      <= load_col_now[LOCAL_IDX_W-1:0];
            end else begin
                load_meta_valid <= 1'b0;
                load_a_valid_d  <= 1'b0;
                load_b_valid_d  <= 1'b0;
                load_buf_sel_d  <= 1'b0;
            end
        end
    end

    always @(*) begin
        wb_row_now    = 0;
        wb_col_now    = 0;
        wb_global_row = 0;
        wb_global_col = 0;
        pool_row_now  = 0;
        pool_col_now  = 0;
        out_dim       = enable_pool ? (active_dim / 2) : active_dim;
        out_global_row = 0;
        out_global_col = 0;

        c_rd_addr = c_host_rd_addr;

        if (writeback_active && (wb_count < TILE_ELEMS)) begin
            wb_row_now    = wb_count / ARRAY_N;
            wb_col_now    = wb_count % ARRAY_N;
            wb_global_row = (tile_row * ARRAY_N) + wb_row_now;
            wb_global_col = (tile_col * ARRAY_N) + wb_col_now;

            pool_row_now  = wb_count / HALF_ARRAY_N;
            pool_col_now  = wb_count % HALF_ARRAY_N;

            if (enable_pool) begin
                out_global_row = (tile_row * HALF_ARRAY_N) + pool_row_now;
                out_global_col = (tile_col * HALF_ARRAY_N) + pool_col_now;
            end else begin
                out_global_row = wb_global_row;
                out_global_col = wb_global_col;
            end
        end
    end

    assign base_r = enable_pool ? (pool_row_now[LOCAL_IDX_W-1:0] << 1) : wb_row_now[LOCAL_IDX_W-1:0];
    assign base_c = enable_pool ? (pool_col_now[LOCAL_IDX_W-1:0] << 1) : wb_col_now[LOCAL_IDX_W-1:0];
    assign base_r_next = base_r + 1'b1;
    assign base_c_next = base_c + 1'b1;
    assign global_c_base = (tile_col * ARRAY_N) + base_c;
    assign global_c_base_next = global_c_base + 1'b1;

    assign pool_elems[0] = partial_tile[base_r][base_c];
    assign pool_elems[1] = partial_tile[base_r][base_c_next];
    assign pool_elems[2] = partial_tile[base_r_next][base_c];
    assign pool_elems[3] = partial_tile[base_r_next][base_c_next];

    assign pool_bias[0] = enable_bias ? bias_mem[global_c_base]   : $signed({(DW){1'b0}});
    assign pool_bias[1] = enable_bias ? bias_mem[global_c_base_next] : $signed({(DW){1'b0}});
    assign pool_bias[2] = enable_bias ? bias_mem[global_c_base]   : $signed({(DW){1'b0}});
    assign pool_bias[3] = enable_bias ? bias_mem[global_c_base_next] : $signed({(DW){1'b0}});

    genvar p_idx;
    generate
        for (p_idx = 0; p_idx < 4; p_idx = p_idx + 1) begin : gen_pool_act
            assign pool_pre[p_idx] = pool_elems[p_idx] + pool_bias[p_idx];
            assign pool_post[p_idx] = apply_activation_fn(pool_pre[p_idx], act_mode);
        end
    endgenerate

    assign max_01 = (pool_post[0] > pool_post[1]) ? pool_post[0] : pool_post[1];
    assign max_23 = (pool_post[2] > pool_post[3]) ? pool_post[2] : pool_post[3];
    assign max_all = (max_01 > max_23) ? max_01 : max_23;

    assign final_wr_data = enable_pool ? max_all : pool_post[0];

    always @(*) begin
        c_wr_en        = 1'b0;
        c_wr_addr      = '0;
        c_wr_data      = '0;
        c_host_rd_data = c_rd_data;

        if (clear_c_active) begin
            c_wr_en   = 1'b1;
            c_wr_addr = clear_c_addr;
            c_wr_data = '0;
        end else if (writeback_active &&
                     ((!enable_pool && wb_count < TILE_ELEMS) || (enable_pool && wb_count < POOL_TILE_ELEMS)) &&
                     (out_global_row < out_dim) &&
                     (out_global_col < out_dim)) begin
            c_wr_en   = 1'b1;
            c_wr_addr = (out_global_row * out_dim) + out_global_col;
            if (mode_passthrough) begin
                c_wr_data = partial_tile[wb_row_now][wb_col_now];
            end else begin
                c_wr_data = final_wr_data;
            end
        end
    end

    always @(*) begin
        for (feed_idx = 0; feed_idx < ARRAY_N; feed_idx = feed_idx + 1) begin
            feed_delta       = run_count - feed_idx;
            a_feed[feed_idx] = '0;
            b_feed[feed_idx] = '0;

            if (run_en) begin
                if ((run_count >= feed_idx) && (feed_delta < ARRAY_N)) begin
                    a_feed[feed_idx] = a_tile[buf_sel][feed_idx][feed_delta];
                    b_feed[feed_idx] = b_tile[buf_sel][feed_delta][feed_idx];
                end
            end
        end
    end

endmodule
