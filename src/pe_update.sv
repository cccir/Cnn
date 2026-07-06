module pe #(
    parameter int DATA_W   = 6,
    parameter int WEIGHT_W = 2, // 2's comp range -2..1
    parameter int ACC_W    = 13
)(
    input  logic              clk,
    input  logic              rst_n,
    //input  logic              en,          // compute enable — high in CLEAR and COMPUTE only
    input  logic              move_en,
    input  logic              psum_shift_en,
    input  logic [1:0]        dst_sel,
    input  logic [1:0]        src_sel,

    input  logic [ACC_W-1:0]  act_from_left,
    input  logic [ACC_W-1:0]  act_from_right,
    input  logic [ACC_W-1:0]  act_from_up,
    input  logic [ACC_W-1:0]  act_from_down,

    output logic [ACC_W-1:0]  act_to_left,
    output logic [ACC_W-1:0]  act_to_right,
    output logic [ACC_W-1:0]  act_to_up,
    output logic [ACC_W-1:0]  act_to_down,

    input  logic                    w_ld_en,
    input  logic [WEIGHT_W-1:0]     w_in,
    output logic [WEIGHT_W-1:0]     w_out,

    input  logic                    psum_clr,
    input  logic                    en_latched // gated clock en signal for psum_out register
);



    // ── Registers ────────────────────────────────────────────────
    logic [ACC_W-1:0]           move_reg;
    logic signed [WEIGHT_W-1:0] w_reg;
    logic signed [ACC_W-1:0]    psum_out;

    // ── Incoming mux ─────────────────────────────────────────────
    logic [ACC_W-1:0] incoming;
    always_comb begin
        unique case (src_sel)
            2'b00: incoming = act_from_left;
            2'b01: incoming = act_from_right;
            2'b10: incoming = act_from_up;
            2'b11: incoming = act_from_down;
            default: incoming = '0;
        endcase
    end

    ///// Weight buffering //////////////////////
    logic signed [WEIGHT_W-1:0] w_buffer;

    // ── Weight register ───────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin       
            w_buffer <= '0;
        end else if (w_ld_en) begin
            w_buffer <= $signed(w_in);
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) w_reg <= '0;
        else w_reg <= w_buffer; // 1-cycle delayed weight
    end

    assign w_out = w_buffer;

    // ── MAC ───────────────────────────────────────────────────────
    logic [DATA_W-1:0]   act_val;
    logic signed   [WEIGHT_W-1:0] w_val;
    logic signed   [ACC_W-1:0]    product;

    // Opt1: operand isolation — en=0 forces multiplier inputs to zero,
    // eliminating all internal switching during non-compute states.
    assign act_val = move_reg[DATA_W-1:0];
    assign w_val   = w_reg               ;

    assign product = $signed({{(ACC_W-DATA_W){1'b0}}, act_val}) *
                     $signed({{(ACC_W-WEIGHT_W){w_val[WEIGHT_W-1]}}, w_val});

    // ── Psum accumulator — gated clock ───────────────────────────
    // clk_psum_gated active only when en=1 (CLEAR + COMPUTE).
    // Synchronous clock enable replaces gated clock for synthesis compatibility.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_out <= '0;
        end else if (en_latched) begin
            if (psum_clr)
                psum_out <= '0;
            else
                psum_out <= psum_out + product;
        end
    end

    // ── Psum shift edge detect ────────────────────────────────────
    logic psum_shift_en_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) psum_shift_en_d <= '0;
        else        psum_shift_en_d <= psum_shift_en;
    end

    wire first_shift   = psum_shift_en  & ~psum_shift_en_d;  // rising edge

    // ── act_out_val mux ───────────────────────────────────────────
    // first_shift → own psum_out immediately (no move_reg latency)
    // otherwise   → move_reg (activation data or forwarded psum chain)
    logic [ACC_W-1:0] act_out_val;
    always_comb begin
        if (first_shift)
            act_out_val = psum_out;
        else
            act_out_val = move_reg;
    end

    // ── Movement register ─────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            move_reg <= '0;
        end else if (move_en) begin
                if (psum_shift_en)
                    move_reg <= incoming;                   // full ACC_W: psum chain
                else
                    move_reg <= {{(ACC_W-DATA_W){1'b0}}, incoming[DATA_W-1:0]}; // zero-extend activation
        end
    end

    // ── Directional output drive ──────────────────────────────────
    // Combinational, no FF delay. Only active direction carries
    // act_out_val; other three driven to '0 to prevent stale data
    // reaching neighbours in the wrong direction phase.
    assign act_to_right = (dst_sel == 2'b00) ? act_out_val : '0;
    assign act_to_left  = (dst_sel == 2'b01) ? act_out_val : '0;
    assign act_to_down  = (dst_sel == 2'b10) ? act_out_val : '0;
    assign act_to_up    = (dst_sel == 2'b11) ? act_out_val : '0;

endmodule
