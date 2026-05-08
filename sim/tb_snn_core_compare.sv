`timescale 1ns / 1ps

module tb_snn_core_compare;

    localparam integer NUM_CASES = 4;
    localparam integer TIMEOUT_CYCLES = 2_500_000;

    reg clk;
    reg rst_n;
    reg start;
    reg [7:0] img_data [0:255];

    wire done_new;
    wire [3:0] pred_new;
    wire done_legacy;
    wire [3:0] pred_legacy;

    integer case_idx;
    integer pix_idx;
    integer row_idx;
    integer col_idx;
    integer rng_state;
    integer waited_cycles;
    integer saw_new;
    integer saw_legacy;
    reg [3:0] latched_new;
    reg [3:0] latched_legacy;

    snn_core dut_new (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .img_data(img_data),
        .done(done_new),
        .prediction(pred_new)
    );

    snn_core_legacy dut_legacy (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .img_data(img_data),
        .done(done_legacy),
        .prediction(pred_legacy)
    );

    always #5 clk = ~clk;

    task automatic load_case;
        input integer idx;
        integer center_r;
        integer center_c;
        integer dr;
        integer dc;
        begin
            for (pix_idx = 0; pix_idx < 256; pix_idx = pix_idx + 1) begin
                img_data[pix_idx] = 8'd0;
            end

            case (idx)
                0: begin
                    // Keep the blank frame for a deterministic baseline.
                end

                1: begin
                    // Simple "0"-like ring.
                    for (row_idx = 3; row_idx <= 12; row_idx = row_idx + 1) begin
                        img_data[(row_idx * 16) + 3] = 8'd220;
                        img_data[(row_idx * 16) + 12] = 8'd220;
                    end
                    for (col_idx = 3; col_idx <= 12; col_idx = col_idx + 1) begin
                        img_data[(3 * 16) + col_idx] = 8'd220;
                        img_data[(12 * 16) + col_idx] = 8'd220;
                    end
                end

                2: begin
                    // Diagonal slash with a brighter base.
                    for (row_idx = 2; row_idx < 14; row_idx = row_idx + 1) begin
                        img_data[(row_idx * 16) + row_idx] = 8'd255;
                        if (row_idx + 1 < 16) begin
                            img_data[(row_idx * 16) + row_idx + 1] = 8'd160;
                        end
                    end
                    for (col_idx = 4; col_idx < 12; col_idx = col_idx + 1) begin
                        img_data[(13 * 16) + col_idx] = 8'd180;
                    end
                end

                default: begin
                    // Deterministic random stress case.
                    rng_state = 32'h1357_2468 + idx;
                    for (pix_idx = 0; pix_idx < 256; pix_idx = pix_idx + 1) begin
                        img_data[pix_idx] = $random(rng_state);
                    end

                    // Add one bright centered blob so we do not only test noise.
                    center_r = 8;
                    center_c = 8;
                    for (dr = -1; dr <= 1; dr = dr + 1) begin
                        for (dc = -1; dc <= 1; dc = dc + 1) begin
                            img_data[((center_r + dr) * 16) + center_c + dc] = 8'd240;
                        end
                    end
                end
            endcase
        end
    endtask

    task automatic run_case;
        input integer idx;
        begin
            load_case(idx);
            saw_new = 0;
            saw_legacy = 0;
            latched_new = 4'd0;
            latched_legacy = 4'd0;

            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            waited_cycles = 0;
            while (!(saw_new && saw_legacy)) begin
                @(negedge clk);
                waited_cycles = waited_cycles + 1;

                if (done_new) begin
                    saw_new = 1;
                    latched_new = pred_new;
                end
                if (done_legacy) begin
                    saw_legacy = 1;
                    latched_legacy = pred_legacy;
                end

                if (waited_cycles > TIMEOUT_CYCLES) begin
                    $fatal(1, "Timeout waiting for case %0d", idx);
                end
            end

            if (latched_new !== latched_legacy) begin
                $fatal(
                    1,
                    "Prediction mismatch on case %0d: new=%0d legacy=%0d",
                    idx,
                    latched_new,
                    latched_legacy
                );
            end

            $display(
                "PASS: case %0d matched prediction %0d after %0d cycles",
                idx,
                latched_new,
                waited_cycles
            );
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        for (pix_idx = 0; pix_idx < 256; pix_idx = pix_idx + 1) begin
            img_data[pix_idx] = 8'd0;
        end

        repeat (10) @(negedge clk);
        rst_n = 1'b1;

        for (case_idx = 0; case_idx < NUM_CASES; case_idx = case_idx + 1) begin
            run_case(case_idx);
        end

        $display("PASS: TPU-backed snn_core matches snn_core_legacy.");
        $finish;
    end

endmodule
