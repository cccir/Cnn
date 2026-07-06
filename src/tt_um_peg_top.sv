// TinyTapeout GF26a wrapper for uart_peg_top
// Pins: ui_in[0] = rx,  uo_out[0] = tx,  all others unused.
`default_nettype none

module tt_um_peg_top (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    assign uio_out  = 8'b0;
    assign uio_oe   = 8'b0;
    assign uo_out[7:1] = 7'b0;

    uart_peg_top #(
        .CLK_FREQ  (25_000_000),
        .BAUD_RATE (115_200),
        .DATA_W    (6),
        .WEIGHT_W  (2),
        .ACC_W     (13),
        .COLS      (2)
    ) u_core (
        .clk   (clk),
        .rst_n (rst_n),
        .rx    (ui_in[0]),
        .tx    (uo_out[0])
    );

endmodule
