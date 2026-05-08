`timescale 1ns / 1ps

module snn_core_legacy (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [7:0] img_data [0:255],
    output reg  done,
    output reg  [3:0] prediction
);

    localparam NUM_STEPS = 20;
    localparam Q_SCALE = 256;
    localparam Q_FRAC_BITS = 8;
    localparam LIF_BETA_Q = 230;
    localparam THRESHOLD_Q = 256;

    // The weight store is synchronous, so each FC layer needs a one-cycle prime
    // step before the multiply-accumulate loop can consume valid ROM data.
    typedef enum logic [3:0] {
        IDLE,
        FC1_PRIME,
        FC1_CALC,
        LIF1_CALC,
        FC2_PRIME,
        FC2_CALC,
        LIF2_CALC,
        ARGMAX
    } state_t;

    state_t state;

    logic [4:0] step_cnt;
    logic [8:0] i_cnt;
    logic [6:0] j_cnt;

    logic [5:0] w1_row_addr;
    logic [7:0] w1_col_addr;
    logic signed [31:0] w1_data;

    logic [3:0] w2_row_addr;
    logic [5:0] w2_col_addr;
    logic signed [31:0] w2_data;

    logic [5:0] b1_addr;
    logic signed [31:0] b1_data;

    logic [3:0] b2_addr;
    logic signed [31:0] b2_data;

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

    logic signed [31:0] fc1_out [0:63];
    logic signed [31:0] mem1 [0:63];
    logic spikes1 [0:63];

    logic signed [31:0] fc2_out [0:9];
    logic signed [31:0] mem2 [0:9];
    logic spikes2 [0:9];

    logic signed [31:0] scores [0:9];

    logic signed [31:0] mac_acc;
    logic signed [31:0] vtmp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            prediction <= 0;
            step_cnt <= 0;
            i_cnt <= 0;
            j_cnt <= 0;
            w1_row_addr <= 0;
            w1_col_addr <= 0;
            w2_row_addr <= 0;
            w2_col_addr <= 0;
            b1_addr <= 0;
            b2_addr <= 0;
            mac_acc <= 0;
            vtmp <= 0;
            for (int i = 0; i < 64; i++) fc1_out[i] <= 0;
            for (int i = 0; i < 64; i++) mem1[i] <= 0;
            for (int i = 0; i < 64; i++) spikes1[i] <= 0;
            for (int i = 0; i < 10; i++) fc2_out[i] <= 0;
            for (int i = 0; i < 10; i++) mem2[i] <= 0;
            for (int i = 0; i < 10; i++) spikes2[i] <= 0;
            for (int i = 0; i < 10; i++) scores[i] <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: begin
                    if (start) begin
                        state <= FC1_PRIME;
                        step_cnt <= 0;
                        i_cnt <= 0;
                        j_cnt <= 0;
                        mac_acc <= 0;
                        prediction <= 0;
                        w1_row_addr <= 0;
                        w1_col_addr <= 0;
                        w2_row_addr <= 0;
                        w2_col_addr <= 0;
                        b1_addr <= 0;
                        b2_addr <= 0;
                        for (int i = 0; i < 64; i++) fc1_out[i] <= 0;
                        for (int i = 0; i < 64; i++) mem1[i] <= 0;
                        for (int i = 0; i < 64; i++) spikes1[i] <= 0;
                        for (int i = 0; i < 10; i++) fc2_out[i] <= 0;
                        for (int i = 0; i < 10; i++) mem2[i] <= 0;
                        for (int i = 0; i < 10; i++) spikes2[i] <= 0;
                        for (int i = 0; i < 10; i++) scores[i] <= 0;
                    end
                end

                FC1_PRIME: begin
                    mac_acc <= 0;
                    i_cnt <= 0;
                    w1_col_addr <= 8'd1;
                    state <= FC1_CALC;
                end

                FC1_CALC: begin
                    if (i_cnt < 255) begin
                        mac_acc <= mac_acc + w1_data * $signed({24'b0, img_data[i_cnt]});
                        if (i_cnt < 254) begin
                            w1_col_addr <= i_cnt[7:0] + 8'd2;
                        end
                        i_cnt <= i_cnt + 1;
                    end else begin
                        logic signed [31:0] final_mac;
                        final_mac = mac_acc + w1_data * $signed({24'b0, img_data[255]});
                        fc1_out[j_cnt] <= (final_mac >>> 8) + b1_data;
                        if (j_cnt < 63) begin
                            j_cnt <= j_cnt + 1;
                            w1_row_addr <= j_cnt[5:0] + 6'd1;
                            w1_col_addr <= 8'd0;
                            b1_addr <= j_cnt[5:0] + 6'd1;
                            state <= FC1_PRIME;
                        end else begin
                            j_cnt <= 0;
                            state <= LIF1_CALC;
                        end
                    end
                end

                LIF1_CALC: begin
                    if (j_cnt < 64) begin
                        vtmp = ((LIF_BETA_Q * mem1[j_cnt]) >>> Q_FRAC_BITS) + fc1_out[j_cnt];
                        if (vtmp > THRESHOLD_Q) begin
                            spikes1[j_cnt] <= 1;
                            mem1[j_cnt] <= vtmp - THRESHOLD_Q;
                        end else begin
                            spikes1[j_cnt] <= 0;
                            mem1[j_cnt] <= vtmp;
                        end
                        j_cnt <= j_cnt + 1;
                    end else begin
                        state <= FC2_PRIME;
                        j_cnt <= 0;
                        w2_row_addr <= 0;
                        w2_col_addr <= 0;
                        b2_addr <= 0;
                    end
                end

                FC2_PRIME: begin
                    mac_acc <= 0;
                    i_cnt <= 0;
                    w2_col_addr <= 6'd1;
                    state <= FC2_CALC;
                end

                FC2_CALC: begin
                    if (i_cnt < 63) begin
                        if (spikes1[i_cnt]) begin
                            mac_acc <= mac_acc + (w2_data * Q_SCALE);
                        end
                        if (i_cnt < 62) begin
                            w2_col_addr <= i_cnt[5:0] + 6'd2;
                        end
                        i_cnt <= i_cnt + 1;
                    end else begin
                        logic signed [31:0] final_val;
                        final_val = mac_acc;
                        if (spikes1[63]) begin
                            final_val = final_val + (w2_data * Q_SCALE);
                        end
                        fc2_out[j_cnt] <= (final_val >>> 8) + b2_data;

                        if (j_cnt < 9) begin
                            j_cnt <= j_cnt + 1;
                            w2_row_addr <= j_cnt[3:0] + 4'd1;
                            w2_col_addr <= 6'd0;
                            b2_addr <= j_cnt[3:0] + 4'd1;
                            state <= FC2_PRIME;
                        end else begin
                            j_cnt <= 0;
                            state <= LIF2_CALC;
                        end
                    end
                end

                LIF2_CALC: begin
                    if (j_cnt < 10) begin
                        vtmp = ((LIF_BETA_Q * mem2[j_cnt]) >>> Q_FRAC_BITS) + fc2_out[j_cnt];
                        if (vtmp > THRESHOLD_Q) begin
                            spikes2[j_cnt] <= 1;
                            mem2[j_cnt] <= vtmp - THRESHOLD_Q;
                            scores[j_cnt] <= scores[j_cnt] + Q_SCALE;
                        end else begin
                            spikes2[j_cnt] <= 0;
                            mem2[j_cnt] <= vtmp;
                        end
                        j_cnt <= j_cnt + 1;
                    end else begin
                        if (step_cnt < NUM_STEPS - 1) begin
                            step_cnt <= step_cnt + 1;
                            state <= FC1_PRIME;
                            j_cnt <= 0;
                            w1_row_addr <= 0;
                            w1_col_addr <= 0;
                            b1_addr <= 0;
                        end else begin
                            state <= ARGMAX;
                            j_cnt <= 0;
                        end
                    end
                end

                ARGMAX: begin
                    logic signed [31:0] max_score;
                    logic [3:0] max_idx;
                    max_score = scores[0];
                    max_idx = 0;
                    for (int i = 1; i < 10; i++) begin
                        if (scores[i] > max_score) begin
                            max_score = scores[i];
                            max_idx = i;
                        end
                    end
                    prediction <= max_idx;
                    done <= 1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
