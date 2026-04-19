`timescale 1ns / 1ps
`include "params.vh"

module tb_tpu_top;

    localparam integer MAX_N            = `DEFAULT_MATRIX_N;
    localparam integer ARRAY_N          = `DEFAULT_ARRAY_N;
    localparam integer DW               = `DEFAULT_DW;
    localparam integer DIM_W            = ((MAX_N + 1) <= 1) ? 1 : $clog2(MAX_N + 1);
    localparam integer ACCW             = 2*DW + $clog2(MAX_N);
    localparam integer MAX_DEPTH        = MAX_N * MAX_N;
    localparam integer ADDRW            = (MAX_DEPTH <= 1) ? 1 : $clog2(MAX_DEPTH);
    localparam integer RUN_W            = (((3 * ARRAY_N) - 2) <= 1) ? 1 : $clog2((3 * ARRAY_N) - 2);
    localparam integer DEFAULT_SIM_N    = MAX_N;
    localparam integer DEFAULT_SIM_SEED = 1;
    localparam integer SIM_TIMEOUT_CYC  = 1000000;

    reg clk;
    reg rst_n;
    reg start;
    reg [DIM_W-1:0] matrix_dim;
    wire busy;
    wire done;
    wire [31:0] cycle_count;
    wire debug_run_active;
    wire [RUN_W-1:0] debug_run_count;
    wire [DIM_W-1:0] active_matrix_dim;

    reg  a_wr_en;
    reg  b_wr_en;
    reg  [ADDRW-1:0] a_wr_addr;
    reg  [ADDRW-1:0] b_wr_addr;
    reg  signed [DW-1:0] a_wr_data;
    reg  signed [DW-1:0] b_wr_data;
    reg  [ADDRW-1:0] c_host_rd_addr;
    wire signed [ACCW-1:0] c_host_rd_data;

    integer idx;
    integer r;
    integer c;
    integer k;
    integer file_a;
    integer file_b;
    integer file_c;
    integer file_meta;
    integer file_case;
    integer runtime_dim;
    integer runtime_seed;
    integer active_dim_seen;
    integer mismatch_count;
    integer first_mismatch_idx;
    integer first_mismatch_r;
    integer first_mismatch_c;
    integer rand_a;
    integer rand_b;
    integer rng_state;
    string  output_dir;

    reg signed [DW-1:0]   mat_a [0:MAX_DEPTH-1];
    reg signed [DW-1:0]   mat_b [0:MAX_DEPTH-1];
    integer               mat_c_hw [0:MAX_DEPTH-1];
    integer               mat_c_ref [0:MAX_DEPTH-1];

    tpu_top #(
        .N       (MAX_N),
        .ARRAY_N (ARRAY_N),
        .DW      (DW),
        .DIM_W   (DIM_W),
        .ACCW    (ACCW),
        .ADDRW   (ADDRW),
        .RUN_W   (RUN_W)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .matrix_dim       (matrix_dim),
        .busy             (busy),
        .done             (done),
        .cycle_count      (cycle_count),
        .debug_run_active (debug_run_active),
        .debug_run_count  (debug_run_count),
        .active_matrix_dim(active_matrix_dim),
        .a_wr_en          (a_wr_en),
        .b_wr_en          (b_wr_en),
        .a_wr_addr        (a_wr_addr),
        .b_wr_addr        (b_wr_addr),
        .a_wr_data        (a_wr_data),
        .b_wr_data        (b_wr_data),
        .c_host_rd_addr   (c_host_rd_addr),
        .c_host_rd_data   (c_host_rd_data)
    );

    always #5 clk = ~clk;

    task automatic clear_storage;
        begin
            for (idx = 0; idx < MAX_DEPTH; idx = idx + 1) begin
                mat_a[idx]     = '0;
                mat_b[idx]     = '0;
                mat_c_hw[idx]  = 0;
                mat_c_ref[idx] = 0;
            end
        end
    endtask

    task automatic randomize_inputs;
        input integer n;
        input integer seed_value;
        begin
            rng_state = seed_value;
            for (idx = 0; idx < (n * n); idx = idx + 1) begin
                rand_a     = $random(rng_state);
                rand_b     = $random(rng_state);
                mat_a[idx] = rand_a[DW-1:0];
                mat_b[idx] = rand_b[DW-1:0];
            end
        end
    endtask

    task automatic compute_reference;
        input integer n;
        integer sum_val;
        begin
            for (r = 0; r < n; r = r + 1) begin
                for (c = 0; c < n; c = c + 1) begin
                    sum_val = 0;
                    for (k = 0; k < n; k = k + 1) begin
                        sum_val = sum_val + (mat_a[r*n + k] * mat_b[k*n + c]);
                    end
                    mat_c_ref[r*n + c] = sum_val;
                end
            end
        end
    endtask

    task automatic write_inputs_to_dut;
        input integer n;
        begin
            for (idx = 0; idx < (n * n); idx = idx + 1) begin
                a_wr_en   = 1'b1;
                a_wr_addr = idx[ADDRW-1:0];
                a_wr_data = mat_a[idx];
                b_wr_en   = 1'b1;
                b_wr_addr = idx[ADDRW-1:0];
                b_wr_data = mat_b[idx];
                @(posedge clk);
            end

            a_wr_en   = 1'b0;
            b_wr_en   = 1'b0;
            a_wr_addr = '0;
            b_wr_addr = '0;
            a_wr_data = '0;
            b_wr_data = '0;
            @(posedge clk);
        end
    endtask

    task automatic start_core;
        begin
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_for_done;
        integer timeout_count;
        begin
            timeout_count = SIM_TIMEOUT_CYC;
            while ((done !== 1'b1) && (timeout_count > 0)) begin
                @(posedge clk);
                timeout_count = timeout_count - 1;
            end

            if (timeout_count == 0) begin
                $fatal(1, "Timeout waiting for done. busy=%0d run_active=%0d run_count=%0d cycle_count=%0d",
                       busy, debug_run_active, debug_run_count, cycle_count);
            end
        end
    endtask

    task automatic read_hw_result;
        input integer n;
        integer depth;
        begin
            depth = n * n;
            c_host_rd_addr = '0;
            @(posedge clk);

            for (idx = 0; idx < depth; idx = idx + 1) begin
                mat_c_hw[idx] = c_host_rd_data;
                if (idx != (depth - 1)) begin
                    c_host_rd_addr = idx + 1;
                    @(posedge clk);
                end
            end

            c_host_rd_addr = '0;
            @(posedge clk);

            for (idx = depth; idx < MAX_DEPTH; idx = idx + 1) begin
                mat_c_hw[idx] = 0;
            end
        end
    endtask

    task automatic open_output_file;
        output integer file_handle;
        input string leaf_name;
        string file_path;
        begin
            file_handle = 0;
            file_path   = "";

            if (output_dir.len() != 0) begin
                if (output_dir == ".") begin
                    file_path = leaf_name;
                end else begin
                    file_path = {output_dir, "/", leaf_name};
                end
                file_handle = $fopen(file_path, "w");
            end

            if (file_handle == 0) begin
                file_path   = "../../sim/output/";
                file_path   = {file_path, leaf_name};
                file_handle = $fopen(file_path, "w");
            end

            if (file_handle == 0) begin
                file_path   = "../../../sim/output/";
                file_path   = {file_path, leaf_name};
                file_handle = $fopen(file_path, "w");
            end

            if (file_handle == 0) begin
                file_path   = "../../../../sim/output/";
                file_path   = {file_path, leaf_name};
                file_handle = $fopen(file_path, "w");
            end

            if (file_handle == 0) begin
                file_path   = "../../../../../sim/output/";
                file_path   = {file_path, leaf_name};
                file_handle = $fopen(file_path, "w");
            end

            if (file_handle == 0) begin
                file_path   = leaf_name;
                file_handle = $fopen(file_path, "w");
            end

            if (file_handle == 0) begin
                $fatal(1, "Could not open output file for '%s'.", leaf_name);
            end

            $display("Writing output file: %s", file_path);
        end
    endtask

    task automatic dump_matrix_a;
        input integer n;
        begin
            open_output_file(file_a, "matrix_a.txt");
            for (r = 0; r < n; r = r + 1) begin
                for (c = 0; c < n; c = c + 1) begin
                    $fwrite(file_a, "%0d", mat_a[r*n + c]);
                    if (c != (n - 1)) begin
                        $fwrite(file_a, " ");
                    end
                end
                $fwrite(file_a, "\n");
            end
            $fclose(file_a);
        end
    endtask

    task automatic dump_matrix_b;
        input integer n;
        begin
            open_output_file(file_b, "matrix_b.txt");
            for (r = 0; r < n; r = r + 1) begin
                for (c = 0; c < n; c = c + 1) begin
                    $fwrite(file_b, "%0d", mat_b[r*n + c]);
                    if (c != (n - 1)) begin
                        $fwrite(file_b, " ");
                    end
                end
                $fwrite(file_b, "\n");
            end
            $fclose(file_b);
        end
    endtask

    task automatic dump_matrix_c;
        input integer n;
        begin
            open_output_file(file_c, "matrix_c_hw.txt");
            for (r = 0; r < n; r = r + 1) begin
                for (c = 0; c < n; c = c + 1) begin
                    $fwrite(file_c, "%0d", mat_c_hw[r*n + c]);
                    if (c != (n - 1)) begin
                        $fwrite(file_c, " ");
                    end
                end
                $fwrite(file_c, "\n");
            end
            $fclose(file_c);
        end
    endtask

    task automatic dump_run_info;
        input integer n;
        input integer seed_value;
        begin
            open_output_file(file_meta, "run_info.txt");
            $fwrite(file_meta, "MAX_N=%0d\n", MAX_N);
            $fwrite(file_meta, "ARRAY_N=%0d\n", ARRAY_N);
            $fwrite(file_meta, "ACTIVE_DIM=%0d\n", n);
            $fwrite(file_meta, "ACTIVE_DIM_SEEN=%0d\n", active_dim_seen);
            $fwrite(file_meta, "DATA_W=%0d\n", DW);
            $fwrite(file_meta, "ACC_W=%0d\n", ACCW);
            $fwrite(file_meta, "SEED=%0d\n", seed_value);
            $fwrite(file_meta, "CYCLES=%0d\n", cycle_count);
            $fclose(file_meta);
        end
    endtask

    task automatic dump_combined_case;
        input integer n;
        input integer seed_value;
        begin
            open_output_file(file_case, "matmul_case.txt");
            $fwrite(file_case, "FORMAT_VERSION=1\n");
            $fwrite(file_case, "MAX_N=%0d\n", MAX_N);
            $fwrite(file_case, "ARRAY_N=%0d\n", ARRAY_N);
            $fwrite(file_case, "MATRIX_DIM=%0d\n", n);
            $fwrite(file_case, "DATA_W=%0d\n", DW);
            $fwrite(file_case, "ACC_W=%0d\n", ACCW);
            $fwrite(file_case, "SEED=%0d\n", seed_value);
            $fwrite(file_case, "CYCLES=%0d\n", cycle_count);

            $fwrite(file_case, "BEGIN_MATRIX_A\n");
            for (r = 0; r < n; r = r + 1) begin
                for (c = 0; c < n; c = c + 1) begin
                    $fwrite(file_case, "%0d", mat_a[r*n + c]);
                    if (c != (n - 1)) begin
                        $fwrite(file_case, " ");
                    end
                end
                $fwrite(file_case, "\n");
            end
            $fwrite(file_case, "END_MATRIX_A\n");

            $fwrite(file_case, "BEGIN_MATRIX_B\n");
            for (r = 0; r < n; r = r + 1) begin
                for (c = 0; c < n; c = c + 1) begin
                    $fwrite(file_case, "%0d", mat_b[r*n + c]);
                    if (c != (n - 1)) begin
                        $fwrite(file_case, " ");
                    end
                end
                $fwrite(file_case, "\n");
            end
            $fwrite(file_case, "END_MATRIX_B\n");

            $fwrite(file_case, "BEGIN_MATRIX_C\n");
            for (r = 0; r < n; r = r + 1) begin
                for (c = 0; c < n; c = c + 1) begin
                    $fwrite(file_case, "%0d", mat_c_hw[r*n + c]);
                    if (c != (n - 1)) begin
                        $fwrite(file_case, " ");
                    end
                end
                $fwrite(file_case, "\n");
            end
            $fwrite(file_case, "END_MATRIX_C\n");

            $fclose(file_case);
        end
    endtask

    task automatic compare_hw_vs_ref;
        input integer n;
        integer depth;
        begin
            depth               = n * n;
            mismatch_count      = 0;
            first_mismatch_idx  = -1;
            first_mismatch_r    = -1;
            first_mismatch_c    = -1;

            for (idx = 0; idx < depth; idx = idx + 1) begin
                if (mat_c_hw[idx] !== mat_c_ref[idx]) begin
                    mismatch_count = mismatch_count + 1;
                    if (first_mismatch_idx < 0) begin
                        first_mismatch_idx = idx;
                        first_mismatch_r   = idx / n;
                        first_mismatch_c   = idx % n;
                    end
                end
            end

            if (mismatch_count != 0) begin
                $display("Matrix mismatch count: %0d", mismatch_count);
                $display("First mismatch at (%0d, %0d): hw=%0d ref=%0d",
                         first_mismatch_r,
                         first_mismatch_c,
                         mat_c_hw[first_mismatch_idx],
                         mat_c_ref[first_mismatch_idx]);
                $fatal(1, "Matrix multiply mismatch for N=%0d", n);
            end
        end
    endtask

    initial begin
        clk                = 1'b0;
        rst_n              = 1'b0;
        start              = 1'b0;
        matrix_dim         = '0;
        a_wr_en            = 1'b0;
        b_wr_en            = 1'b0;
        a_wr_addr          = '0;
        b_wr_addr          = '0;
        a_wr_data          = '0;
        b_wr_data          = '0;
        c_host_rd_addr     = '0;
        runtime_dim        = DEFAULT_SIM_N;
        runtime_seed       = DEFAULT_SIM_SEED;
        active_dim_seen    = 0;
        mismatch_count     = 0;
        first_mismatch_idx = -1;
        first_mismatch_r   = -1;
        first_mismatch_c   = -1;
        output_dir         = "sim/output";

        if ($value$plusargs("matrix_dim=%d", runtime_dim)) begin
            $display("Using runtime matrix_dim=%0d", runtime_dim);
        end
        if ($value$plusargs("seed=%d", runtime_seed)) begin
            $display("Using runtime seed=%0d", runtime_seed);
        end
        if ($value$plusargs("out_dir=%s", output_dir)) begin
            $display("Using runtime out_dir=%s", output_dir);
        end

        if ((runtime_dim < 1) || (runtime_dim > MAX_N)) begin
            $fatal(1, "matrix_dim must satisfy 1 <= matrix_dim <= %0d", MAX_N);
        end

        matrix_dim = runtime_dim[DIM_W-1:0];

        clear_storage();
        randomize_inputs(runtime_dim, runtime_seed);
        compute_reference(runtime_dim);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        $display("Writing matrices into DUT for N=%0d with ARRAY_N=%0d", runtime_dim, ARRAY_N);
        write_inputs_to_dut(runtime_dim);
        dump_matrix_a(runtime_dim);
        dump_matrix_b(runtime_dim);

        $display("Starting tiled matmul");
        start_core();
        wait_for_done();
        active_dim_seen = active_matrix_dim;

        $display("Reading DUT output. cycle_count=%0d active_dim=%0d", cycle_count, active_dim_seen);
        read_hw_result(runtime_dim);
        dump_matrix_c(runtime_dim);
        dump_run_info(runtime_dim, runtime_seed);
        dump_combined_case(runtime_dim, runtime_seed);
        compare_hw_vs_ref(runtime_dim);

        $display("PASS: tiled matrix multiply completed in %0d cycles for N=%0d using ARRAY_N=%0d",
                 cycle_count, runtime_dim, ARRAY_N);
        $finish;
    end

endmodule
