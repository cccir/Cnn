// ============================================================
//  uart_peg_top.sv  —  UART wrapper for peg_1x (2×2 PEG)
//
//  Ports: clk, rst_n, rx, tx  (no others)
//
//  Protocol  8N1, BAUD_RATE = 115 200 (parameterisable)
//  ─────────────────────────────────────────────────────────
//  PC → FPGA : 3 bytes per DUT clock cycle
//
//    Byte 0   [7]   = en
//             [6]   = move_en
//             [5]   = psum_shift_en
//             [4]   = psum_clr
//             [3]   = w_ld_en
//             [2:1] = direction[1:0]
//             [0]   = (reserved, send 0)
//    Byte 1   [7:2] = h_in0[5:0]
//             [1:0] = v_in0[5:4]
//    Byte 2   [7:4] = v_in0[3:0]
//             [3:2] = w_in[1][1:0]
//             [1:0] = w_in[0][1:0]
//
//  FPGA → PC : 2 bytes after each applied cycle
//    Byte 0   [4:0] = psum_out0[12:8]   (bits [7:5] = 0)
//    Byte 1   [7:0] = psum_out0[7:0]
//
//  Timing notes
//  ─────────────────────────────────────────────────────────
//  Each 3-byte packet drives the DUT for exactly ONE clock
//  cycle (the APPLY state).  The five transient control
//  signals (en, move_en, psum_shift_en, psum_clr, w_ld_en)
//  are auto-cleared after APPLY so long inter-packet gaps
//  cannot corrupt the accumulator.  Sticky signals
//  (direction, h_in0, v_in0, w_in) retain their last value.
//
//  psum_out0 is captured at the posedge that ends APPLY —
//  this is the same sample point used by the testbench's
//  drain_psum task (combinational output one posedge after
//  psum_shift_en rises, before first_shift clears).
//
//  The PC must wait for the 2-byte response before sending
//  the next packet; bytes arriving during TX are discarded.
// ============================================================



