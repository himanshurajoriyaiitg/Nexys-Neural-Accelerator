// =============================================================================
// tb_tpu_top.sv  -  Self-checking testbench for tpu_top
//
// What it does:
//   1. Generates random NxN signed 8-bit matrices A and B using $urandom.
//   2. Writes them as hex files (weight.hex, data0.hex) for $readmemh.
//   3. Writes a single output.txt containing:
//        - Matrix A (decimal, space-separated rows)
//        - blank line
//        - Matrix B (decimal, space-separated rows)
//        - blank line
//        - TPU result C (decimal, space-separated rows)
//   4. Applies reset, pulses tpu_start, waits for tpu_done.
//   5. Run  python verify.py  to compare against NumPy reference.
//
// Change N_TB to test any matrix size (N <= 21 with 6-bit cycle counter).
// =============================================================================
`timescale 1ns/1ps

module tb_tpu_top;

    // ── Testbench parameters ──────────────────────────────────────────────────
    localparam int N_TB    = 16;
    localparam int DW_TB   = 8;
    localparam int ACCW_TB = 2*DW_TB + $clog2(N_TB);

    // ── DUT port signals ──────────────────────────────────────────────────────
    logic                         clk;
    logic                         rst_n;
    logic                         tpu_start;
    logic                         tpu_done;
    logic signed [ACCW_TB-1:0]    result [0:N_TB-1][0:N_TB-1];

    // ── DUT instantiation ─────────────────────────────────────────────────────
    tpu_top #(
        .N    (N_TB),
        .DW   (DW_TB),
        .ACCW (ACCW_TB)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .tpu_start (tpu_start),
        .tpu_done  (tpu_done),
        .result    (result)
    );

    // ── Clock: 10 ns period ───────────────────────────────────────────────────
    initial clk = 1'b0;
    always  #5  clk = ~clk;

    // ── Local random matrices ─────────────────────────────────────────────────
    byte signed A_tb [0:N_TB*N_TB-1];
    byte signed B_tb [0:N_TB*N_TB-1];

    integer fd;

    // =========================================================================
    // Task: write_hex_file
    // =========================================================================
    task automatic write_hex_file (
        input string  filename,
        ref   byte signed mem [0:N_TB*N_TB-1]
    );
        integer fh;
        fh = $fopen(filename, "w");
        if (fh == 0) begin
            $display("ERROR: cannot open %s for writing.", filename);
            $finish;
        end
        for (int k = 0; k < N_TB*N_TB; k++)
            $fwrite(fh, "%02h\n", 8'(mem[k]));
        $fclose(fh);
        $display("  Written: %s", filename);
    endtask

    // =========================================================================
    // Task: write_dec_block
    //   Writes one NxN matrix block (signed decimal) to an already-open fd.
    // =========================================================================
    task automatic write_dec_block (
        integer       fh,
        ref   byte signed mem [0:N_TB*N_TB-1]
    );
        for (int r = 0; r < N_TB; r++) begin
            for (int c = 0; c < N_TB; c++) begin
                $fwrite(fh, "%0d", mem[r*N_TB + c]);
                if (c != N_TB-1) $fwrite(fh, " ");
            end
            $fwrite(fh, "\n");
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        // ── Step 1: Generate random matrices ─────────────────────────────────
        $display("\n=== Generating random %0dx%0d matrices ===", N_TB, N_TB);
        for (int k = 0; k < N_TB*N_TB; k++) begin
            A_tb[k] = byte'($urandom());
            B_tb[k] = byte'($urandom());
        end

        // ── Step 2: Write hex files for $readmemh ────────────────────────────
        $display("Writing hex input files...");
        write_hex_file("weight.hex", A_tb);
        write_hex_file("data0.hex",  B_tb);

        // ── Step 3: Reset sequence ────────────────────────────────────────────
        $display("\nApplying reset...");
        rst_n     = 1'b0;
        tpu_start = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        $display("Reset released.");

        // ── Step 4: Pulse tpu_start for exactly one clock cycle ──────────────
        @(posedge clk); #1;
        tpu_start = 1'b1;
        @(posedge clk); #1;
        tpu_start = 1'b0;
        $display("tpu_start pulsed. Waiting for tpu_done...");

        // ── Step 5: Wait for tpu_done with watchdog ───────────────────────────
        fork
            begin : wait_done
                @(posedge tpu_done);
            end
            begin : watchdog
                repeat (500) @(posedge clk);
                $display("WATCHDOG TIMEOUT: tpu_done never asserted!");
                $finish;
            end
        join_any
        disable fork;

        $display("tpu_done received at time %0t ns.", $time);

        // Wait one more clock so result registers are fully settled
        @(posedge clk); #1;

        // ── Step 6: Write output.txt with A, B, and C ────────────────────────
        $display("Writing output.txt (A, B, TPU result)...");
        fd = $fopen("output.txt", "w");
        if (fd == 0) begin
            $display("ERROR: Cannot open output.txt");
            $finish;
        end

        // Write A
        write_dec_block(fd, A_tb);
        $fwrite(fd, "\n");

        // Write B
        write_dec_block(fd, B_tb);
        $fwrite(fd, "\n");

        // Write TPU result C
        for (int i = 0; i < N_TB; i++) begin
            for (int j = 0; j < N_TB; j++) begin
                $fwrite(fd, "%0d", $signed(result[i][j]));
                if (j != N_TB-1) $fwrite(fd, " ");
            end
            $fwrite(fd, "\n");
        end

        $fclose(fd);
        $display("  Written: output.txt");
        $display("\n=== Simulation complete. Run: python verify.py ===\n");
        $finish;
    end

    // ── Optional VCD waveform dump ────────────────────────────────────────────
    initial begin
        $dumpfile("tb_tpu.vcd");
        $dumpvars(0, tb_tpu_top);
    end

endmodule