`timescale 1ns / 1ps

module reset_sync (
    input  wire clk,
    input  wire arst_n,
    output wire rst_n
);

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] sync_ff;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            sync_ff <= 2'b00;
        end else begin
            sync_ff <= {sync_ff[0], 1'b1};
        end
    end

    assign rst_n = sync_ff[1];

endmodule