// ─────────────────────────────────────────────────────────────
//  UART RX  (8N1)
// ─────────────────────────────────────────────────────────────
module uart_rx #(
    parameter int CLK_FREQ  = 100_000_000,
    parameter int BAUD_RATE = 115_200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid   // 1-cycle pulse when byte ready
);
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam int CNT_W        = $clog2(CLKS_PER_BIT + 1);

    typedef enum logic [1:0] {S_IDLE, S_START, S_DATA, S_STOP} state_t;
    state_t state;

    logic [CNT_W-1:0] cnt;
    logic [2:0]       bit_idx;
    logic [7:0]       shift;
    logic             rxq0, rxq;   // 2-FF metastability guard

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin rxq0 <= 1'b1; rxq <= 1'b1; end
        else        begin rxq0 <= rx;   rxq <= rxq0;  end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            cnt     <= '0;
            bit_idx <= '0;
            shift   <= '0;
            data    <= '0;
            valid   <= 1'b0;
        end else begin
            valid <= 1'b0;
            unique case (state)
                S_IDLE:
                    if (!rxq) begin                          // start-bit edge
                        cnt   <= CNT_W'(CLKS_PER_BIT/2 - 1);
                        state <= S_START;
                    end

                S_START:
                    if (cnt == '0) begin
                        if (!rxq) begin                      // confirm start bit
                            cnt     <= CNT_W'(CLKS_PER_BIT - 1);
                            bit_idx <= '0;
                            state   <= S_DATA;
                        end else
                            state <= S_IDLE;                 // glitch — abort
                    end else cnt <= cnt - 1;

                S_DATA:
                    if (cnt == '0) begin
                        shift <= {rxq, shift[7:1]};          // LSB first
                        cnt   <= CNT_W'(CLKS_PER_BIT - 1);
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else                 bit_idx <= bit_idx + 1;
                    end else cnt <= cnt - 1;

                S_STOP:
                    if (cnt == '0) begin
                        if (rxq) begin data <= shift; valid <= 1'b1; end
                        state <= S_IDLE;
                    end else cnt <= cnt - 1;
            endcase
        end
    end
endmodule


// ─────────────────────────────────────────────────────────────
//  UART TX  (8N1)
// ─────────────────────────────────────────────────────────────
module uart_tx #(
    parameter int CLK_FREQ  = 100_000_000,
    parameter int BAUD_RATE = 115_200
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] data,
    input  logic       start,  // 1-cycle pulse to begin transmission
    output logic       tx,
    output logic       busy
);
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam int CNT_W        = $clog2(CLKS_PER_BIT + 1);

    typedef enum logic [1:0] {S_IDLE, S_START, S_DATA, S_STOP} state_t;
    state_t state;

    logic [CNT_W-1:0] cnt;
    logic [2:0]       bit_idx;
    logic [7:0]       shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            tx      <= 1'b1;
            busy    <= 1'b0;
            cnt     <= '0;
            bit_idx <= '0;
            shift   <= '0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    tx <= 1'b1; busy <= 1'b0;
                    if (start) begin
                        shift   <= data;
                        cnt     <= CNT_W'(CLKS_PER_BIT - 1);
                        busy    <= 1'b1;
                        state   <= S_START;
                    end
                end
                S_START: begin
                    tx <= 1'b0;
                    if (cnt == '0) begin
                        bit_idx <= '0;
                        cnt     <= CNT_W'(CLKS_PER_BIT - 1);
                        state   <= S_DATA;
                    end else cnt <= cnt - 1;
                end
                S_DATA: begin
                    tx <= shift[0];
                    if (cnt == '0) begin
                        shift   <= shift >> 1;
                        cnt     <= CNT_W'(CLKS_PER_BIT - 1);
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else                 bit_idx <= bit_idx + 1;
                    end else cnt <= cnt - 1;
                end
                S_STOP: begin
                    tx <= 1'b1;
                    if (cnt == '0) state <= S_IDLE;
                    else cnt <= cnt - 1;
                end
            endcase
        end
    end
endmodule


// ─────────────────────────────────────────────────────────────
//  Top-level wrapper
// ─────────────────────────────────────────────────────────────
module uart_peg_top #(
    parameter int CLK_FREQ  = 100_000_000,
    parameter int BAUD_RATE = 115_200,
    parameter int DATA_W    = 6,
    parameter int WEIGHT_W  = 2,
    parameter int ACC_W     = 13,
    parameter int COLS      = 2
)(
    input  logic clk,
    input  logic rst_n,
    input  logic rx,
    output logic tx
);

    // ── UART wires ────────────────────────────────────────────
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_start, tx_busy;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(rx),
        .data(rx_data), .valid(rx_valid)
    );
    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_tx (
        .clk(clk), .rst_n(rst_n), .data(tx_data), .start(tx_start),
        .tx(tx), .busy(tx_busy)
    );

    // ── DUT input registers (driven from decoded packet) ──────
    logic                dut_en, dut_move_en, dut_psum_shift_en;
    logic                dut_psum_clr, dut_w_ld_en;
    logic [1:0]          dut_direction;
    logic [DATA_W-1:0]   dut_h_in0, dut_v_in0;
    logic [COLS*WEIGHT_W-1:0] dut_w_in;  // packed: [1]=bits[3:2], [0]=bits[1:0]

    logic [ACC_W-1:0] psum_out0;

    peg_1x #(
        .DATA_W(DATA_W), .WEIGHT_W(WEIGHT_W), .ACC_W(ACC_W),
        .ROWS(2), .COLS(COLS)
    ) u_dut (
        .clk(clk),           .rst_n(rst_n),
        .h_in0(dut_h_in0),   .v_in0(dut_v_in0),
        .en(dut_en),         .move_en(dut_move_en),
        .psum_shift_en(dut_psum_shift_en),
        .psum_clr(dut_psum_clr),
        .w_ld_en(dut_w_ld_en),
        .w_in(dut_w_in),
        .direction(dut_direction),
        .psum_out0(psum_out0)
    );

    // ── Packet receive buffers ────────────────────────────────
    logic [7:0]       pkt_b0, pkt_b1;   // byte 2 decoded directly from rx_data
    logic [ACC_W-1:0] psum_cap;          // psum_out0 captured at end of APPLY

    // ── FSM ───────────────────────────────────────────────────
    // TX_Bx_PEND: one dead cycle after pulsing tx_start so that
    // uart_tx can assert busy before TX_Bx_WAIT checks it.
    typedef enum logic [3:0] {
        WAIT_B0,
        WAIT_B1,
        WAIT_B2,
        APPLY,
        TX_B0,
        TX_B0_PEND,
        TX_B0_WAIT,
        TX_B1,
        TX_B1_PEND,
        TX_B1_WAIT
    } fsm_t;
    fsm_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= WAIT_B0;
            pkt_b0            <= '0;
            pkt_b1            <= '0;
            psum_cap          <= '0;
            tx_data           <= '0;
            tx_start          <= 1'b0;
            // Safe idle: all pulses low, h-zigzag direction held
            dut_en            <= 1'b0;
            dut_move_en       <= 1'b0;
            dut_psum_shift_en <= 1'b0;
            dut_psum_clr      <= 1'b0;
            dut_w_ld_en       <= 1'b0;
            dut_direction     <= 2'b10;
            dut_h_in0         <= '0;
            dut_v_in0         <= '0;
            dut_w_in          <= '0;
        end else begin
            tx_start <= 1'b0;   // default: no TX pulse

            unique case (state)

                // ── Packet reception ─────────────────────────
                WAIT_B0:
                    if (rx_valid) begin
                        pkt_b0 <= rx_data;
                        state  <= WAIT_B1;
                    end

                WAIT_B1:
                    if (rx_valid) begin
                        pkt_b1 <= rx_data;
                        state  <= WAIT_B2;
                    end

                WAIT_B2:
                    if (rx_valid) begin
                        // Decode all three bytes into DUT input registers.
                        // These new values reach the DUT between this posedge
                        // and the next (APPLY posedge).
                        dut_en            <= pkt_b0[7];
                        dut_move_en       <= pkt_b0[6];
                        dut_psum_shift_en <= pkt_b0[5];
                        dut_psum_clr      <= pkt_b0[4];
                        dut_w_ld_en       <= pkt_b0[3];
                        dut_direction     <= pkt_b0[2:1];
                        dut_h_in0         <= pkt_b1[7:2];
                        dut_v_in0         <= {pkt_b1[1:0], rx_data[7:4]};
                        dut_w_in[3:2]     <= rx_data[3:2];  // w_in[1]
                        dut_w_in[1:0]     <= rx_data[1:0];  // w_in[0]
                        state             <= APPLY;
                    end

                // ── Single DUT clock cycle ────────────────────
                // DUT sees the decoded inputs during the inter-posedge
                // interval that precedes this posedge.  On THIS posedge:
                //   • DUT FFs (move_reg, w_reg, psum_out via gated clk) latch.
                //   • psum_out0 is combinational and valid just before this
                //     posedge — the FF assignment captures that pre-posedge
                //     value into psum_cap (standard SV non-blocking semantics).
                // Transient control pulses are auto-cleared so the accumulator
                // is not corrupted during the long TX phase that follows.
                APPLY: begin
                    psum_cap          <= psum_out0;
                    dut_en            <= 1'b0;
                    dut_move_en       <= 1'b0;
                    dut_psum_shift_en <= 1'b0;
                    dut_psum_clr      <= 1'b0;
                    dut_w_ld_en       <= 1'b0;
                    state             <= TX_B0;
                end

                // ── Transmit high byte psum_cap[12:8] ─────────
                TX_B0: begin
                    tx_data  <= {3'b000, psum_cap[12:8]};
                    tx_start <= 1'b1;
                    state    <= TX_B0_PEND;
                end

                TX_B0_PEND:         // wait one cycle for uart_tx to assert busy
                    state <= TX_B0_WAIT;

                TX_B0_WAIT:
                    if (!tx_busy) state <= TX_B1;

                // ── Transmit low byte psum_cap[7:0] ───────────
                TX_B1: begin
                    tx_data  <= psum_cap[7:0];
                    tx_start <= 1'b1;
                    state    <= TX_B1_PEND;
                end

                TX_B1_PEND:
                    state <= TX_B1_WAIT;

                TX_B1_WAIT:
                    if (!tx_busy) state <= WAIT_B0;

            endcase
        end
    end
endmodule
