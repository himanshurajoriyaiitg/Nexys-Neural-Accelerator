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
    output wire [15:0] LED,
    output wire [6:0]  SEG,
    output wire        DP,
    output wire [7:0]  AN
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
    localparam integer SYS_CLK_DIVIDE            = 4;
    localparam integer SYS_CLK_HZ                =
        (CLK_HZ / SYS_CLK_DIVIDE) > 0 ? (CLK_HZ / SYS_CLK_DIVIDE) : 1;
    localparam integer HEARTBEAT_W               = 27;
    localparam integer ACTIVITY_LED_HOLD_CYCLES = SYS_CLK_HZ;
    localparam integer STAGE_LED_HOLD_CYCLES    = SYS_CLK_HZ * 2;
    localparam integer STREAM_PACKET_MAX_BYTES  = 52;
    localparam integer LED_PROGRESS_STEP_CYCLES =
        (SYS_CLK_HZ / 4) > 0 ? (SYS_CLK_HZ / 4) : 1;
    localparam integer LED_HOLD_CYCLES_MAX      =
        (STAGE_LED_HOLD_CYCLES > ACTIVITY_LED_HOLD_CYCLES) ?
        STAGE_LED_HOLD_CYCLES : ACTIVITY_LED_HOLD_CYCLES;
    localparam integer LED_HOLD_W = clog2_safe(LED_HOLD_CYCLES_MAX + 1);
    localparam integer LED_PROGRESS_W = clog2_safe(LED_PROGRESS_STEP_CYCLES);
    localparam integer STREAM_PACKET_W = clog2_safe(STREAM_PACKET_MAX_BYTES + 1);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_CLEAR_C   = 3'd1;
    localparam [2:0] ST_PRELOAD   = 3'd2;
    localparam [2:0] ST_CLEAR_ACC = 3'd3;
    localparam [2:0] ST_RUN       = 3'd4;
    localparam [2:0] ST_WAIT_LOAD = 3'd5;
    localparam [2:0] ST_WRITEBACK = 3'd6;
    localparam [2:0] ST_DONE      = 3'd7;

    localparam [7:0] FRAME_START = 8'hA5;
    localparam [7:0] CMD_WRITE_A = 8'h01;
    localparam [7:0] CMD_WRITE_B = 8'h02;
    localparam [7:0] CMD_START   = 8'h03;
    localparam [7:0] CMD_STATUS  = 8'h04;
    localparam [7:0] CMD_DUMP_C  = 8'h05;
    localparam [7:0] CMD_PROFILE = 8'h06;
    localparam [7:0] CMD_WRITE_BIAS = 8'h07;
    localparam [7:0] CMD_SET_LED_CODE = 8'h20;
    localparam [7:0] CMD_WRITE_A_BURST = 8'h10;
    localparam [7:0] CMD_WRITE_B_BURST = 8'h11;
    localparam [7:0] CMD_ZERO_A_RUN    = 8'h12;
    localparam [7:0] CMD_ZERO_B_RUN    = 8'h13;
    localparam [7:0] CMD_WRITE_SNN_IMG = 8'h21;
    localparam [7:0] CMD_START_SNN     = 8'h22;
    localparam [7:0] CMD_STATUS_SNN    = 8'h23;

    localparam [7:0] RESP_ACK    = 8'h5A;
    localparam [7:0] RESP_ERROR  = 8'hE0;
    localparam [7:0] RESP_STATUS = 8'hA6;
    localparam [7:0] RESP_DUMP   = 8'hA7;
    localparam [7:0] RESP_PROFILE = 8'hA8;

    localparam [2:0] RX_WAIT_START = 3'd0;
    localparam [2:0] RX_WAIT_CMD   = 3'd1;
    localparam [2:0] RX_WAIT_AHI   = 3'd2;
    localparam [2:0] RX_WAIT_ALO   = 3'd3;
    localparam [2:0] RX_WAIT_DATA  = 3'd4;
    localparam [2:0] RX_BURST_DATA = 3'd5;

    localparam [3:0] STREAM_IDLE         = 4'd0;
    localparam [3:0] STREAM_PACKET       = 4'd1;
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
    wire clk_ready;
