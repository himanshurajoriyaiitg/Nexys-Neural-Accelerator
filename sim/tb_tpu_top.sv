`timescale 1ns / 1ps
`include "params.vh"

module tb_tpu_top;

    localparam integer MAX_N     = `DEFAULT_MATRIX_N;
    localparam integer ARRAY_N   = `DEFAULT_ARRAY_N;
    localparam integer TEST_N    = (MAX_N >= (2 * ARRAY_N)) ? (2 * ARRAY_N) : MAX_N;
    localparam integer DW        = `DEFAULT_DW;
    localparam integer DIM_W     = ((MAX_N + 1) <= 1) ? 1 : $clog2(MAX_N + 1);
    localparam integer ACCW      = 2*DW + $clog2(MAX_N);
    localparam integer MAX_DEPTH = MAX_N * MAX_N;
    localparam integer DEPTH     = TEST_N * TEST_N;
    localparam integer ADDRW     = (MAX_DEPTH <= 1) ? 1 : $clog2(MAX_DEPTH);
    localparam integer RUN_W     = (((3 * ARRAY_N) - 2) <= 1) ? 1 : $clog2((3 * ARRAY_N) - 2);

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

    reg signed [DW-1:0]   mat_a [0:DEPTH-1];
    reg signed [DW-1:0]   mat_b [0:DEPTH-1];
    reg signed [ACCW-1:0] mat_c_hw [0:DEPTH-1];
    reg signed [ACCW-1:0] mat_c_ref [0:DEPTH-1];

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

    task automatic randomize_inputs;
        integer rand_a;
        integer rand_b;
        begin
            for (idx = 0; idx < DEPTH; idx = idx + 1) begin
                rand_a = $urandom_range(0, 255) - 128;
                rand_b = $urandom_range(0, 255) - 128;
                mat_a[idx] = $signed(rand_a[DW-1:0]);
                mat_b[idx] = $signed(rand_b[DW-1:0]);
            end
        end
    endtask

    task automatic write_inputs_to_dut;
        begin
            for (idx = 0; idx < DEPTH; idx = idx + 1) begin
                @(posedge clk);
                a_wr_en   <= 1'b1;
                a_wr_addr <= idx[ADDRW-1:0];
                a_wr_data <= mat_a[idx];
                b_wr_en   <= 1'b1;
                b_wr_addr <= idx[ADDRW-1:0];
                b_wr_data <= mat_b[idx];
            end

            @(posedge clk);
            a_wr_en <= 1'b0;
            b_wr_en <= 1'b0;
        end
    endtask

    task automatic compute_reference;
        integer sum_val;
        begin
            for (r = 0; r < TEST_N; r = r + 1) begin
                for (c = 0; c < TEST_N; c = c + 1) begin
                    sum_val = 0;
                    for (k = 0; k < TEST_N; k = k + 1) begin
                        sum_val = sum_val + (mat_a[r*TEST_N + k] * mat_b[k*TEST_N + c]);
                    end
                    mat_c_ref[r*TEST_N + c] = sum_val;
                end
            end
        end
    endtask

    task automatic read_hw_result;
        begin
            c_host_rd_addr <= '0;
            @(posedge clk);
            @(posedge clk);
            for (idx = 0; idx < DEPTH; idx = idx + 1) begin
                mat_c_hw[idx] = c_host_rd_data;
                if (idx != (DEPTH - 1)) begin
                    c_host_rd_addr <= idx + 1;
                end
                @(posedge clk);
            end
            @(posedge clk);
        end
    endtask

    task automatic dump_matrix_a;
        begin
            file_a = $fopen("sim/output/matrix_a.txt", "w");
            for (r = 0; r < TEST_N; r = r + 1) begin
                for (c = 0; c < TEST_N; c = c + 1) begin
                    $fwrite(file_a, "%0d", mat_a[r*TEST_N + c]);
                    if (c != (TEST_N - 1)) begin
                        $fwrite(file_a, " ");
                    end
                end
                $fwrite(file_a, "\n");
            end
            $fclose(file_a);
        end
    endtask

    task automatic dump_matrix_b;
        begin
            file_b = $fopen("sim/output/matrix_b.txt", "w");
            for (r = 0; r < TEST_N; r = r + 1) begin
                for (c = 0; c < TEST_N; c = c + 1) begin
                    $fwrite(file_b, "%0d", mat_b[r*TEST_N + c]);
                    if (c != (TEST_N - 1)) begin
                        $fwrite(file_b, " ");
                    end
                end
                $fwrite(file_b, "\n");
            end
            $fclose(file_b);
        end
    endtask

    task automatic dump_matrix_c;
        begin
            file_c = $fopen("sim/output/matrix_c_hw.txt", "w");
            for (r = 0; r < TEST_N; r = r + 1) begin
                for (c = 0; c < TEST_N; c = c + 1) begin
                    $fwrite(file_c, "%0d", mat_c_hw[r*TEST_N + c]);
                    if (c != (TEST_N - 1)) begin
                        $fwrite(file_c, " ");
                    end
                end
                $fwrite(file_c, "\n");
            end
            $fclose(file_c);
        end
    endtask

    task automatic dump_run_info;
        begin
            file_meta = $fopen("sim/output/run_info.txt", "w");
            $fwrite(file_meta, "MAX_N=%0d\n", MAX_N);
            $fwrite(file_meta, "TEST_N=%0d\n", TEST_N);
            $fwrite(file_meta, "ARRAY_N=%0d\n", ARRAY_N);
            $fwrite(file_meta, "DATA_W=%0d\n", DW);
            $fwrite(file_meta, "ACC_W=%0d\n", ACCW);
            $fwrite(file_meta, "ACTIVE_DIM=%0d\n", active_matrix_dim);
            $fwrite(file_meta, "CYCLES=%0d\n", cycle_count);
            $fclose(file_meta);
        end
    endtask

    task automatic compare_hw_vs_ref;
        begin
            for (idx = 0; idx < DEPTH; idx = idx + 1) begin
                if (mat_c_hw[idx] !== mat_c_ref[idx]) begin
                    $display("Mismatch at index %0d: hw=%0d ref=%0d", idx, mat_c_hw[idx], mat_c_ref[idx]);
                    $fatal(1, "Matrix mismatch");
                end
            end
        end
    endtask

    initial begin
        clk            = 1'b0;
        rst_n          = 1'b0;
        start          = 1'b0;
        matrix_dim     = TEST_N[DIM_W-1:0];
        a_wr_en        = 1'b0;
        b_wr_en        = 1'b0;
        a_wr_addr      = '0;
        b_wr_addr      = '0;
        a_wr_data      = '0;
        b_wr_data      = '0;
        c_host_rd_addr = '0;

        randomize_inputs();
        compute_reference();

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;

        write_inputs_to_dut();
        dump_matrix_a();
        dump_matrix_b();

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        repeat (200000) begin
            @(posedge clk);
            if (done) begin
                read_hw_result();
                compare_hw_vs_ref();
                dump_matrix_c();
                dump_run_info();
                $display("PASS: tiled matrix multiply completed in %0d cycles for N=%0d", cycle_count, TEST_N);
                $finish;
            end
        end

        $fatal(1, "Timeout waiting for done.");
    end

endmodule
