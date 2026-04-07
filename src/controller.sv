// =============================================================================
// controller.sv  -  FSM that drives the systolic array
//
// State machine:
//
//   IDLE  ──(start)──► CLEAR ──► RUN ──(cycle==3N-3)──► DONE ──► IDLE
//
//   IDLE  : waits for start pulse.
//   CLEAR : asserts clear_acc for exactly 1 clock. en=0, cycle stays 0.
//   RUN   : asserts en for exactly (3N-2) clocks (cycle 0 .. 3N-3).
//             • For an NxN systolic array with diagonal skew feeding,
//               PE(i,j) receives its last product at cycle (N-1)+i+j.
//               The maximum is at PE(N-1,N-1): cycle = 3*(N-1) = 3N-3.
//             Total = 3N-2 run cycles → indices 0 .. 3N-3.
//   DONE  : pulses done=1 for exactly 1 clock, then returns to IDLE.
//
// KEY FIX vs original:
//   Original had TOTAL=3N-1 (one cycle too many) and asserted en=1 in
//   the CLEAR state, causing cycle-0 to be fed twice (double-accumulation
//   of the main diagonal).  Now en is only ever asserted inside RUN.
// =============================================================================
module controller #(
    parameter int N = 4
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,
    output logic       clear_acc,
    output logic       en,
    output logic       done,
    output logic [5:0] cycle    // enough for 3*N-3 ≤ 63  (N ≤ 22)
);

    // 3N-2 total RUN cycles → last index = 3N-3
    localparam int LAST = 3*N - 3;   // = 3*(N-1)

    typedef enum logic [1:0] {
        IDLE  = 2'd0,
        CLEAR = 2'd1,
        RUN   = 2'd2,
        DONE  = 2'd3
    } state_t;

    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            clear_acc <= 1'b0;
            en        <= 1'b0;
            done      <= 1'b0;
            cycle     <= 6'd0;
        end else begin
            // Default: deassert every single-cycle signal each clock
            clear_acc <= 1'b0;
            en        <= 1'b0;
            done      <= 1'b0;

            case (state)
                // ── Wait for start ────────────────────────────────────────
                IDLE: begin
                    cycle <= 6'd0;
                    if (start) begin
                        clear_acc <= 1'b1;   // pulse clear this cycle
                        state     <= CLEAR;
                    end
                end

                // ── Accumulator clear (1 cycle) ───────────────────────────
                // en is NOT asserted here.  The PEs absorb the clear on this
                // posedge; on the very next posedge en goes high for cycle 0.
                CLEAR: begin
                    cycle <= 6'd0;
                    // en stays 0 (default above)
                    state <= RUN;
                end

                // ── Feed data for (3N-2) cycles ───────────────────────────
                RUN: begin
                    en <= 1'b1;
                    if (cycle == 6'(LAST)) begin
                        state <= DONE;
                        cycle <= 6'd0;
                    end else begin
                        cycle <= cycle + 6'd1;
                    end
                end

                // ── Signal completion (1-cycle pulse) ─────────────────────
                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                    cycle <= 6'd0;
                    if (start) begin
                        clear_acc <= 1'b1;
                        state     <= CLEAR;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
