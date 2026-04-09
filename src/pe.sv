// =============================================================================
// pe.sv  -  Processing Element
//
// Computes:  acc += a_in * b_in  (when en=1)
// Passes:    a_in → a_out,  b_in → b_out  (registered, 1-cycle latency)
//
// clear_acc: synchronous strobe to zero the accumulator between runs.
//            Must be pulsed for exactly 1 cycle before a new computation.
// =============================================================================
module pe #(
    parameter int DW   = 8,
    parameter int ACCW = 21
)(
    input  logic                   clk,
    input  logic                   rst_n,      // active-low async reset
    input  logic                   clear_acc,  // synchronous accumulator clear
    input  logic                   en,         // accumulate enable
    input  logic signed [DW-1:0]   a_in,
    input  logic signed [DW-1:0]   b_in,
    output logic signed [DW-1:0]   a_out,
    output logic signed [DW-1:0]   b_out,
    output logic signed [ACCW-1:0] acc
);

    // ── Pass-through registers (data wave propagation) ──────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= '0;
            b_out <= '0;
        end else begin
            a_out <= a_in;
            b_out <= b_in;
        end
    end

    // ── Accumulator ─────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= '0;
        end else if (clear_acc) begin
            acc <= '0;                               // synchronous clear
        end else if (en) begin
            acc <= acc + ACCW'(signed'(a_in) * signed'(b_in));
        end
    end

endmodule