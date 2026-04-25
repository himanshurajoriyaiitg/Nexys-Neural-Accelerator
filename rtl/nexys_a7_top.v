`timescale 1ns / 1ps
`include "params.vh"

module nexys_a7_top #(
    parameter integer N         = `DEFAULT_MATRIX_N,
    parameter integer ARRAY_N   = `DEFAULT_ARRAY_N,
    parameter integer DW        = `DEFAULT_DW,
    parameter integer DIM_W     = ((N + 1) <= 1) ? 1 : $clog2(N + 1),
    parameter integer ACCW      = 2*DW + $clog2(N),
    parameter integer CLK_HZ    = `DEFAULT_CLK_HZ,
    parameter integer UART_BAUD = `DEFAULT_UART_BAUD
)(
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        UART_TXD_IN,
    output wire        UART_RXD_OUT,
    output wire [15:0] LED
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

    function [1:0] low2;
        input integer value;
        begin
            low2 = value[1:0];
        end
    endfunction

    localparam integer MATRIX_ELEMS = N * N;
    localparam integer ADDRW        = clog2_safe(MATRIX_ELEMS);
    localparam integer RUN_W        = clog2_safe((3 * ARRAY_N) - 1);
    localparam integer HEARTBEAT_W               = 27;
    localparam integer ACTIVITY_LED_HOLD_CYCLES = CLK_HZ;
    localparam integer STAGE_LED_HOLD_CYCLES    = CLK_HZ * 2;
    localparam integer LED_PROGRESS_STEP_CYCLES =
        (CLK_HZ / 4) > 0 ? (CLK_HZ / 4) : 1;
    localparam integer LED_HOLD_CYCLES_MAX      =
        (STAGE_LED_HOLD_CYCLES > ACTIVITY_LED_HOLD_CYCLES) ?
        STAGE_LED_HOLD_CYCLES : ACTIVITY_LED_HOLD_CYCLES;
    localparam integer LED_HOLD_W = clog2_safe(LED_HOLD_CYCLES_MAX + 1);
    localparam integer LED_PROGRESS_W = clog2_safe(LED_PROGRESS_STEP_CYCLES);

    localparam [7:0] FRAME_START = 8'hA5;
    localparam [7:0] CMD_WRITE_A = 8'h01;
    localparam [7:0] CMD_WRITE_B = 8'h02;
    localparam [7:0] CMD_START   = 8'h03;
    localparam [7:0] CMD_STATUS  = 8'h04;
    localparam [7:0] CMD_DUMP_C  = 8'h05;

    localparam [7:0] RESP_ACK    = 8'h5A;
    localparam [7:0] RESP_ERROR  = 8'hE0;
    localparam [7:0] RESP_STATUS = 8'hA6;
    localparam [7:0] RESP_DUMP   = 8'hA7;

    localparam [2:0] RX_WAIT_START = 3'd0;
    localparam [2:0] RX_WAIT_CMD   = 3'd1;
    localparam [2:0] RX_WAIT_AHI   = 3'd2;
    localparam [2:0] RX_WAIT_ALO   = 3'd3;
    localparam [2:0] RX_WAIT_DATA  = 3'd4;

    localparam [3:0] STREAM_IDLE         = 4'd0;
    localparam [3:0] STREAM_STATUS_FLAGS = 4'd1;
    localparam [3:0] STREAM_STATUS_C3    = 4'd2;
    localparam [3:0] STREAM_STATUS_C2    = 4'd3;
    localparam [3:0] STREAM_STATUS_C1    = 4'd4;
    localparam [3:0] STREAM_STATUS_C0    = 4'd5;
    localparam [3:0] STREAM_DUMP_DIM_HI  = 4'd6;
    localparam [3:0] STREAM_DUMP_DIM_LO  = 4'd7;
    localparam [3:0] STREAM_DUMP_SETADDR = 4'd8;
    localparam [3:0] STREAM_DUMP_WAIT0   = 4'd9;
    localparam [3:0] STREAM_DUMP_WAIT1   = 4'd10;
    localparam [3:0] STREAM_DUMP_B3      = 4'd11;
    localparam [3:0] STREAM_DUMP_B2      = 4'd12;
    localparam [3:0] STREAM_DUMP_B1      = 4'd13;
    localparam [3:0] STREAM_DUMP_B0      = 4'd14;

    wire clk;
    wire rst_n;
    assign clk   = CLK100MHZ;
    reset_sync u_reset_sync (
        .clk    (clk),
        .arst_n (CPU_RESETN),
        .rst_n  (rst_n)
    );

    wire [7:0] rx_data;
    wire       rx_valid;
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;
    reg  [7:0] tx_req_data;
    reg        tx_req_valid;

    reg                      core_start;
    reg  [DIM_W-1:0]         requested_matrix_dim;
    wire                     core_busy;
    wire                     core_done;
    wire [31:0]              core_cycle_count;
    wire                     core_run_active;
    wire [RUN_W-1:0]         core_run_count;
    wire                     core_clear_c_active;
    wire                     core_load_active;
    wire                     core_writeback_active;
    wire                     core_clear_acc;
    wire                     core_buf_sel;
    wire                     core_load_buf_sel;
    wire [15:0]              core_load_count;
    wire [15:0]              core_wb_count;
    wire [15:0]              core_clear_c_addr;
    wire                     core_overflow_flag;
    wire [DIM_W-1:0]         active_matrix_dim;
    wire [ADDRW:0]           active_matrix_elems;

    reg                      a_wr_en;
    reg                      b_wr_en;
    reg  [ADDRW-1:0]         a_wr_addr;
    reg  [ADDRW-1:0]         b_wr_addr;
    reg  signed [DW-1:0]     a_wr_data;
    reg  signed [DW-1:0]     b_wr_data;
    reg  [ADDRW-1:0]         c_host_rd_addr;
    wire signed [ACCW-1:0]   c_host_rd_data;

    reg  [2:0]               rx_state;
    reg  [7:0]               cmd_byte;
    reg  [7:0]               addr_hi_byte;
    reg  [7:0]               addr_lo_byte;
    reg  [7:0]               data_byte;
    reg                      pending_cmd_valid;
    reg  [7:0]               pending_cmd_byte;
    reg  [7:0]               pending_addr_hi_byte;
    reg  [7:0]               pending_addr_lo_byte;
    reg  [7:0]               pending_data_byte;

    reg                      done_latched;
    reg  [3:0]               stream_state;
    reg  [ADDRW-1:0]         dump_index;
    reg  signed [31:0]       dump_word;
    reg  [HEARTBEAT_W-1:0]   heartbeat_ctr;
    reg  [LED_HOLD_W-1:0]    busy_led_hold;
    reg  [LED_HOLD_W-1:0]    rx_led_hold;
    reg  [LED_HOLD_W-1:0]    tx_led_hold;
    reg  [LED_HOLD_W-1:0]    clear_c_led_hold;
    reg  [LED_HOLD_W-1:0]    load_led_hold;
    reg  [LED_HOLD_W-1:0]    clear_acc_led_hold;
    reg  [LED_HOLD_W-1:0]    run_led_hold;
    reg  [LED_HOLD_W-1:0]    writeback_led_hold;
    reg  [3:0]               led_progress;
    reg  [LED_PROGRESS_W-1:0] led_progress_div;
    reg                      led_buf_sel;
    reg                      led_load_buf_sel;

    wire [15:0] pending_word;
    wire [ADDRW:0] dump_last_index;
    wire [15:0] active_dim_u16;
    wire        led_heartbeat;
    wire        led_busy_seen;
    wire        led_rx_seen;
    wire        led_tx_seen;
    wire        led_clear_c_seen;
    wire        led_load_seen;
    wire        led_clear_acc_seen;
    wire        led_run_seen;
    wire        led_writeback_seen;

    assign pending_word = {pending_addr_hi_byte, pending_addr_lo_byte};
    assign active_matrix_elems = active_matrix_dim * active_matrix_dim;
    assign dump_last_index = active_matrix_elems - 1'b1;
    assign active_dim_u16 = active_matrix_dim;
    assign led_heartbeat = heartbeat_ctr[HEARTBEAT_W-1];
    assign led_busy_seen = (busy_led_hold != 0);
    assign led_rx_seen = (rx_led_hold != 0);
    assign led_tx_seen = (tx_led_hold != 0);
    assign led_clear_c_seen = (clear_c_led_hold != 0);
    assign led_load_seen = (load_led_hold != 0);
    assign led_clear_acc_seen = (clear_acc_led_hold != 0);
    assign led_run_seen = (run_led_hold != 0);
    assign led_writeback_seen = (writeback_led_hold != 0);

     uart_rx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (UART_BAUD)
    ) u_uart_rx (
        .clk     (clk),
        .rst_n   (rst_n),
        .rx_i    (UART_TXD_IN),
        .data_o  (rx_data),
        .valid_o (rx_valid)
    );

    uart_tx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (UART_BAUD)
    ) u_uart_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .data_i  (tx_data),
        .start_i (tx_start),
        .tx_o    (UART_RXD_OUT),
        .busy_o  (tx_busy)
    );

    tpu_top #(
        .N       (N),
        .ARRAY_N (ARRAY_N),
        .DW      (DW),
        .DIM_W   (DIM_W),
        .ACCW    (ACCW),
        .ADDRW   (ADDRW),
        .RUN_W   (RUN_W)
    ) u_tpu_top (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (core_start),
        .matrix_dim       (requested_matrix_dim),
        .busy             (core_busy),
        .done             (core_done),
        .cycle_count      (core_cycle_count),
        .debug_run_active (core_run_active),
        .debug_run_count  (core_run_count),
        .debug_clear_c_active(core_clear_c_active),
        .debug_load_active(core_load_active),
        .debug_writeback_active(core_writeback_active),
        .debug_clear_acc  (core_clear_acc),
        .debug_buf_sel    (core_buf_sel),
        .debug_load_buf_sel(core_load_buf_sel),
        .debug_load_count (core_load_count),
        .debug_wb_count   (core_wb_count),
        .debug_clear_c_addr(core_clear_c_addr),
        .overflow_flag    (core_overflow_flag),
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

    assign LED[3:0]   = led_progress;
    assign LED[4]     = led_load_buf_sel;
    assign LED[5]     = led_buf_sel;
    assign LED[6]     = led_writeback_seen;
    assign LED[7]     = led_run_seen;
    assign LED[8]     = led_clear_acc_seen;
    assign LED[9]     = led_load_seen;
    assign LED[10]    = led_clear_c_seen;
    assign LED[11]    = led_tx_seen;
    assign LED[12]    = led_rx_seen;
    assign LED[13]    = led_busy_seen;
    assign LED[14]    = done_latched;
    assign LED[15]    = led_heartbeat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state              <= RX_WAIT_START;
            cmd_byte              <= 8'd0;
            addr_hi_byte          <= 8'd0;
            addr_lo_byte          <= 8'd0;
            data_byte             <= 8'd0;
            pending_cmd_valid     <= 1'b0;
            pending_cmd_byte      <= 8'd0;
            pending_addr_hi_byte  <= 8'd0;
            pending_addr_lo_byte  <= 8'd0;
            pending_data_byte     <= 8'd0;
            core_start            <= 1'b0;
            requested_matrix_dim  <= '0;
            a_wr_en               <= 1'b0;
            b_wr_en               <= 1'b0;
            a_wr_addr             <= '0;
            b_wr_addr             <= '0;
            a_wr_data             <= '0;
            b_wr_data             <= '0;
            c_host_rd_addr        <= '0;
            tx_data               <= 8'd0;
            tx_start              <= 1'b0;
            tx_req_data           <= 8'd0;
            tx_req_valid          <= 1'b0;
            done_latched          <= 1'b0;
            stream_state          <= STREAM_IDLE;
            dump_index            <= '0;
            dump_word             <= 32'sd0;
            heartbeat_ctr         <= '0;
            busy_led_hold         <= '0;
            rx_led_hold           <= '0;
            tx_led_hold           <= '0;
            clear_c_led_hold      <= '0;
            load_led_hold         <= '0;
            clear_acc_led_hold    <= '0;
            run_led_hold          <= '0;
            writeback_led_hold    <= '0;
            led_progress          <= 4'b0000;
            led_progress_div      <= '0;
            led_buf_sel           <= 1'b0;
            led_load_buf_sel      <= 1'b0;
        end else begin
            core_start <= 1'b0;
            a_wr_en    <= 1'b0;
            b_wr_en    <= 1'b0;
            tx_start   <= 1'b0;
            heartbeat_ctr <= heartbeat_ctr + 1'b1;
            if (led_progress_div == (LED_PROGRESS_STEP_CYCLES - 1)) begin
                led_progress_div <= '0;
            end else begin
                led_progress_div <= led_progress_div + 1'b1;
            end

            if (busy_led_hold != 0) begin
                busy_led_hold <= busy_led_hold - 1'b1;
            end
            if (rx_led_hold != 0) begin
                rx_led_hold <= rx_led_hold - 1'b1;
            end
            if (tx_led_hold != 0) begin
                tx_led_hold <= tx_led_hold - 1'b1;
            end
            if (clear_c_led_hold != 0) begin
                clear_c_led_hold <= clear_c_led_hold - 1'b1;
            end
            if (load_led_hold != 0) begin
                load_led_hold <= load_led_hold - 1'b1;
            end
            if (clear_acc_led_hold != 0) begin
                clear_acc_led_hold <= clear_acc_led_hold - 1'b1;
            end
            if (run_led_hold != 0) begin
                run_led_hold <= run_led_hold - 1'b1;
            end
            if (writeback_led_hold != 0) begin
                writeback_led_hold <= writeback_led_hold - 1'b1;
            end

            if (core_busy) begin
                busy_led_hold <= ACTIVITY_LED_HOLD_CYCLES - 1;
            end

            if (tx_req_valid && !tx_busy) begin
                tx_data      <= tx_req_data;
                tx_start     <= 1'b1;
                tx_req_valid <= 1'b0;
                tx_led_hold  <= ACTIVITY_LED_HOLD_CYCLES - 1;
            end

            if (core_clear_c_active) begin
                clear_c_led_hold <= STAGE_LED_HOLD_CYCLES - 1;
                if (led_progress_div == '0) begin
                    led_progress <= 4'b0001 << low2(core_clear_c_addr);
                end
            end

            if (core_load_active) begin
                load_led_hold    <= STAGE_LED_HOLD_CYCLES - 1;
                led_load_buf_sel <= core_load_buf_sel;
                if (led_progress_div == '0) begin
                    led_progress <= 4'b0001 << low2(core_load_count);
                end
            end

            if (core_done) begin
                done_latched <= 1'b1;
                led_progress <= active_matrix_dim;
            end

            if (core_clear_acc) begin
                clear_acc_led_hold <= STAGE_LED_HOLD_CYCLES - 1;
                led_progress       <= 4'b1111;
            end

            if (core_run_active) begin
                run_led_hold <= STAGE_LED_HOLD_CYCLES - 1;
                led_buf_sel  <= core_buf_sel;
                if (led_progress_div == '0) begin
                    led_progress <= 4'b0001 << low2(core_run_count);
                end
            end

            if (core_writeback_active) begin
                writeback_led_hold <= STAGE_LED_HOLD_CYCLES - 1;
                if (led_progress_div == '0) begin
                    led_progress <= 4'b0001 << low2(core_wb_count);
                end
            end

            if (rx_valid) begin
                rx_led_hold <= ACTIVITY_LED_HOLD_CYCLES - 1;
                case (rx_state)
                    RX_WAIT_START: begin
                        if (rx_data == FRAME_START) begin
                            rx_state <= RX_WAIT_CMD;
                        end
                    end

                    RX_WAIT_CMD: begin
                        cmd_byte  <= rx_data;
                        rx_state  <= RX_WAIT_AHI;
                    end

                    RX_WAIT_AHI: begin
                        addr_hi_byte <= rx_data;
                        rx_state     <= RX_WAIT_ALO;
                    end

                    RX_WAIT_ALO: begin
                        addr_lo_byte <= rx_data;
                        rx_state     <= RX_WAIT_DATA;
                    end

                    RX_WAIT_DATA: begin
                        data_byte <= rx_data;
                        rx_state  <= RX_WAIT_START;

                        if (!pending_cmd_valid) begin
                            pending_cmd_valid    <= 1'b1;
                            pending_cmd_byte     <= cmd_byte;
                            pending_addr_hi_byte <= addr_hi_byte;
                            pending_addr_lo_byte <= addr_lo_byte;
                            pending_data_byte    <= rx_data;
                        end
                    end

                    default: begin
                        rx_state <= RX_WAIT_START;
                    end
                endcase
            end

            if (pending_cmd_valid && (stream_state == STREAM_IDLE) && !tx_busy && !tx_req_valid) begin
                pending_cmd_valid <= 1'b0;

                case (pending_cmd_byte)
                    CMD_WRITE_A: begin
                        if (!core_busy && (pending_word < MATRIX_ELEMS)) begin
                            a_wr_en      <= 1'b1;
                            a_wr_addr    <= pending_word[ADDRW-1:0];
                            a_wr_data    <= $signed(pending_data_byte);
                            done_latched <= 1'b0;
                            tx_req_data  <= RESP_ACK;
                            tx_req_valid <= 1'b1;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_WRITE_B: begin
                        if (!core_busy && (pending_word < MATRIX_ELEMS)) begin
                            b_wr_en      <= 1'b1;
                            b_wr_addr    <= pending_word[ADDRW-1:0];
                            b_wr_data    <= $signed(pending_data_byte);
                            done_latched <= 1'b0;
                            tx_req_data  <= RESP_ACK;
                            tx_req_valid <= 1'b1;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_START: begin
                        if (!core_busy && (pending_word >= 1) && (pending_word <= N)) begin
                            core_start   <= 1'b1;
                            requested_matrix_dim <= pending_word[DIM_W-1:0];
                            done_latched <= 1'b0;
                            tx_req_data  <= RESP_ACK;
                            tx_req_valid <= 1'b1;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_STATUS: begin
                        tx_req_data  <= RESP_STATUS;
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_STATUS_FLAGS;
                    end

                    CMD_DUMP_C: begin
                        if (!core_busy && (active_matrix_dim != 0)) begin
                            tx_req_data  <= RESP_DUMP;
                            tx_req_valid <= 1'b1;
                            dump_index   <= '0;
                            stream_state <= STREAM_DUMP_DIM_HI;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    default: begin
                        tx_req_data  <= RESP_ERROR;
                        tx_req_valid <= 1'b1;
                    end
                endcase
            end else if (!tx_busy && !tx_req_valid) begin
                case (stream_state)
                    STREAM_IDLE: begin
                    end

                    STREAM_STATUS_FLAGS: begin
                        tx_req_data  <= {5'b0, core_overflow_flag, done_latched, core_busy};
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_STATUS_C3;
                    end

                    STREAM_STATUS_C3: begin
                        tx_req_data  <= core_cycle_count[31:24];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_STATUS_C2;
                    end

                    STREAM_STATUS_C2: begin
                        tx_req_data  <= core_cycle_count[23:16];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_STATUS_C1;
                    end

                    STREAM_STATUS_C1: begin
                        tx_req_data  <= core_cycle_count[15:8];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_STATUS_C0;
                    end

                    STREAM_STATUS_C0: begin
                        tx_req_data  <= core_cycle_count[7:0];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_IDLE;
                    end

                    STREAM_DUMP_DIM_HI: begin
                        tx_req_data  <= active_dim_u16[15:8];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_DUMP_DIM_LO;
                    end

                    STREAM_DUMP_DIM_LO: begin
                        tx_req_data  <= active_dim_u16[7:0];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_DUMP_SETADDR;
                    end

                    STREAM_DUMP_SETADDR: begin
                        c_host_rd_addr <= dump_index;
                        stream_state   <= STREAM_DUMP_WAIT0;
                    end

                    STREAM_DUMP_WAIT0: begin
                        stream_state <= STREAM_DUMP_WAIT1;
                    end

                    STREAM_DUMP_WAIT1: begin
                        dump_word    <= $signed(c_host_rd_data);
                        stream_state <= STREAM_DUMP_B3;
                    end

                    STREAM_DUMP_B3: begin
                        tx_req_data  <= dump_word[31:24];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_DUMP_B2;
                    end

                    STREAM_DUMP_B2: begin
                        tx_req_data  <= dump_word[23:16];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_DUMP_B1;
                    end

                    STREAM_DUMP_B1: begin
                        tx_req_data  <= dump_word[15:8];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_DUMP_B0;
                    end

                    STREAM_DUMP_B0: begin
                        tx_req_data  <= dump_word[7:0];
                        tx_req_valid <= 1'b1;
                        if (dump_index == dump_last_index[ADDRW-1:0]) begin
                            stream_state <= STREAM_IDLE;
                        end else begin
                            dump_index   <= dump_index + 1'b1;
                            stream_state <= STREAM_DUMP_SETADDR;
                        end
                    end

                    default: begin
                        stream_state <= STREAM_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
