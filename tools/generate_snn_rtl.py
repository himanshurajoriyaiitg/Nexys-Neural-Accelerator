import numpy as np
import os

def generate_rtl():
    weights_file = os.path.join(os.path.dirname(__file__), 'snn_weights.npz')
    data = np.load(weights_file)
    w1 = data['w1']  # 64 x 256
    w2 = data['w2']  # 10 x 64
    b1 = data['b1']  # 64
    b2 = data['b2']  # 10
    
    rtl_dir = os.path.join(os.path.dirname(__file__), '..', 'rtl')
    os.makedirs(rtl_dir, exist_ok=True)
    
    # 1. Generate snn_weights.sv
    with open(os.path.join(rtl_dir, 'snn_weights.sv'), 'w') as f:
        f.write("`timescale 1ns / 1ps\n\n")
        f.write("module snn_weights (\n")
        f.write("    input  wire         clk,\n")
        f.write("    input  wire [5:0]   w1_row_addr,\n")
        f.write("    input  wire [7:0]   w1_col_addr,\n")
        f.write("    output reg  signed [31:0] w1_data,\n")
        f.write("    input  wire [3:0]   w2_row_addr,\n")
        f.write("    input  wire [5:0]   w2_col_addr,\n")
        f.write("    output reg  signed [31:0] w2_data,\n")
        f.write("    input  wire [5:0]   b1_addr,\n")
        f.write("    output reg  signed [31:0] b1_data,\n")
        f.write("    input  wire [3:0]   b2_addr,\n")
        f.write("    output reg  signed [31:0] b2_data\n")
        f.write(");\n\n")
        
        # W1 ROM
        f.write("    always @(posedge clk) begin\n")
        f.write("        case ({w1_row_addr, w1_col_addr})\n")
        for r in range(w1.shape[0]):
            for c in range(w1.shape[1]):
                if w1[r,c] != 0:
                    f.write(f"            14'd{(r << 8) | c}: w1_data <= {w1[r,c]};\n")
        f.write("            default: w1_data <= 0;\n")
        f.write("        endcase\n")
        f.write("    end\n\n")
        
        # W2 ROM
        f.write("    always @(posedge clk) begin\n")
        f.write("        case ({w2_row_addr, w2_col_addr})\n")
        for r in range(w2.shape[0]):
            for c in range(w2.shape[1]):
                if w2[r,c] != 0:
                    f.write(f"            10'd{(r << 6) | c}: w2_data <= {w2[r,c]};\n")
        f.write("            default: w2_data <= 0;\n")
        f.write("        endcase\n")
        f.write("    end\n\n")
        
        # B1 ROM
        f.write("    always @(posedge clk) begin\n")
        f.write("        case (b1_addr)\n")
        for r in range(b1.shape[0]):
            f.write(f"            6'd{r}: b1_data <= {b1[r]};\n")
        f.write("            default: b1_data <= 0;\n")
        f.write("        endcase\n")
        f.write("    end\n\n")

        # B2 ROM
        f.write("    always @(posedge clk) begin\n")
        f.write("        case (b2_addr)\n")
        for r in range(b2.shape[0]):
            f.write(f"            4'd{r}: b2_data <= {b2[r]};\n")
        f.write("            default: b2_data <= 0;\n")
        f.write("        endcase\n")
        f.write("    end\n\n")
        
        f.write("endmodule\n")

    # 2. Generate snn_core.sv (The FSM)
    # The FSM mimics the exact VHDL behavior:
    # 20 steps. 
    # For each step: FC1 -> LIF1 -> FC2 -> LIF2.
    # Note: the input image is 256 bytes.
    with open(os.path.join(rtl_dir, 'snn_core.sv'), 'w') as f:
        f.write("""`timescale 1ns / 1ps

module snn_core (
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

    // FSM States
    typedef enum logic [3:0] {
        IDLE,
        FC1_CALC,
        LIF1_CALC,
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
            for (int i=0; i<64; i++) mem1[i] <= 0;
            for (int i=0; i<10; i++) mem2[i] <= 0;
            for (int i=0; i<10; i++) scores[i] <= 0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    if (start) begin
                        state <= FC1_CALC;
                        step_cnt <= 0;
                        i_cnt <= 0;
                        j_cnt <= 0;
                        for (int i=0; i<64; i++) mem1[i] <= 0;
                        for (int i=0; i<10; i++) mem2[i] <= 0;
                        for (int i=0; i<10; i++) scores[i] <= 0;
                        w1_row_addr <= 0;
                        w1_col_addr <= 0;
                        b1_addr <= 0;
                    end
                end
                
                FC1_CALC: begin
                    if (i_cnt == 0) begin
                        mac_acc <= 0;
                        w1_row_addr <= j_cnt;
                        w1_col_addr <= i_cnt;
                        i_cnt <= 1;
                    end else if (i_cnt <= 256) begin
                        mac_acc <= mac_acc + w1_data * $signed({24'b0, img_data[i_cnt-1]});
                        if (i_cnt < 256) begin
                            w1_col_addr <= i_cnt;
                            i_cnt <= i_cnt + 1;
                        end else begin
                            logic signed [31:0] final_mac;
                            final_mac = mac_acc + w1_data * $signed({24'b0, img_data[255]});
                            fc1_out[j_cnt] <= (final_mac >>> 8) + b1_data;
                            if (j_cnt < 63) begin
                                j_cnt <= j_cnt + 1;
                                b1_addr <= j_cnt + 1;
                                i_cnt <= 0;
                            end else begin
                                state <= LIF1_CALC;
                                j_cnt <= 0;
                            end
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
                        state <= FC2_CALC;
                        j_cnt <= 0;
                        i_cnt <= 0;
                        b2_addr <= 0;
                    end
                end
                
                FC2_CALC: begin
                    if (i_cnt == 0) begin
                        mac_acc <= 0;
                        w2_row_addr <= j_cnt;
                        w2_col_addr <= i_cnt;
                        i_cnt <= 1;
                    end else if (i_cnt <= 64) begin
                        if (spikes1[i_cnt-1]) begin
                            mac_acc <= mac_acc + (w2_data * Q_SCALE);
                        end
                        if (i_cnt < 64) begin
                            w2_col_addr <= i_cnt;
                            i_cnt <= i_cnt + 1;
                        end else begin
                            logic signed [31:0] final_val;
                            final_val = mac_acc;
                            if (spikes1[63]) final_val = mac_acc + (w2_data * Q_SCALE);
                            fc2_out[j_cnt] <= (final_val >>> 8) + b2_data;
                            
                            if (j_cnt < 9) begin
                                j_cnt <= j_cnt + 1;
                                b2_addr <= j_cnt + 1;
                                i_cnt <= 0;
                            end else begin
                                state <= LIF2_CALC;
                                j_cnt <= 0;
                            end
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
                            state <= FC1_CALC;
                            j_cnt <= 0;
                            i_cnt <= 0;
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
                    for (int i=1; i<10; i++) begin
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
""")

if __name__ == "__main__":
    generate_rtl()
    print("Generated snn_weights.sv and snn_core.sv")
