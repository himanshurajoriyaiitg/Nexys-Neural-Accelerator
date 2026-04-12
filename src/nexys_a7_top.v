`timescale 1ns / 1ps
`include "params.vh"

module nexys_a7_top #(
    parameter integer N         = `DEFAULT_MATRIX_N,
    parameter integer ARRAY_N   = `DEFAULT_ARRAY_N,
    parameter integer DW        = `DEFAULT_DW,
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

    localparam integer MATRIX_ELEMS = N * N;
    localparam integer ADDRW        = clog2_safe(MATRIX_ELEMS);
    localparam integer RUN_W        = clog2_safe((3 * ARRAY_N) - 1);
    localparam integer DISPLAY_DIV  = CLK_HZ * 2;
    localparam integer DISPLAY_W    = clog2_safe(DISPLAY_DIV);

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

    localparam [1:0] RX_WAIT_START = 2'd0;
    localparam [1:0] RX_WAIT_CMD   = 2'd1;
    localparam [1:0] RX_WAIT_ARG0  = 2'd2;
    localparam [1:0] RX_WAIT_ARG1  = 2'd3;

    localparam [3:0] STREAM_IDLE         = 4'd0;
    localparam [3:0] STREAM_STATUS_FLAGS = 4'd1;
    localparam [3:0] STREAM_STATUS_HI    = 4'd2;
    localparam [3:0] STREAM_STATUS_LO    = 4'd3;
    localparam [3:0] STREAM_DUMP_DIM     = 4'd4;
    localparam [3:0] STREAM_DUMP_SETADDR = 4'd5;
    localparam [3:0] STREAM_DUMP_WAIT0   = 4'd6;
    localparam [3:0] STREAM_DUMP_WAIT1   = 4'd7;
    localparam [3:0] STREAM_DUMP_B3      = 4'd8;
    localparam [3:0] STREAM_DUMP_B2      = 4'd9;
    localparam [3:0] STREAM_DUMP_B1      = 4'd10;
    localparam [3:0] STREAM_DUMP_B0      = 4'd11;

    localparam [2:0] DBG_IDLE      = 3'd0;
    localparam [2:0] DBG_START     = 3'd1;
    localparam [2:0] DBG_CLEAR_C   = 3'd2;
    localparam [2:0] DBG_LOAD      = 3'd3;
    localparam [2:0] DBG_CLEAR_ACC = 3'd4;
    localparam [2:0] DBG_RUN       = 3'd5;
    localparam [2:0] DBG_WRITEBACK = 3'd6;
    localparam [2:0] DBG_DONE      = 3'd7;

    wire clk;
    wire rst_n;
    assign clk   = CLK100MHZ;
    assign rst_n = CPU_RESETN;

    wire [7:0] rx_data;
    wire       rx_valid;
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;
    reg  [7:0] tx_req_data;
    reg        tx_req_valid;

    reg                      core_start;
    wire                     core_busy;
    wire                     core_done;
    wire [31:0]              core_cycle_count;
    wire                     core_run_active;
    wire [RUN_W-1:0]         core_run_count;

    reg                      a_wr_en;
    reg                      b_wr_en;
    reg  [ADDRW-1:0]         a_wr_addr;
    reg  [ADDRW-1:0]         b_wr_addr;
    reg  signed [DW-1:0]     a_wr_data;
    reg  signed [DW-1:0]     b_wr_data;
    reg  [ADDRW-1:0]         c_host_rd_addr;
    wire signed [ACCW-1:0]   c_host_rd_data;

    reg  [1:0]               rx_state;
    reg  [7:0]               cmd_byte;
    reg  [7:0]               arg0_byte;
    reg  [7:0]               arg1_byte;
    reg                      pending_cmd_valid;
    reg  [7:0]               pending_cmd_byte;
    reg  [7:0]               pending_arg0_byte;
    reg  [7:0]               pending_arg1_byte;

    reg                      start_latched;
    reg                      done_latched;
    reg                      cmd_accept_latched;
    reg                      cmd_error_latched;
    reg  [7:0]               rx_activity_stretch;

    reg  [3:0]               stream_state;
    reg  [ADDRW-1:0]         dump_index;
    reg  signed [31:0]       dump_word;
    reg  [23:0]              start_led_timer;
    reg  [23:0]              done_led_timer;
    reg  [23:0]              cmd_accept_led_timer;
    reg  [DISPLAY_W-1:0]     display_div_count;
    reg                      display_run_active;
    reg  [RUN_W-1:0]         display_run_count;
    reg  [2:0]               debug_phase;

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
        .ACCW    (ACCW)
    ) u_tpu_top (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (core_start),
        .busy           (core_busy),
        .done           (core_done),
        .cycle_count    (core_cycle_count),
        .debug_run_active(core_run_active),
        .debug_run_count (core_run_count),
        .a_wr_en        (a_wr_en),
        .b_wr_en        (b_wr_en),
        .a_wr_addr      (a_wr_addr),
        .b_wr_addr      (b_wr_addr),
        .a_wr_data      (a_wr_data),
        .b_wr_data      (b_wr_data),
        .c_host_rd_addr (c_host_rd_addr),
        .c_host_rd_data (c_host_rd_data)
    );

    assign LED[4:0]  = (debug_phase == DBG_RUN) ? {{(5-RUN_W){1'b0}}, display_run_count} : 5'd0;
    assign LED[7:5]  = 3'b000;
    assign LED[8]    = (debug_phase == DBG_START);
    assign LED[9]    = (debug_phase == DBG_DONE);
    assign LED[10]   = (debug_phase == DBG_CLEAR_C);
    assign LED[11]   = (debug_phase == DBG_LOAD);
    assign LED[12]   = (debug_phase == DBG_CLEAR_ACC);
    assign LED[13]   = (debug_phase == DBG_RUN);
    assign LED[14]   = (debug_phase == DBG_WRITEBACK);
    assign LED[15]   = core_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state            <= RX_WAIT_START;
            cmd_byte            <= 8'd0;
            arg0_byte           <= 8'd0;
            arg1_byte           <= 8'd0;
            pending_cmd_valid   <= 1'b0;
            pending_cmd_byte    <= 8'd0;
            pending_arg0_byte   <= 8'd0;
            pending_arg1_byte   <= 8'd0;
            core_start          <= 1'b0;
            a_wr_en             <= 1'b0;
            b_wr_en             <= 1'b0;
            a_wr_addr           <= '0;
            b_wr_addr           <= '0;
            a_wr_data           <= '0;
            b_wr_data           <= '0;
            c_host_rd_addr      <= '0;
            tx_data             <= 8'd0;
            tx_start            <= 1'b0;
            tx_req_data         <= 8'd0;
            tx_req_valid        <= 1'b0;
            start_latched       <= 1'b0;
            done_latched        <= 1'b0;
            cmd_accept_latched  <= 1'b0;
            cmd_error_latched   <= 1'b0;
            rx_activity_stretch <= 8'd0;
            stream_state        <= STREAM_IDLE;
            dump_index          <= '0;
            dump_word           <= 32'sd0;
            start_led_timer     <= 24'd0;
            done_led_timer      <= 24'd0;
            cmd_accept_led_timer <= 24'd0;
            display_div_count   <= '0;
            display_run_active  <= 1'b0;
            display_run_count   <= '0;
            debug_phase         <= DBG_IDLE;
        end else begin
            core_start <= 1'b0;
            a_wr_en    <= 1'b0;
            b_wr_en    <= 1'b0;
            tx_start   <= 1'b0;

            if (start_led_timer != 24'd0) begin
                start_led_timer <= start_led_timer - 1'b1;
            end
            if (done_led_timer != 24'd0) begin
                done_led_timer <= done_led_timer - 1'b1;
            end
            if (cmd_accept_led_timer != 24'd0) begin
                cmd_accept_led_timer <= cmd_accept_led_timer - 1'b1;
            end

            case (debug_phase)
                DBG_IDLE: begin
                    display_div_count <= '0;
                end

                DBG_START: begin
                    if (display_div_count == (DISPLAY_DIV - 1)) begin
                        display_div_count <= '0;
                        debug_phase       <= DBG_CLEAR_C;
                    end else begin
                        display_div_count <= display_div_count + 1'b1;
                    end
                end

                DBG_CLEAR_C: begin
                    if (display_div_count == (DISPLAY_DIV - 1)) begin
                        display_div_count <= '0;
                        debug_phase       <= DBG_LOAD;
                    end else begin
                        display_div_count <= display_div_count + 1'b1;
                    end
                end

                DBG_LOAD: begin
                    if (display_div_count == (DISPLAY_DIV - 1)) begin
                        display_div_count <= '0;
                        debug_phase       <= DBG_CLEAR_ACC;
                    end else begin
                        display_div_count <= display_div_count + 1'b1;
                    end
                end

                DBG_CLEAR_ACC: begin
                    if (display_div_count == (DISPLAY_DIV - 1)) begin
                        display_div_count <= '0;
                        debug_phase       <= DBG_RUN;
                        display_run_count <= '0;
                    end else begin
                        display_div_count <= display_div_count + 1'b1;
                    end
                end

                DBG_RUN: begin
                    if (display_div_count == (DISPLAY_DIV - 1)) begin
                        display_div_count <= '0;
                        if (display_run_count == ((3 * ARRAY_N) - 3)) begin
                            debug_phase <= DBG_WRITEBACK;
                        end else begin
                            display_run_count <= display_run_count + 1'b1;
                        end
                    end else begin
                        display_div_count <= display_div_count + 1'b1;
                    end
                end

                DBG_WRITEBACK: begin
                    if (display_div_count == (DISPLAY_DIV - 1)) begin
                        display_div_count <= '0;
                        debug_phase       <= DBG_DONE;
                    end else begin
                        display_div_count <= display_div_count + 1'b1;
                    end
                end

                DBG_DONE: begin
                    display_div_count <= '0;
                end

                default: begin
                    debug_phase <= DBG_IDLE;
                end
            endcase

            if (tx_req_valid && !tx_busy) begin
                tx_data      <= tx_req_data;
                tx_start     <= 1'b1;
                tx_req_valid <= 1'b0;
            end

            if (rx_valid) begin
                rx_activity_stretch <= 8'hFF;
            end else if (rx_activity_stretch != 8'd0) begin
                rx_activity_stretch <= rx_activity_stretch - 1'b1;
            end

            if (core_done) begin
                done_latched <= 1'b1;
                done_led_timer <= 24'hFFFFFF;
            end

            if (rx_valid) begin
                case (rx_state)
                    RX_WAIT_START: begin
                        if (rx_data == FRAME_START) begin
                            rx_state <= RX_WAIT_CMD;
                        end
                    end

                    RX_WAIT_CMD: begin
                        cmd_byte <= rx_data;
                        rx_state <= RX_WAIT_ARG0;
                    end

                    RX_WAIT_ARG0: begin
                        arg0_byte <= rx_data;
                        rx_state  <= RX_WAIT_ARG1;
                    end

                    RX_WAIT_ARG1: begin
                        arg1_byte <= rx_data;
                        rx_state  <= RX_WAIT_START;
                        if (!pending_cmd_valid) begin
                            pending_cmd_valid <= 1'b1;
                            pending_cmd_byte  <= cmd_byte;
                            pending_arg0_byte <= arg0_byte;
                            pending_arg1_byte <= rx_data;
                        end
                    end

                    default: begin
                        rx_state <= RX_WAIT_START;
                    end
                endcase
            end

            if (pending_cmd_valid && (stream_state == STREAM_IDLE) && !tx_busy && !tx_req_valid) begin
                cmd_accept_latched <= 1'b0;
                cmd_error_latched  <= 1'b0;
                pending_cmd_valid  <= 1'b0;

                case (pending_cmd_byte)
                    CMD_WRITE_A: begin
                        if (!core_busy && (pending_arg0_byte < MATRIX_ELEMS)) begin
                            a_wr_en            <= 1'b1;
                            a_wr_addr          <= pending_arg0_byte[ADDRW-1:0];
                            a_wr_data          <= $signed(pending_arg1_byte);
                            tx_req_data        <= RESP_ACK;
                            tx_req_valid       <= 1'b1;
                            cmd_accept_latched <= 1'b1;
                            cmd_accept_led_timer <= 24'h7FFFFF;
                        end else begin
                            tx_req_data       <= RESP_ERROR;
                            tx_req_valid      <= 1'b1;
                            cmd_error_latched <= 1'b1;
                        end
                    end

                    CMD_WRITE_B: begin
                        if (!core_busy && (pending_arg0_byte < MATRIX_ELEMS)) begin
                            b_wr_en            <= 1'b1;
                            b_wr_addr          <= pending_arg0_byte[ADDRW-1:0];
                            b_wr_data          <= $signed(pending_arg1_byte);
                            tx_req_data        <= RESP_ACK;
                            tx_req_valid       <= 1'b1;
                            cmd_accept_latched <= 1'b1;
                            cmd_accept_led_timer <= 24'h7FFFFF;
                        end else begin
                            tx_req_data       <= RESP_ERROR;
                            tx_req_valid      <= 1'b1;
                            cmd_error_latched <= 1'b1;
                        end
                    end

                    CMD_START: begin
                        if (!core_busy) begin
                            core_start         <= 1'b1;
                            start_latched      <= 1'b1;
                            done_latched       <= 1'b0;
                            start_led_timer    <= 24'hFFFFFF;
                            done_led_timer     <= 24'd0;
                            display_run_active <= 1'b0;
                            display_run_count  <= '0;
                            display_div_count  <= '0;
                            debug_phase        <= DBG_START;
                            tx_req_data        <= RESP_ACK;
                            tx_req_valid       <= 1'b1;
                            cmd_accept_latched <= 1'b1;
                            cmd_accept_led_timer <= 24'h7FFFFF;
                        end else begin
                            tx_req_data       <= RESP_ERROR;
                            tx_req_valid      <= 1'b1;
                            cmd_error_latched <= 1'b1;
                        end
                    end

                    CMD_STATUS: begin
                        tx_req_data        <= RESP_STATUS;
                        tx_req_valid       <= 1'b1;
                        stream_state       <= STREAM_STATUS_FLAGS;
                        cmd_accept_latched <= 1'b1;
                        cmd_accept_led_timer <= 24'h7FFFFF;
                    end

                    CMD_DUMP_C: begin
                        if (!core_busy) begin
                            tx_req_data        <= RESP_DUMP;
                            tx_req_valid       <= 1'b1;
                            dump_index         <= '0;
                            stream_state       <= STREAM_DUMP_DIM;
                            cmd_accept_latched <= 1'b1;
                            cmd_accept_led_timer <= 24'h7FFFFF;
                        end else begin
                            tx_req_data       <= RESP_ERROR;
                            tx_req_valid      <= 1'b1;
                            cmd_error_latched <= 1'b1;
                        end
                    end

                    default: begin
                        tx_req_data       <= RESP_ERROR;
                        tx_req_valid      <= 1'b1;
                        cmd_error_latched <= 1'b1;
                    end
                endcase
            end else if (!tx_busy && !tx_req_valid) begin
                case (stream_state)
                    STREAM_IDLE: begin
                    end

                    STREAM_STATUS_FLAGS: begin
                        tx_req_data  <= {6'b0, done_latched, core_busy};
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_STATUS_HI;
                    end

                    STREAM_STATUS_HI: begin
                        tx_req_data  <= core_cycle_count[15:8];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_STATUS_LO;
                    end

                    STREAM_STATUS_LO: begin
                        tx_req_data  <= core_cycle_count[7:0];
                        tx_req_valid <= 1'b1;
                        stream_state <= STREAM_IDLE;
                    end

                    STREAM_DUMP_DIM: begin
                        tx_req_data  <= N;
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
                        if (dump_index == (MATRIX_ELEMS - 1)) begin
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