`ifdef SYNTHESIS
    wire clk_mmcm;
    wire clk_fb_mmcm;
    wire clk_fb;
    wire mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKIN1_PERIOD    (10.0),
        .CLKFBOUT_MULT_F  (10.0),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (40.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE    (0.0),
        .STARTUP_WAIT     ("FALSE")
    ) u_sys_clk_mmcm (
        .CLKIN1   (CLK100MHZ),
        .CLKFBIN  (clk_fb),
        .RST      (1'b0),
        .PWRDWN   (1'b0),
        .CLKFBOUT (clk_fb_mmcm),
        .CLKOUT0  (clk_mmcm),
        .LOCKED   (mmcm_locked)
    );

    BUFG u_clkfb_buf (
        .I (clk_fb_mmcm),
        .O (clk_fb)
    );

    BUFG u_sys_clk_buf (
        .I (clk_mmcm),
        .O (clk)
    );

    assign clk_ready = mmcm_locked;
`else
    reg [1:0] sim_clk_div = 2'b00;
    always @(posedge CLK100MHZ) begin
        sim_clk_div <= sim_clk_div + 2'b01;
    end
    assign clk = sim_clk_div[1];
    assign clk_ready = 1'b1;
`endif

    reset_sync u_reset_sync (
        .clk    (clk),
        .arst_n (CPU_RESETN & clk_ready),
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
    reg  [1:0]               core_act_mode;
    reg                      core_enable_bias;
    reg                      core_enable_pool;
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
    wire [2:0]               core_debug_state;
    wire                     core_buf_sel;
    wire                     core_load_buf_sel;
    wire [15:0]              core_load_count;
    wire [15:0]              core_wb_count;
    wire [15:0]              core_clear_c_addr;
    wire                     core_overflow_flag;
    wire [DIM_W-1:0]         active_matrix_dim;
    wire [ADDRW:0]           active_matrix_elems;
    wire [31:0]              core_profile_clear_c_cycles;
    wire [31:0]              core_profile_preload_cycles;
    wire [31:0]              core_profile_clear_acc_cycles;
    wire [31:0]              core_profile_run_cycles;
    wire [31:0]              core_profile_wait_load_cycles;
    wire [31:0]              core_profile_writeback_cycles;
    wire [31:0]              core_profile_load_overlap_cycles;
    wire [31:0]              core_profile_buffer_swap_count;
    wire [31:0]              core_profile_output_tile_count;
    wire [31:0]              core_profile_k_pass_count;
    wire [31:0]              core_profile_result_signature;

    reg                      a_wr_en;
    reg                      b_wr_en;
    reg                      bias_wr_en;
    reg  [ADDRW-1:0]         a_wr_addr;
    reg  [ADDRW-1:0]         b_wr_addr;
    reg  [DIM_W-1:0]         bias_wr_addr;
    reg  signed [DW-1:0]     a_wr_data;
    reg  signed [DW-1:0]     b_wr_data;
    reg  signed [DW-1:0]     bias_wr_data;
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
    reg  [7:0]               stream_packet [0:STREAM_PACKET_MAX_BYTES-1];
    reg  [STREAM_PACKET_W-1:0] stream_packet_len;
    reg  [STREAM_PACKET_W-1:0] stream_packet_index;
    reg  [ADDRW-1:0]         dump_index;
    reg  signed [31:0]       dump_word;
    reg                      burst_active;
    reg                      burst_is_b;
    reg  [ADDRW-1:0]         burst_addr;
    reg  [7:0]               burst_remaining;
    reg                      zero_run_active;
    reg                      zero_run_is_b;
    reg  [ADDRW-1:0]         zero_run_addr;
    reg  [7:0]               zero_run_remaining;
    reg                      pending_burst_seen;
    reg                      pending_zero_seen;
    reg                      run_burst_seen;
    reg                      run_zero_seen;
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
    reg  [15:0]              led_out;
    reg  [7:0]               result_led_code;
    reg                      result_led_valid;

    wire [15:0] pending_word;
    wire [DIM_W-1:0] output_matrix_dim;
    wire [ADDRW:0] output_matrix_elems;
    wire [ADDRW:0] dump_last_index;
    wire [15:0] active_dim_u16;
    wire [15:0] output_dim_u16;
    wire        led_heartbeat;
    wire [3:0]  led_mode;
    wire [7:0]  status_flags;
    wire        led_busy_seen;
    wire        led_rx_seen;
    wire        led_tx_seen;
    wire        led_clear_c_seen;
    wire        led_load_seen;
    wire        led_clear_acc_seen;
    wire        led_run_seen;
    wire        led_writeback_seen;
    wire        command_engine_busy;
    wire        profile_wait_seen;
    wire        profile_overlap_seen;
    wire        profile_swap_seen;

    assign pending_word = {pending_addr_hi_byte, pending_addr_lo_byte};
    assign active_matrix_elems = active_matrix_dim * active_matrix_dim;
    assign output_matrix_dim = core_enable_pool ? (active_matrix_dim >> 1) : active_matrix_dim;
    assign output_matrix_elems = output_matrix_dim * output_matrix_dim;
    assign dump_last_index = output_matrix_elems - 1'b1;
    assign active_dim_u16 = active_matrix_dim;
    assign output_dim_u16 = output_matrix_dim;
    assign led_heartbeat = heartbeat_ctr[HEARTBEAT_W-1];
    assign led_mode = {core_enable_pool, core_enable_bias, core_act_mode};
    assign status_flags = {5'b0, core_overflow_flag, done_latched, core_busy};
    assign led_busy_seen = (busy_led_hold != 0);
    assign led_rx_seen = (rx_led_hold != 0);
    assign led_tx_seen = (tx_led_hold != 0);
    assign led_clear_c_seen = (clear_c_led_hold != 0);
    assign led_load_seen = (load_led_hold != 0);
    assign led_clear_acc_seen = (clear_acc_led_hold != 0);
    assign led_run_seen = (run_led_hold != 0);
    assign led_writeback_seen = (writeback_led_hold != 0);
    assign command_engine_busy = burst_active || zero_run_active;
    assign profile_wait_seen = (core_profile_wait_load_cycles != 0);
    assign profile_overlap_seen = (core_profile_load_overlap_cycles != 0);
    assign profile_swap_seen = (core_profile_buffer_swap_count != 0);

     uart_rx #(
        .CLK_HZ (SYS_CLK_HZ),
        .BAUD   (UART_BAUD)
    ) u_uart_rx (
        .clk     (clk),
        .rst_n   (rst_n),
        .rx_i    (UART_TXD_IN),
        .data_o  (rx_data),
        .valid_o (rx_valid)
    );

    uart_tx #(
        .CLK_HZ (SYS_CLK_HZ),
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
        .act_mode         (core_act_mode),
        .enable_bias      (core_enable_bias),
        .enable_pool      (core_enable_pool),
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
        .debug_state      (core_debug_state),
        .debug_buf_sel    (core_buf_sel),
        .debug_load_buf_sel(core_load_buf_sel),
        .debug_load_count (core_load_count),
        .debug_wb_count   (core_wb_count),
        .debug_clear_c_addr(core_clear_c_addr),
        .overflow_flag    (core_overflow_flag),
        .active_matrix_dim(active_matrix_dim),
        .profile_clear_c_cycles(core_profile_clear_c_cycles),
        .profile_preload_cycles(core_profile_preload_cycles),
        .profile_clear_acc_cycles(core_profile_clear_acc_cycles),
        .profile_run_cycles(core_profile_run_cycles),
        .profile_wait_load_cycles(core_profile_wait_load_cycles),
        .profile_writeback_cycles(core_profile_writeback_cycles),
        .profile_load_overlap_cycles(core_profile_load_overlap_cycles),
        .profile_buffer_swap_count(core_profile_buffer_swap_count),
        .profile_output_tile_count(core_profile_output_tile_count),
        .profile_k_pass_count(core_profile_k_pass_count),
        .profile_result_signature(core_profile_result_signature),
        .a_wr_en          (a_wr_en),
        .b_wr_en          (b_wr_en),
        .bias_wr_en       (bias_wr_en),
        .a_wr_addr        (a_wr_addr),
        .b_wr_addr        (b_wr_addr),
        .bias_wr_addr     (bias_wr_addr),
        .a_wr_data        (a_wr_data),
        .b_wr_data        (b_wr_data),
        .bias_wr_data     (bias_wr_data),
        .c_host_rd_addr   (c_host_rd_addr),
        .c_host_rd_data   (c_host_rd_data)
    );

    assign LED = led_out;

    reg [7:0] snn_img_data [0:255];
    reg snn_start_trigger;
    reg snn_done_latched;
    reg [3:0] snn_prediction_latched;
    wire snn_done;
    wire [3:0] snn_prediction;
    
    snn_core u_snn_core (
        .clk(clk),
        .rst_n(rst_n),
        .start(snn_start_trigger),
        .img_data(snn_img_data),
        .done(snn_done),
        .prediction(snn_prediction)
    );

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
            core_act_mode         <= 2'b00;
            core_enable_bias      <= 1'b0;
            core_enable_pool      <= 1'b0;
            requested_matrix_dim  <= '0;
            a_wr_en               <= 1'b0;
            b_wr_en               <= 1'b0;
            bias_wr_en            <= 1'b0;
            a_wr_addr             <= '0;
            b_wr_addr             <= '0;
            bias_wr_addr          <= '0;
            a_wr_data             <= '0;
            b_wr_data             <= '0;
            bias_wr_data          <= '0;
            c_host_rd_addr        <= '0;
            tx_data               <= 8'd0;
            tx_start              <= 1'b0;
            tx_req_data           <= 8'd0;
            tx_req_valid          <= 1'b0;
            done_latched          <= 1'b0;
            stream_state          <= STREAM_IDLE;
            stream_packet_len     <= '0;
            stream_packet_index   <= '0;
            dump_index            <= '0;
            dump_word             <= 32'sd0;
            burst_active          <= 1'b0;
            burst_is_b            <= 1'b0;
            burst_addr            <= '0;
            burst_remaining       <= 8'd0;
            zero_run_active       <= 1'b0;
            zero_run_is_b         <= 1'b0;
            zero_run_addr         <= '0;
            zero_run_remaining    <= 8'd0;
            pending_burst_seen    <= 1'b0;
            pending_zero_seen     <= 1'b0;
            run_burst_seen        <= 1'b0;
            run_zero_seen         <= 1'b0;
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
            result_led_code       <= 8'd0;
            result_led_valid      <= 1'b0;
            snn_start_trigger     <= 1'b0;
            snn_done_latched      <= 1'b0;
            snn_prediction_latched <= 4'd0;
            for (int i = 0; i < 256; i++) snn_img_data[i] <= 8'd0;
        end else begin
            core_start <= 1'b0;
            snn_start_trigger <= 1'b0;
            a_wr_en    <= 1'b0;
            b_wr_en    <= 1'b0;
            bias_wr_en <= 1'b0;
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

            if (zero_run_active) begin
                done_latched <= 1'b0;
                if (zero_run_is_b) begin
                    b_wr_en   <= 1'b1;
                    b_wr_addr <= zero_run_addr;
                    b_wr_data <= '0;
                end else begin
                    a_wr_en   <= 1'b1;
                    a_wr_addr <= zero_run_addr;
                    a_wr_data <= '0;
                end

                if (zero_run_remaining == 8'd1) begin
                    zero_run_active    <= 1'b0;
                    zero_run_remaining <= 8'd0;
                    tx_req_data        <= RESP_ACK;
                    tx_req_valid       <= 1'b1;
                end else begin
                    zero_run_addr      <= zero_run_addr + 1'b1;
                    zero_run_remaining <= zero_run_remaining - 1'b1;
                end
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
                led_progress <= active_matrix_dim[3:0];
            end

            if (snn_done) begin
                snn_done_latched       <= 1'b1;
                snn_prediction_latched <= snn_prediction;
                done_latched           <= 1'b1;
                result_led_code        <= {4'd0, snn_prediction};
                result_led_valid       <= 1'b1;
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
                        cmd_byte <= rx_data;
                        rx_state <= RX_WAIT_AHI;
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

                    RX_BURST_DATA: begin
                        if (burst_active && !core_busy && !zero_run_active) begin
                            done_latched <= 1'b0;

                            if (burst_is_b) begin
                                b_wr_en   <= 1'b1;
                                b_wr_addr <= burst_addr;
                                b_wr_data <= $signed(rx_data);
                            end else begin
                                a_wr_en   <= 1'b1;
                                a_wr_addr <= burst_addr;
                                a_wr_data <= $signed(rx_data);
                            end

                            if (burst_remaining == 8'd1) begin
                                burst_active    <= 1'b0;
                                burst_remaining <= 8'd0;
                                rx_state        <= RX_WAIT_START;
                                tx_req_data     <= RESP_ACK;
                                tx_req_valid    <= 1'b1;
                            end else begin
                                burst_addr      <= burst_addr + 1'b1;
                                burst_remaining <= burst_remaining - 1'b1;
                            end
                        end else begin
                            burst_active    <= 1'b0;
                            burst_remaining <= 8'd0;
                            rx_state        <= RX_WAIT_START;
                            tx_req_data     <= RESP_ERROR;
                            tx_req_valid    <= 1'b1;
                        end
                    end

                    default: begin
                        rx_state <= RX_WAIT_START;
                    end
                endcase
            end

            if (pending_cmd_valid &&
                (stream_state == STREAM_IDLE) &&
                !tx_busy &&
                !tx_req_valid &&
                !command_engine_busy &&
                (rx_state != RX_BURST_DATA)) begin
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
                        if (!core_busy && (pending_word[DIM_W-1:0] >= 1) && (pending_word[DIM_W-1:0] <= N)) begin
                            core_start           <= 1'b1;
                            requested_matrix_dim <= pending_word[DIM_W-1:0];
                            core_enable_pool     <= pending_word[11];
                            core_enable_bias     <= pending_word[12];
                            core_act_mode        <= pending_word[14:13];
                            done_latched         <= 1'b0;
                            run_burst_seen       <= pending_burst_seen;
                            run_zero_seen        <= pending_zero_seen;
                            pending_burst_seen   <= 1'b0;
                            pending_zero_seen    <= 1'b0;
                            tx_req_data          <= RESP_ACK;
                            tx_req_valid         <= 1'b1;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_STATUS: begin
                        stream_packet[0]  <= RESP_STATUS;
                        stream_packet[1]  <= status_flags;
                        stream_packet[2]  <= core_cycle_count[31:24];
                        stream_packet[3]  <= core_cycle_count[23:16];
                        stream_packet[4]  <= core_cycle_count[15:8];
                        stream_packet[5]  <= core_cycle_count[7:0];
                        stream_packet_len <= 6;
                        stream_packet_index <= '0;
                        stream_state      <= STREAM_PACKET;
                    end

                    CMD_WRITE_BIAS: begin
                        if (!core_busy && (pending_word[DIM_W-1:0] < N)) begin
                            bias_wr_en   <= 1'b1;
                            bias_wr_addr <= pending_word[DIM_W-1:0];
                            bias_wr_data <= $signed(pending_data_byte);
                            done_latched <= 1'b0;
                            tx_req_data  <= RESP_ACK;
                            tx_req_valid <= 1'b1;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_SET_LED_CODE: begin
                        result_led_code <= pending_data_byte;
                        result_led_valid <= 1'b1;
                        tx_req_data <= RESP_ACK;
                        tx_req_valid <= 1'b1;
                    end

                    CMD_DUMP_C: begin
                        if (!core_busy && (output_matrix_dim != 0)) begin
                            tx_req_data  <= RESP_DUMP;
                            tx_req_valid <= 1'b1;
                            dump_index   <= '0;
                            stream_state <= STREAM_DUMP_DIM_HI;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_PROFILE: begin
                        stream_packet[0]   <= RESP_PROFILE;
                        stream_packet[1]   <= status_flags;
                        stream_packet[2]   <= active_dim_u16[15:8];
                        stream_packet[3]   <= active_dim_u16[7:0];
                        stream_packet[4]   <= core_cycle_count[31:24];
                        stream_packet[5]   <= core_cycle_count[23:16];
                        stream_packet[6]   <= core_cycle_count[15:8];
                        stream_packet[7]   <= core_cycle_count[7:0];
                        stream_packet[8]   <= core_profile_clear_c_cycles[31:24];
                        stream_packet[9]   <= core_profile_clear_c_cycles[23:16];
                        stream_packet[10]  <= core_profile_clear_c_cycles[15:8];
                        stream_packet[11]  <= core_profile_clear_c_cycles[7:0];
                        stream_packet[12]  <= core_profile_preload_cycles[31:24];
                        stream_packet[13]  <= core_profile_preload_cycles[23:16];
                        stream_packet[14]  <= core_profile_preload_cycles[15:8];
                        stream_packet[15]  <= core_profile_preload_cycles[7:0];
                        stream_packet[16]  <= core_profile_clear_acc_cycles[31:24];
                        stream_packet[17]  <= core_profile_clear_acc_cycles[23:16];
                        stream_packet[18]  <= core_profile_clear_acc_cycles[15:8];
                        stream_packet[19]  <= core_profile_clear_acc_cycles[7:0];
                        stream_packet[20]  <= core_profile_run_cycles[31:24];
                        stream_packet[21]  <= core_profile_run_cycles[23:16];
                        stream_packet[22]  <= core_profile_run_cycles[15:8];
                        stream_packet[23]  <= core_profile_run_cycles[7:0];
                        stream_packet[24]  <= core_profile_wait_load_cycles[31:24];
                        stream_packet[25]  <= core_profile_wait_load_cycles[23:16];
                        stream_packet[26]  <= core_profile_wait_load_cycles[15:8];
                        stream_packet[27]  <= core_profile_wait_load_cycles[7:0];
                        stream_packet[28]  <= core_profile_writeback_cycles[31:24];
                        stream_packet[29]  <= core_profile_writeback_cycles[23:16];
                        stream_packet[30]  <= core_profile_writeback_cycles[15:8];
                        stream_packet[31]  <= core_profile_writeback_cycles[7:0];
                        stream_packet[32]  <= core_profile_load_overlap_cycles[31:24];
                        stream_packet[33]  <= core_profile_load_overlap_cycles[23:16];
                        stream_packet[34]  <= core_profile_load_overlap_cycles[15:8];
                        stream_packet[35]  <= core_profile_load_overlap_cycles[7:0];
                        stream_packet[36]  <= core_profile_buffer_swap_count[31:24];
                        stream_packet[37]  <= core_profile_buffer_swap_count[23:16];
                        stream_packet[38]  <= core_profile_buffer_swap_count[15:8];
                        stream_packet[39]  <= core_profile_buffer_swap_count[7:0];
                        stream_packet[40]  <= core_profile_output_tile_count[31:24];
                        stream_packet[41]  <= core_profile_output_tile_count[23:16];
                        stream_packet[42]  <= core_profile_output_tile_count[15:8];
                        stream_packet[43]  <= core_profile_output_tile_count[7:0];
                        stream_packet[44]  <= core_profile_k_pass_count[31:24];
                        stream_packet[45]  <= core_profile_k_pass_count[23:16];
                        stream_packet[46]  <= core_profile_k_pass_count[15:8];
                        stream_packet[47]  <= core_profile_k_pass_count[7:0];
                        stream_packet[48]  <= core_profile_result_signature[31:24];
                        stream_packet[49]  <= core_profile_result_signature[23:16];
                        stream_packet[50]  <= core_profile_result_signature[15:8];
                        stream_packet[51]  <= core_profile_result_signature[7:0];
                        stream_packet_len  <= STREAM_PACKET_MAX_BYTES;
                        stream_packet_index <= '0;
                        stream_state       <= STREAM_PACKET;
                    end

                    CMD_WRITE_A_BURST: begin
                        if (!core_busy &&
                            (pending_data_byte != 0) &&
                            ((pending_word + pending_data_byte) <= MATRIX_ELEMS)) begin
                            burst_active       <= 1'b1;
                            burst_is_b         <= 1'b0;
                            burst_addr         <= pending_word[ADDRW-1:0];
                            burst_remaining    <= pending_data_byte;
                            pending_burst_seen <= 1'b1;
                            done_latched       <= 1'b0;
                            rx_state           <= RX_BURST_DATA;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_WRITE_B_BURST: begin
                        if (!core_busy &&
                            (pending_data_byte != 0) &&
                            ((pending_word + pending_data_byte) <= MATRIX_ELEMS)) begin
                            burst_active       <= 1'b1;
                            burst_is_b         <= 1'b1;
                            burst_addr         <= pending_word[ADDRW-1:0];
                            burst_remaining    <= pending_data_byte;
                            pending_burst_seen <= 1'b1;
                            done_latched       <= 1'b0;
                            rx_state           <= RX_BURST_DATA;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_ZERO_A_RUN: begin
                        if (!core_busy &&
                            (pending_data_byte != 0) &&
                            ((pending_word + pending_data_byte) <= MATRIX_ELEMS)) begin
                            zero_run_active    <= 1'b1;
                            zero_run_is_b      <= 1'b0;
                            zero_run_addr      <= pending_word[ADDRW-1:0];
                            zero_run_remaining <= pending_data_byte;
                            pending_zero_seen  <= 1'b1;
                            done_latched       <= 1'b0;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_ZERO_B_RUN: begin
                        if (!core_busy &&
                            (pending_data_byte != 0) &&
                            ((pending_word + pending_data_byte) <= MATRIX_ELEMS)) begin
                            zero_run_active    <= 1'b1;
                            zero_run_is_b      <= 1'b1;
                            zero_run_addr      <= pending_word[ADDRW-1:0];
                            zero_run_remaining <= pending_data_byte;
                            pending_zero_seen  <= 1'b1;
                            done_latched       <= 1'b0;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    CMD_WRITE_SNN_IMG: begin
                        if (pending_word[15:8] == 8'd0) begin
                            snn_img_data[pending_word[7:0]] <= pending_data_byte;
                            tx_req_data  <= RESP_ACK;
                            tx_req_valid <= 1'b1;
                        end else begin
                            tx_req_data  <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end
                    
                    CMD_START_SNN: begin
                        snn_start_trigger <= 1'b1;
                        snn_done_latched <= 1'b0;
                        snn_prediction_latched <= 4'd0;
                        result_led_valid <= 1'b0;
                        tx_req_data  <= RESP_ACK;
                        tx_req_valid <= 1'b1;
                        done_latched <= 1'b0;
                    end
                    
                    CMD_STATUS_SNN: begin
                        if (snn_done_latched) begin
                            stream_packet[0] <= RESP_STATUS;
                            stream_packet[1] <= {4'b0000, snn_prediction_latched};
                            stream_packet_len <= 2;
                            stream_packet_index <= '0;
                            stream_state <= STREAM_PACKET;
                        end else begin
                            tx_req_data <= RESP_ERROR;
                            tx_req_valid <= 1'b1;
                        end
                    end

                    default: begin
                        tx_req_data  <= RESP_ERROR;
                        tx_req_valid <= 1'b1;
                    end
                endcase
            end else if (!tx_busy && !tx_req_valid && !command_engine_busy) begin
                case (stream_state)
                    STREAM_IDLE: begin
                    end

                    STREAM_PACKET: begin
                        tx_req_data  <= stream_packet[stream_packet_index];
                        tx_req_valid <= 1'b1;
                        if ((stream_packet_index + 1'b1) >= stream_packet_len) begin
                            stream_packet_index <= '0;
                            stream_state        <= STREAM_IDLE;
                        end else begin
                            stream_packet_index <= stream_packet_index + 1'b1;
                        end
                    end

                    STREAM_DUMP_DIM_HI: begin
                        tx_req_data  <= output_dim_u16[15:8];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_DUMP_DIM_LO;
                    end

                    STREAM_DUMP_DIM_LO: begin
                        tx_req_data  <= output_dim_u16[7:0];
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

    always @(*) begin
        led_out = 16'd0;

        if (core_busy) begin
            led_out[3:0]  = led_mode;
            led_out[4]    = led_clear_c_seen;
            led_out[5]    = led_load_seen;
            led_out[6]    = led_clear_acc_seen;
            led_out[7]    = led_run_seen;
            led_out[8]    = led_writeback_seen;
            led_out[9]    = (core_debug_state == ST_WAIT_LOAD);
            led_out[10]   = core_load_active &&
                            ((core_debug_state == ST_RUN) || (core_debug_state == ST_WRITEBACK));
            led_out[11]   = led_tx_seen;
            led_out[12]   = led_rx_seen;
            led_out[13]   = 1'b1;
            led_out[14]   = core_overflow_flag;
            led_out[15]   = led_heartbeat;
        end else if (done_latched) begin
            if (result_led_valid) begin
                led_out[7:0]  = result_led_code;
                led_out[8]    = 1'b1;
                led_out[9]    = core_overflow_flag;
                led_out[10]   = profile_wait_seen;
                led_out[11]   = profile_overlap_seen;
                led_out[12]   = profile_swap_seen;
                led_out[13]   = led_writeback_seen;
                led_out[14]   = 1'b1;
                led_out[15]   = led_heartbeat;
            end else begin
                led_out[3:0]  = led_mode;
                led_out[4]    = 1'b1;
                led_out[5]    = core_overflow_flag;
                led_out[6]    = profile_wait_seen;
                led_out[7]    = profile_overlap_seen;
                led_out[8]    = profile_swap_seen;
                led_out[9]    = run_burst_seen;
                led_out[10]   = run_zero_seen;
                led_out[11]   = led_writeback_seen;
                led_out[12]   = led_run_seen;
                led_out[13]   = led_load_seen;
                led_out[14]   = led_clear_c_seen;
                led_out[15]   = led_heartbeat;
            end
        end else if (command_engine_busy || pending_cmd_valid || (rx_state == RX_BURST_DATA)) begin
            led_out[3:0]  = led_mode;
            led_out[4]    = burst_active;
            led_out[5]    = zero_run_active;
            led_out[6]    = pending_burst_seen;
            led_out[7]    = pending_zero_seen;
            led_out[11]   = led_tx_seen;
            led_out[12]   = led_rx_seen;
            led_out[13]   = led_busy_seen;
            led_out[15]   = led_heartbeat;
        end else begin
            if (result_led_valid) begin
                led_out[7:0]  = result_led_code;
                led_out[8]    = 1'b1;
                led_out[9]    = done_latched;
                led_out[10]   = core_overflow_flag;
                led_out[11]   = led_tx_seen;
                led_out[12]   = led_rx_seen;
                led_out[13]   = led_busy_seen;
                led_out[14]   = led_writeback_seen | led_run_seen | led_load_seen;
                led_out[15]   = led_heartbeat;
            end else begin
                led_out[3:0]  = led_mode;
                led_out[4]    = done_latched;
                led_out[5]    = core_overflow_flag;
                led_out[6]    = profile_wait_seen;
                led_out[7]    = profile_overlap_seen;
                led_out[8]    = profile_swap_seen;
                led_out[9]    = run_burst_seen;
                led_out[10]   = run_zero_seen;
                led_out[11]   = led_tx_seen;
                led_out[12]   = led_rx_seen;
                led_out[13]   = led_busy_seen;
                led_out[14]   = led_writeback_seen | led_run_seen | led_load_seen;
                led_out[15]   = led_heartbeat;
            end
        end
    end

    sevenseg_display #(
        .CLK_HZ (SYS_CLK_HZ)
    ) u_sevenseg_display (
        .clk        (clk),
        .rst_n      (rst_n),
        .value_valid(result_led_valid),
        .value      (result_led_code),
        .seg        (SEG),
        .dp         (DP),
        .an         (AN)
    );

endmodule
