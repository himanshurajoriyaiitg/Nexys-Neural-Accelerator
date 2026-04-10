// =============================================================================
// tpu_top.sv  -  Top-level: controller + diagonal feeder + systolic array
//
// Computes C = A * B for NxN signed integer matrices.
//   A is stored in "weight.hex"  (row-major, 2-hex-digit per element)
//   B is stored in "data0.hex"   (row-major, 2-hex-digit per element)
//
// ── Diagonal (skewed) feeding ─────────────────────────────────────────────
//
//   For C[i][j] = Σ_k A[i][k]*B[k][j], element A[i][k] must meet B[k][j]
//   at PE(i,j).  Because data takes one clock per PE hop:
//     A[i][k] injected at LEFT  edge row i reaches PE(i,j) at cycle k+j.
//     B[k][j] injected at TOP   edge col j reaches PE(i,j) at cycle k+i.
//   For them to meet at the same cycle:
//     Inject A[i][k] at cycle (k + i)  →  feed_a[i] = A[i][ cycle - i ]
//     Inject B[k][j] at cycle (k + j)  →  feed_b[j] = B[ cycle - j ][j]
//
// ── KEY FIX vs original ───────────────────────────────────────────────────
//   Original code used the same loop variable `ii` for BOTH the A-row skew
//   and the B-column skew, and gated both on `en`.  The feeder must use
//   separate indices (ii for rows of A, jj for columns of B).
//   The `en` gate is removed from the feeder: the range-check
//   (0 <= k < N) already outputs 0 outside the valid window, and gating
//   on `en` would suppress zeros that should propagate through the array.
//
// ── Overflow safety ───────────────────────────────────────────────────────
//   ACCW = 2*DW + $clog2(N) guarantees no overflow for NxN multiply of
//   DW-bit signed values.
// =============================================================================
module tpu_top #(
    parameter int N    = 4,
    parameter int DW   = 8,
    parameter int ACCW = 2*DW + $clog2(N)
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     tpu_start,
    output logic                     tpu_done,
    output logic signed [ACCW-1:0]   result [0:N-1][0:N-1]
);

    // ── Controller ────────────────────────────────────────────────────────────
    logic        clear_acc;
    logic        en;
    logic [5:0]  cycle;

    controller #(
        .N (N)
    ) u_ctrl (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (tpu_start),
        .clear_acc (clear_acc),
        .en        (en),
        .done      (tpu_done),
        .cycle     (cycle)
    );

    // ── On-chip memory (loaded from hex files at simulation start) ────────────
    logic signed [DW-1:0] A_mem [0:N*N-1];   // matrix A, row-major
    logic signed [DW-1:0] B_mem [0:N*N-1];   // matrix B, row-major

    initial begin
        $readmemh("weight.hex", A_mem);
        $readmemh("data0.hex",  B_mem);
    end

    // ── Combinational diagonal feeder ─────────────────────────────────────────
    //
    //   a_feed[i] = A_mem[i*N + (cycle-i)]   when 0 <= (cycle-i) < N
    //               0                         otherwise
    //
    //   b_feed[j] = B_mem[(cycle-j)*N + j]   when 0 <= (cycle-j) < N
    //               0                         otherwise
    //
    // NOTE: No `en` gate here.  The out-of-range check already makes feeds=0
    //       outside the active window.  Gating on `en` would incorrectly
    //       suppress the first valid cycle when en rises simultaneously.
    logic signed [DW-1:0] a_feed [0:N-1];
    logic signed [DW-1:0] b_feed [0:N-1];

    always_comb begin
        for (int ii = 0; ii < N; ii++) begin
            automatic int ka = int'(cycle) - ii;   // A row-skew
            if (ka >= 0 && ka < N)
                a_feed[ii] = A_mem[ii * N + ka];
            else
                a_feed[ii] = '0;
        end
        for (int jj = 0; jj < N; jj++) begin
            automatic int kb = int'(cycle) - jj;   // B col-skew  (was wrongly `ii`)
            if (kb >= 0 && kb < N)
                b_feed[jj] = B_mem[kb * N + jj];
            else
                b_feed[jj] = '0;
        end
    end

    // ── Systolic array ────────────────────────────────────────────────────────
    systolic_array #(
        .N    (N),
        .DW   (DW),
        .ACCW (ACCW)
    ) u_sa (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear_acc (clear_acc),
        .en        (en),
        .a_in      (a_feed),
        .b_in      (b_feed),
        .c_out     (result)
    );

endmodule
