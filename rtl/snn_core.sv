`timescale 1ns / 1ps
`include "params.vh"

module snn_core (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [7:0] img_data [0:255],
    output reg  done,
    output reg  [3:0] prediction
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

    function automatic signed [31:0] clamp_signed_chunk;
        input signed [31:0] value;
        begin
            if (value > 127) begin
                clamp_signed_chunk = 32'sd127;
            end else if (value < -127) begin
                clamp_signed_chunk = -32'sd127;
            end else begin
                clamp_signed_chunk = value;
            end
        end
    endfunction

    function automatic signed [31:0] clamp_unsigned_chunk;
        input [7:0] value;
        begin
            if (value > 8'd127) begin
                clamp_unsigned_chunk = 32'sd127;
            end else begin
                clamp_unsigned_chunk = $signed({24'd0, value});
            end
        end
    endfunction

    function automatic signed [7:0] signed_chunk_value;
        input signed [31:0] value;
        input integer chunk_idx;
        reg signed [31:0] rem0;
        reg signed [31:0] rem1;
        reg signed [31:0] rem2;
        reg signed [31:0] chunk0;
        reg signed [31:0] chunk1;
        reg signed [31:0] chunk2;
        reg signed [31:0] chunk3;
        begin
            chunk0 = clamp_signed_chunk(value);
            rem0   = value - chunk0;
            chunk1 = clamp_signed_chunk(rem0);
            rem1   = rem0 - chunk1;
            chunk2 = clamp_signed_chunk(rem1);
            rem2   = rem1 - chunk2;
            chunk3 = clamp_signed_chunk(rem2);

            case (chunk_idx)
                0: signed_chunk_value = chunk0[7:0];
                1: signed_chunk_value = chunk1[7:0];
                2: signed_chunk_value = chunk2[7:0];
                3: signed_chunk_value = chunk3[7:0];
                default: signed_chunk_value = 8'sd0;
            endcase
        end
    endfunction

    function automatic signed [7:0] unsigned_chunk_value;
        input [7:0] value;
        input integer chunk_idx;
        reg signed [31:0] rem0;
        reg signed [31:0] rem1;
        reg signed [31:0] chunk0;
        reg signed [31:0] chunk1;
        reg signed [31:0] chunk2;
        begin
            chunk0 = clamp_unsigned_chunk(value);
            rem0   = $signed({24'd0, value}) - chunk0;
            chunk1 = clamp_signed_chunk(rem0);
            rem1   = rem0 - chunk1;
            chunk2 = clamp_signed_chunk(rem1);

            case (chunk_idx)
                0: unsigned_chunk_value = chunk0[7:0];
                1: unsigned_chunk_value = chunk1[7:0];
                2: unsigned_chunk_value = chunk2[7:0];
                default: unsigned_chunk_value = 8'sd0;
            endcase
        end
    endfunction

    function automatic signed [31:0] extend_tpu_acc;
        input signed [20:0] value;
        begin
            extend_tpu_acc = {{11{value[20]}}, value};
        end
    endfunction

    localparam integer NUM_STEPS = 20;
    localparam integer Q_SCALE = 256;
    localparam integer Q_FRAC_BITS = 8;
    localparam integer LIF_BETA_Q = 230;
    localparam integer THRESHOLD_Q = 256;

    localparam integer FC1_ROWS = 64;
    localparam integer FC1_COLS = 256;
    localparam integer FC1_WEIGHT_CHUNKS = 3;
    localparam integer FC1_INPUT_CHUNKS = 3;
    localparam integer FC2_ROWS = 10;
    localparam integer FC2_COLS = 64;
    localparam integer FC2_WEIGHT_CHUNKS = 4;

    localparam integer TPU_N = 32;
    localparam integer TPU_ARRAY_N = `DEFAULT_ARRAY_N;
    localparam integer TPU_DW = `DEFAULT_DW;
    localparam integer TPU_DIM_W = clog2_safe(TPU_N + 1);
    localparam integer TPU_ACCW = (2 * TPU_DW) + $clog2(TPU_N);
    localparam integer TPU_ADDRW = clog2_safe(TPU_N * TPU_N);
    localparam integer TPU_RUN_W = clog2_safe((3 * TPU_ARRAY_N) - 1);
    localparam [TPU_DIM_W-1:0] TPU_MATRIX_DIM = TPU_N;

    // The external SNN command path stays unchanged. Internally, FC1 is
    // computed once through a dedicated tiled TPU instance, then reused across
    // all LIF time steps. FC2 is re-evaluated each step from the current spikes.

    typedef enum logic [4:0] {
        IDLE,
        FC1_PREP,
        FC1_LOAD_A_PRIME,
        FC1_LOAD_A,
        FC1_LOAD_B,
        FC1_START_TPU,
        FC1_WAIT_TPU,
        FC1_READ_SET,
        FC1_READ_WAIT,
        FC1_READ_CAPTURE,
        FC1_ADVANCE,
        FC1_BIAS_PRIME,
        FC1_BIAS_CAPTURE,
        LIF1_CALC,
        FC2_PREP,
        FC2_LOAD_B,
        FC2_LOAD_A_PRIME,
        FC2_LOAD_A,
        FC2_START_TPU,
        FC2_WAIT_TPU,
        FC2_READ_SET,
        FC2_READ_WAIT,
        FC2_READ_CAPTURE,
        FC2_ADVANCE,
        FC2_BIAS_PRIME,
        FC2_BIAS_CAPTURE,
        LIF2_CALC,
        ARGMAX
    } state_t;

    state_t state;

    reg  tpu_start;
    reg  a_wr_en;
    reg  b_wr_en;
    reg  [TPU_ADDRW-1:0] a_wr_addr;
    reg  [TPU_ADDRW-1:0] b_wr_addr;
    reg  signed [TPU_DW-1:0] a_wr_data;
    reg  signed [TPU_DW-1:0] b_wr_data;
    reg  [TPU_ADDRW-1:0] c_host_rd_addr;
    wire signed [TPU_ACCW-1:0] c_host_rd_data;
    wire tpu_busy;
    wire tpu_done;
    wire [31:0] tpu_cycle_count_unused;
    wire tpu_run_active_unused;
    wire [TPU_RUN_W-1:0] tpu_run_count_unused;
    wire tpu_clear_c_active_unused;
    wire tpu_load_active_unused;
    wire tpu_writeback_active_unused;
    wire tpu_clear_acc_unused;
    wire [2:0] tpu_debug_state_unused;
    wire tpu_buf_sel_unused;
    wire tpu_load_buf_sel_unused;
    wire [15:0] tpu_load_count_unused;
    wire [15:0] tpu_wb_count_unused;
    wire [15:0] tpu_clear_c_addr_unused;
    wire tpu_overflow_unused;
    wire [TPU_DIM_W-1:0] tpu_active_dim_unused;
    wire [31:0] tpu_profile_clear_c_cycles_unused;
    wire [31:0] tpu_profile_preload_cycles_unused;
    wire [31:0] tpu_profile_clear_acc_cycles_unused;
    wire [31:0] tpu_profile_run_cycles_unused;
    wire [31:0] tpu_profile_wait_load_cycles_unused;
    wire [31:0] tpu_profile_writeback_cycles_unused;
    wire [31:0] tpu_profile_load_overlap_cycles_unused;
    wire [31:0] tpu_profile_buffer_swap_count_unused;
    wire [31:0] tpu_profile_output_tile_count_unused;
    wire [31:0] tpu_profile_k_pass_count_unused;
    wire [31:0] tpu_profile_result_signature_unused;

    reg [4:0] step_cnt;
    reg       fc1_row_block;
    reg [2:0] fc1_k_block;
    reg [1:0] fc1_w_chunk;
    reg [1:0] fc1_x_chunk;
    reg       fc2_k_block;
    reg [1:0] fc2_w_chunk;
    reg [10:0] load_idx;
    reg [5:0] read_idx;
    reg [6:0] neuron_idx;
    reg       a_pipe_valid;
    reg       a_pipe_zero;
    reg [TPU_ADDRW-1:0] a_pipe_addr;

    reg [5:0] w1_row_addr;
    reg [7:0] w1_col_addr;
    wire signed [31:0] w1_data;

    reg [3:0] w2_row_addr;
    reg [5:0] w2_col_addr;
    wire signed [31:0] w2_data;

    reg [5:0] b1_addr;
    wire signed [31:0] b1_data;

    reg [3:0] b2_addr;
    wire signed [31:0] b2_data;

    reg signed [31:0] fc1_acc [0:FC1_ROWS-1];
    reg signed [31:0] fc1_out [0:FC1_ROWS-1];
    reg signed [31:0] mem1 [0:FC1_ROWS-1];
    reg                spikes1 [0:FC1_ROWS-1];

    reg signed [31:0] fc2_acc [0:FC2_ROWS-1];
    reg signed [31:0] fc2_out [0:FC2_ROWS-1];
    reg signed [31:0] mem2 [0:FC2_ROWS-1];
    reg                spikes2 [0:FC2_ROWS-1];
    reg signed [31:0] scores [0:FC2_ROWS-1];

    integer init_idx;
    integer row_idx;
    reg signed [31:0] lif_value;
    reg signed [31:0] argmax_score;
    reg [3:0] argmax_index;

    snn_weights u_weights (
        .clk(clk),
        .w1_row_addr(w1_row_addr),
        .w1_col_addr(w1_col_addr),
        .w1_data(w1_data),
        .w2_row_addr(w2_row_addr),
        .w2_col_addr(w2_col_addr),
        .w2_data(w2_data),
        .b1_addr(b1_addr),
        .b1_data(b1_data),
        .b2_addr(b2_addr),
        .b2_data(b2_data)
    );

    tpu_top #(
        .N(TPU_N),
        .ARRAY_N(TPU_ARRAY_N),
        .DW(TPU_DW),
        .DIM_W(TPU_DIM_W),
        .ACCW(TPU_ACCW),
        .ADDRW(TPU_ADDRW),
        .RUN_W(TPU_RUN_W)
    ) u_tpu (
        .clk(clk),
        .rst_n(rst_n),
        .start(tpu_start),
        .act_mode(2'b00),
        .enable_bias(1'b0),
        .enable_pool(1'b0),
        .matrix_dim(TPU_MATRIX_DIM),
        .busy(tpu_busy),
        .done(tpu_done),
        .cycle_count(tpu_cycle_count_unused),
        .debug_run_active(tpu_run_active_unused),
        .debug_run_count(tpu_run_count_unused),
        .debug_clear_c_active(tpu_clear_c_active_unused),
        .debug_load_active(tpu_load_active_unused),
        .debug_writeback_active(tpu_writeback_active_unused),
        .debug_clear_acc(tpu_clear_acc_unused),
        .debug_state(tpu_debug_state_unused),
        .debug_buf_sel(tpu_buf_sel_unused),
        .debug_load_buf_sel(tpu_load_buf_sel_unused),
        .debug_load_count(tpu_load_count_unused),
        .debug_wb_count(tpu_wb_count_unused),
        .debug_clear_c_addr(tpu_clear_c_addr_unused),
        .overflow_flag(tpu_overflow_unused),
        .active_matrix_dim(tpu_active_dim_unused),
        .profile_clear_c_cycles(tpu_profile_clear_c_cycles_unused),
        .profile_preload_cycles(tpu_profile_preload_cycles_unused),
        .profile_clear_acc_cycles(tpu_profile_clear_acc_cycles_unused),
        .profile_run_cycles(tpu_profile_run_cycles_unused),
        .profile_wait_load_cycles(tpu_profile_wait_load_cycles_unused),
        .profile_writeback_cycles(tpu_profile_writeback_cycles_unused),
        .profile_load_overlap_cycles(tpu_profile_load_overlap_cycles_unused),
        .profile_buffer_swap_count(tpu_profile_buffer_swap_count_unused),
        .profile_output_tile_count(tpu_profile_output_tile_count_unused),
        .profile_k_pass_count(tpu_profile_k_pass_count_unused),
        .profile_result_signature(tpu_profile_result_signature_unused),
        .a_wr_en(a_wr_en),
        .b_wr_en(b_wr_en),
        .bias_wr_en(1'b0),
        .a_wr_addr(a_wr_addr),
        .b_wr_addr(b_wr_addr),
        .bias_wr_addr('0),
        .a_wr_data(a_wr_data),
        .b_wr_data(b_wr_data),
        .bias_wr_data('0),
        .c_host_rd_addr(c_host_rd_addr),
        .c_host_rd_data(c_host_rd_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            prediction <= 4'd0;
            tpu_start <= 1'b0;
            a_wr_en <= 1'b0;
            b_wr_en <= 1'b0;
            a_wr_addr <= '0;
            b_wr_addr <= '0;
            a_wr_data <= '0;
            b_wr_data <= '0;
            c_host_rd_addr <= '0;
            step_cnt <= '0;
            fc1_row_block <= 1'b0;
            fc1_k_block <= '0;
            fc1_w_chunk <= '0;
            fc1_x_chunk <= '0;
            fc2_k_block <= 1'b0;
            fc2_w_chunk <= '0;
            load_idx <= '0;
            read_idx <= '0;
            neuron_idx <= '0;
            a_pipe_valid <= 1'b0;
            a_pipe_zero <= 1'b0;
            a_pipe_addr <= '0;
            w1_row_addr <= '0;
            w1_col_addr <= '0;
            w2_row_addr <= '0;
            w2_col_addr <= '0;
            b1_addr <= '0;
            b2_addr <= '0;
            for (init_idx = 0; init_idx < FC1_ROWS; init_idx = init_idx + 1) begin
                fc1_acc[init_idx] <= 32'sd0;
                fc1_out[init_idx] <= 32'sd0;
                mem1[init_idx] <= 32'sd0;
                spikes1[init_idx] <= 1'b0;
            end
            for (init_idx = 0; init_idx < FC2_ROWS; init_idx = init_idx + 1) begin
                fc2_acc[init_idx] <= 32'sd0;
                fc2_out[init_idx] <= 32'sd0;
                mem2[init_idx] <= 32'sd0;
                spikes2[init_idx] <= 1'b0;
                scores[init_idx] <= 32'sd0;
            end
            lif_value <= 32'sd0;
            argmax_score <= 32'sd0;
            argmax_index <= 4'd0;
        end else begin
            done <= 1'b0;
            tpu_start <= 1'b0;
            a_wr_en <= 1'b0;
            b_wr_en <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        prediction <= 4'd0;
                        step_cnt <= 5'd0;
                        fc1_row_block <= 1'b0;
                        fc1_k_block <= 3'd0;
                        fc1_w_chunk <= 2'd0;
                        fc1_x_chunk <= 2'd0;
                        fc2_k_block <= 1'b0;
                        fc2_w_chunk <= 2'd0;
                        load_idx <= 11'd0;
                        read_idx <= 6'd0;
                        neuron_idx <= 7'd0;
                        a_pipe_valid <= 1'b0;
                        a_pipe_zero <= 1'b0;
                        a_pipe_addr <= '0;
                        w1_row_addr <= 6'd0;
                        w1_col_addr <= 8'd0;
                        w2_row_addr <= 4'd0;
                        w2_col_addr <= 6'd0;
                        b1_addr <= 6'd0;
                        b2_addr <= 4'd0;
                        c_host_rd_addr <= '0;
                        for (init_idx = 0; init_idx < FC1_ROWS; init_idx = init_idx + 1) begin
                            fc1_acc[init_idx] <= 32'sd0;
                            fc1_out[init_idx] <= 32'sd0;
                            mem1[init_idx] <= 32'sd0;
                            spikes1[init_idx] <= 1'b0;
                        end
                        for (init_idx = 0; init_idx < FC2_ROWS; init_idx = init_idx + 1) begin
                            fc2_acc[init_idx] <= 32'sd0;
                            fc2_out[init_idx] <= 32'sd0;
                            mem2[init_idx] <= 32'sd0;
                            spikes2[init_idx] <= 1'b0;
                            scores[init_idx] <= 32'sd0;
                        end
                        state <= FC1_PREP;
                    end
                end

                FC1_PREP: begin
                    a_pipe_addr <= '0;
                    load_idx <= 11'd1;
                    read_idx <= 6'd0;
                    w1_row_addr <= {fc1_row_block, 5'd0};
                    w1_col_addr <= {fc1_k_block, 5'd0};
                    state <= FC1_LOAD_A_PRIME;
                end

                FC1_LOAD_A_PRIME: begin
                    if (load_idx < (TPU_N * TPU_N)) begin
                        w1_row_addr <= {fc1_row_block, load_idx[9:5]};
                        w1_col_addr <= {fc1_k_block, load_idx[4:0]};
                        load_idx <= load_idx + 1'b1;
                    end
                    state <= FC1_LOAD_A;
                end

                FC1_LOAD_A: begin
                    a_wr_en <= 1'b1;
                    a_wr_addr <= a_pipe_addr;
                    a_wr_data <= signed_chunk_value(w1_data, fc1_w_chunk);

                    if (a_pipe_addr == ((TPU_N * TPU_N) - 1)) begin
                        load_idx <= 11'd0;
                        state <= FC1_LOAD_B;
                    end else begin
                        a_pipe_addr <= a_pipe_addr + 1'b1;
                        if (load_idx < (TPU_N * TPU_N)) begin
                            w1_row_addr <= {fc1_row_block, load_idx[9:5]};
                            w1_col_addr <= {fc1_k_block, load_idx[4:0]};
                            load_idx <= load_idx + 1'b1;
                        end
                    end
                end

                FC1_LOAD_B: begin
                    if (load_idx < (TPU_N * TPU_N)) begin
                        b_wr_en <= 1'b1;
                        b_wr_addr <= load_idx[TPU_ADDRW-1:0];
                        if (load_idx[4:0] == 5'd0) begin
                            b_wr_data <= unsigned_chunk_value(img_data[{fc1_k_block, load_idx[9:5]}], fc1_x_chunk);
                        end else begin
                            b_wr_data <= 8'sd0;
                        end
                        load_idx <= load_idx + 1'b1;
                    end else begin
                        load_idx <= 11'd0;
                        state <= FC1_START_TPU;
                    end
                end

                FC1_START_TPU: begin
                    tpu_start <= 1'b1;
                    state <= FC1_WAIT_TPU;
                end

                FC1_WAIT_TPU: begin
                    if (tpu_done) begin
                        read_idx <= 6'd0;
                        state <= FC1_READ_SET;
                    end
                end

                FC1_READ_SET: begin
                    c_host_rd_addr <= {read_idx[4:0], 5'b00000};
                    state <= FC1_READ_WAIT;
                end

                FC1_READ_WAIT: begin
                    state <= FC1_READ_CAPTURE;
                end

                FC1_READ_CAPTURE: begin
                    fc1_acc[{fc1_row_block, read_idx[4:0]}] <=
                        fc1_acc[{fc1_row_block, read_idx[4:0]}] + extend_tpu_acc(c_host_rd_data);
                    if (read_idx == 6'd31) begin
                        state <= FC1_ADVANCE;
                    end else begin
                        read_idx <= read_idx + 1'b1;
                        state <= FC1_READ_SET;
                    end
                end

                FC1_ADVANCE: begin
                    load_idx <= 11'd0;
                    read_idx <= 6'd0;
                    if (fc1_x_chunk < (FC1_INPUT_CHUNKS - 1)) begin
                        fc1_x_chunk <= fc1_x_chunk + 1'b1;
                        state <= FC1_LOAD_B;
                    end else begin
                        fc1_x_chunk <= 2'd0;
                        if (fc1_w_chunk < (FC1_WEIGHT_CHUNKS - 1)) begin
                            fc1_w_chunk <= fc1_w_chunk + 1'b1;
                            a_pipe_addr <= '0;
                            load_idx <= 11'd1;
                            w1_row_addr <= {fc1_row_block, 5'd0};
                            w1_col_addr <= {fc1_k_block, 5'd0};
                            state <= FC1_LOAD_A_PRIME;
                        end else begin
                            fc1_w_chunk <= 2'd0;
                            if (!fc1_row_block) begin
                                fc1_row_block <= 1'b1;
                                a_pipe_addr <= '0;
                                load_idx <= 11'd1;
                                w1_row_addr <= {1'b1, 5'd0};
                                w1_col_addr <= {fc1_k_block, 5'd0};
                                state <= FC1_LOAD_A_PRIME;
                            end else begin
                                fc1_row_block <= 1'b0;
                                if (fc1_k_block < 3'd7) begin
                                    fc1_k_block <= fc1_k_block + 1'b1;
                                    a_pipe_addr <= '0;
                                    load_idx <= 11'd1;
                                    w1_row_addr <= {1'b0, 5'd0};
                                    w1_col_addr <= {fc1_k_block + 1'b1, 5'd0};
                                    state <= FC1_LOAD_A_PRIME;
                                end else begin
                                    neuron_idx <= 7'd0;
                                    b1_addr <= 6'd0;
                                    load_idx <= 11'd1;
                                    state <= FC1_BIAS_PRIME;
                                end
                            end
                        end
                    end
                end

                FC1_BIAS_PRIME: begin
                    if (load_idx < FC1_ROWS) begin
                        b1_addr <= load_idx[5:0];
                        load_idx <= load_idx + 1'b1;
                    end
                    state <= FC1_BIAS_CAPTURE;
                end

                FC1_BIAS_CAPTURE: begin
                    fc1_out[neuron_idx[5:0]] <= (fc1_acc[neuron_idx[5:0]] >>> 8) + b1_data;
                    if (neuron_idx == (FC1_ROWS - 1)) begin
                        neuron_idx <= 7'd0;
                        state <= LIF1_CALC;
                    end else begin
                        neuron_idx <= neuron_idx + 1'b1;
                        if (load_idx < FC1_ROWS) begin
                            b1_addr <= load_idx[5:0];
                            load_idx <= load_idx + 1'b1;
                        end
                        state <= FC1_BIAS_CAPTURE;
                    end
                end

                LIF1_CALC: begin
                    if (neuron_idx < FC1_ROWS) begin
                        lif_value = ((LIF_BETA_Q * mem1[neuron_idx[5:0]]) >>> Q_FRAC_BITS) + fc1_out[neuron_idx[5:0]];
                        if (lif_value > THRESHOLD_Q) begin
                            spikes1[neuron_idx[5:0]] <= 1'b1;
                            mem1[neuron_idx[5:0]] <= lif_value - THRESHOLD_Q;
                        end else begin
                            spikes1[neuron_idx[5:0]] <= 1'b0;
                            mem1[neuron_idx[5:0]] <= lif_value;
                        end
                        neuron_idx <= neuron_idx + 1'b1;
                    end else begin
                        state <= FC2_PREP;
                    end
                end

                FC2_PREP: begin
                    fc2_k_block <= 1'b0;
                    fc2_w_chunk <= 2'd0;
                    load_idx <= 11'd0;
                    read_idx <= 6'd0;
                    neuron_idx <= 7'd0;
                    for (init_idx = 0; init_idx < FC2_ROWS; init_idx = init_idx + 1) begin
                        fc2_acc[init_idx] <= 32'sd0;
                        fc2_out[init_idx] <= 32'sd0;
                    end
                    state <= FC2_LOAD_B;
                end

                FC2_LOAD_B: begin
                    if (load_idx < (TPU_N * TPU_N)) begin
                        b_wr_en <= 1'b1;
                        b_wr_addr <= load_idx[TPU_ADDRW-1:0];
                        if (load_idx[4:0] == 5'd0) begin
                            b_wr_data <= spikes1[{fc2_k_block, load_idx[9:5]}] ? 8'sd1 : 8'sd0;
                        end else begin
                            b_wr_data <= 8'sd0;
                        end
                        load_idx <= load_idx + 1'b1;
                    end else begin
                        a_pipe_addr <= '0;
                        load_idx <= 11'd1;
                        w2_row_addr <= 4'd0;
                        w2_col_addr <= {fc2_k_block, 5'd0};
                        state <= FC2_LOAD_A_PRIME;
                    end
                end

                FC2_LOAD_A_PRIME: begin
                    if (load_idx < (FC2_ROWS * TPU_N)) begin
                        w2_row_addr <= load_idx[8:5];
                        w2_col_addr <= {fc2_k_block, load_idx[4:0]};
                        load_idx <= load_idx + 1'b1;
                    end
                    state <= FC2_LOAD_A;
                end

                FC2_LOAD_A: begin
                    a_wr_en <= 1'b1;
                    a_wr_addr <= a_pipe_addr;
                    if (a_pipe_addr < (FC2_ROWS * TPU_N)) begin
                        a_wr_data <= signed_chunk_value(w2_data, fc2_w_chunk);
                    end else begin
                        a_wr_data <= 8'sd0;
                    end

                    if (a_pipe_addr == ((TPU_N * TPU_N) - 1)) begin
                        load_idx <= 11'd0;
                        state <= FC2_START_TPU;
                    end else begin
                        a_pipe_addr <= a_pipe_addr + 1'b1;
                        if (load_idx < (FC2_ROWS * TPU_N)) begin
                            w2_row_addr <= load_idx[8:5];
                            w2_col_addr <= {fc2_k_block, load_idx[4:0]};
                            load_idx <= load_idx + 1'b1;
                        end
                    end
                end

                FC2_START_TPU: begin
                    tpu_start <= 1'b1;
                    state <= FC2_WAIT_TPU;
                end

                FC2_WAIT_TPU: begin
                    if (tpu_done) begin
                        read_idx <= 6'd0;
                        state <= FC2_READ_SET;
                    end
                end

                FC2_READ_SET: begin
                    c_host_rd_addr <= {read_idx[4:0], 5'b00000};
                    state <= FC2_READ_WAIT;
                end

                FC2_READ_WAIT: begin
                    state <= FC2_READ_CAPTURE;
                end

                FC2_READ_CAPTURE: begin
                    fc2_acc[read_idx[3:0]] <= fc2_acc[read_idx[3:0]] + extend_tpu_acc(c_host_rd_data);
                    if (read_idx == (FC2_ROWS - 1)) begin
                        state <= FC2_ADVANCE;
                    end else begin
                        read_idx <= read_idx + 1'b1;
                        state <= FC2_READ_SET;
                    end
                end

                FC2_ADVANCE: begin
                    load_idx <= 11'd0;
                    read_idx <= 6'd0;
                    if (fc2_w_chunk < (FC2_WEIGHT_CHUNKS - 1)) begin
                        fc2_w_chunk <= fc2_w_chunk + 1'b1;
                        a_pipe_addr <= '0;
                        load_idx <= 11'd1;
                        w2_row_addr <= 4'd0;
                        w2_col_addr <= {fc2_k_block, 5'd0};
                        state <= FC2_LOAD_A_PRIME;
                    end else begin
                        fc2_w_chunk <= 2'd0;
                        if (!fc2_k_block) begin
                            fc2_k_block <= 1'b1;
                            load_idx <= 11'd0;
                            state <= FC2_LOAD_B;
                        end else begin
                            neuron_idx <= 7'd0;
                            b2_addr <= 4'd0;
                            load_idx <= 11'd1;
                            state <= FC2_BIAS_PRIME;
                        end
                    end
                end

                FC2_BIAS_PRIME: begin
                    if (load_idx < FC2_ROWS) begin
                        b2_addr <= load_idx[3:0];
                        load_idx <= load_idx + 1'b1;
                    end
                    state <= FC2_BIAS_CAPTURE;
                end

                FC2_BIAS_CAPTURE: begin
                    fc2_out[neuron_idx[3:0]] <= fc2_acc[neuron_idx[3:0]] + b2_data;
                    if (neuron_idx == (FC2_ROWS - 1)) begin
                        neuron_idx <= 7'd0;
                        state <= LIF2_CALC;
                    end else begin
                        neuron_idx <= neuron_idx + 1'b1;
                        if (load_idx < FC2_ROWS) begin
                            b2_addr <= load_idx[3:0];
                            load_idx <= load_idx + 1'b1;
                        end
                        state <= FC2_BIAS_CAPTURE;
                    end
                end

                LIF2_CALC: begin
                    if (neuron_idx < FC2_ROWS) begin
                        lif_value = ((LIF_BETA_Q * mem2[neuron_idx[3:0]]) >>> Q_FRAC_BITS) + fc2_out[neuron_idx[3:0]];
                        if (lif_value > THRESHOLD_Q) begin
                            spikes2[neuron_idx[3:0]] <= 1'b1;
                            mem2[neuron_idx[3:0]] <= lif_value - THRESHOLD_Q;
                            scores[neuron_idx[3:0]] <= scores[neuron_idx[3:0]] + Q_SCALE;
                        end else begin
                            spikes2[neuron_idx[3:0]] <= 1'b0;
                            mem2[neuron_idx[3:0]] <= lif_value;
                        end
                        neuron_idx <= neuron_idx + 1'b1;
                    end else begin
                        if (step_cnt < (NUM_STEPS - 1)) begin
                            step_cnt <= step_cnt + 1'b1;
                            neuron_idx <= 7'd0;
                            state <= LIF1_CALC;
                        end else begin
                            state <= ARGMAX;
                        end
                    end
                end

                ARGMAX: begin
                    argmax_score = scores[0];
                    argmax_index = 4'd0;
                    for (row_idx = 1; row_idx < FC2_ROWS; row_idx = row_idx + 1) begin
                        if (scores[row_idx[3:0]] > argmax_score) begin
                            argmax_score = scores[row_idx[3:0]];
                            argmax_index = row_idx[3:0];
                        end
                    end
                    prediction <= argmax_index;
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
