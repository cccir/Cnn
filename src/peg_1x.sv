module peg_1x #(
    parameter int DATA_W   = 6,
    parameter int WEIGHT_W = 2,
    parameter int ACC_W    = 13,
    parameter int ROWS     = 2,
    parameter int COLS     = 2,
    parameter int UNQ_DIR  = 4
)(
    input  logic clk,
    input  logic rst_n,

    // ── Boundary activation inputs ──────────────────────────────
    // h_in0 : act_from_right for PE[1][1]  (right edge, row 1)
    input  logic [DATA_W-1:0] h_in0,

    // v_in0 : act_from_down  for PE[1][0]  (bottom edge, col 0)
    input  logic [DATA_W-1:0] v_in0,

    // ── Control ─────────────────────────────────────────────────
    input  logic              en,
    input  logic              move_en,
    input  logic              psum_shift_en,
    input  logic              psum_clr,
    input  logic              w_ld_en,

    // ── Weight input — packed flat: w_in[c] = w_in[c*WEIGHT_W +: WEIGHT_W]
    input  logic [COLS*WEIGHT_W-1:0] w_in,

    // ── Direction control ────────────────────────────────────────
    // Uses the same encoding as the 4×4 parent:
    //   2'b11 = circular shift  (default)
    //   2'b10 = horizontal zig-zag
    //   2'b01 = vertical zig-zag
    //   2'b00 = circular shift  (fall-through)
    input  logic [1:0]          direction,

    // ── psum drain ───────────────────────────────────────────────
    // act_to_left of PE[1][0]  (col-0, row-1 left boundary)
    output logic [ACC_W-1:0]  psum_out0
);


    // ── Direction decode (identical group mapping as 4×4) ───────
    // Group assignment:
    //   PE[r][c]  r%2==0,c%2==0 → grp 0  : PE[0][0]
    //             r%2==0,c%2==1 → grp 1  : PE[0][1]
    //             r%2==1,c%2==0 → grp 2  : PE[1][0]
    //             r%2==1,c%2==1 → grp 3  : PE[1][1]

    logic [1:0] dst_sel [0:UNQ_DIR-1];
    logic [1:0] src_sel [0:UNQ_DIR-1];

    // dst_sel: 00=to_right 01=to_left 10=to_down 11=to_up
    // src_sel: 00=from_left 01=from_right 10=from_up 11=from_down

    always_comb begin : direction_encoding
        unique case (direction)
            // circular shift
            2'b11: begin
                dst_sel[0] = 2'b10; src_sel[0] = 2'b01;
                dst_sel[1] = 2'b01; src_sel[1] = 2'b11;
                dst_sel[2] = 2'b00; src_sel[2] = 2'b10;
                dst_sel[3] = 2'b11; src_sel[3] = 2'b00;
            end
            // horizontal zig-zag
            2'b10: begin
                dst_sel[0] = 2'b10; src_sel[0] = 2'b01;
                dst_sel[1] = 2'b01; src_sel[1] = 2'b11;
                dst_sel[2] = 2'b01; src_sel[2] = 2'b10;
                dst_sel[3] = 2'b11; src_sel[3] = 2'b01;
            end
            // vertical zig-zag
            2'b01: begin
                dst_sel[0] = 2'b11; src_sel[0] = 2'b01;
                dst_sel[1] = 2'b01; src_sel[1] = 2'b11;
                dst_sel[2] = 2'b00; src_sel[2] = 2'b11;
                dst_sel[3] = 2'b11; src_sel[3] = 2'b00;
            end
            // default → circular shift
            default: begin
                dst_sel[0] = 2'b10; src_sel[0] = 2'b01;
                dst_sel[1] = 2'b01; src_sel[1] = 2'b11;
                dst_sel[2] = 2'b00; src_sel[2] = 2'b10;
                dst_sel[3] = 2'b11; src_sel[3] = 2'b00;
            end
        endcase
    end

    // grp(r,c) = r*COLS+c — inlined directly at instantiation sites below.

    // ── Inter-PE wires ───────────────────────────────────────────
    logic [ACC_W-1:0] act_to_right  [0:ROWS-1][0:COLS-1];
    logic [ACC_W-1:0] act_to_left   [0:ROWS-1][0:COLS-1];
    logic [ACC_W-1:0] act_to_up     [0:ROWS-1][0:COLS-1];
    logic [ACC_W-1:0] act_to_down   [0:ROWS-1][0:COLS-1];
    logic [ACC_W-1:0] act_from_right[0:ROWS-1][0:COLS-1];
    logic [ACC_W-1:0] act_from_left [0:ROWS-1][0:COLS-1];
    logic [ACC_W-1:0] act_from_up   [0:ROWS-1][0:COLS-1];
    logic [ACC_W-1:0] act_from_down [0:ROWS-1][0:COLS-1];

    // ── Weight column chain (top → bottom per column) ────────────
    logic [WEIGHT_W-1:0] w_chain [0:ROWS][0:COLS-1];
    generate
        for (genvar c = 0; c < COLS; c++) begin : g_wchain_top
            assign w_chain[0][c] = w_in[c*WEIGHT_W +: WEIGHT_W];
        end
    endgenerate

    // ── Neighbour connections ────────────────────────────────────
    // Boundary rules:
    //   act_from_left  [r][0]     = '0          (left wall, all rows)
    //   act_from_right [1][1]     = ACC_W'(h_in0) (user spec: h_in0 → PE[1][1])
    //   act_from_right [0][COLS-1]= '0          (right wall, row 0)
    //   act_from_up    [0][c]     = '0          (top wall, all cols)
    //   act_from_down  [1][0]     = ACC_W'(v_in0) (user spec: v_in0 → PE[1][0])
    //   act_from_down  [1][1]     = '0          (bottom wall, col 1 — no v_in1)
    //   All other edge connections follow the internal neighbour rules.

    generate
        for (genvar r = 0; r < ROWS; r++) begin : g_conn_row
            for (genvar c = 0; c < COLS; c++) begin : g_conn_col

                // left neighbour
                assign act_from_left[r][c] =
                    (c == 0) ? '0
                             : act_to_right[r][c-1];

                // right neighbour / boundary
                assign act_from_right[r][c] =
                    (r==1 && c==COLS-1) ? {{(ACC_W-DATA_W){1'b0}}, h_in0} :
                    (c == COLS-1)       ? '0
                                        : act_to_left[r][c+1];

                // upper neighbour
                assign act_from_up[r][c] =
                    (r == 0) ? '0
                             : act_to_down[r-1][c];

                // lower neighbour / boundary
                assign act_from_down[r][c] =
                    (r==ROWS-1 && c==0) ? {{(ACC_W-DATA_W){1'b0}}, v_in0} :
                    (r == ROWS-1)       ? '0               // remaining bottom = '0
                                        : act_to_up[r+1][c];

            end
        end
    endgenerate

    // ── PE instantiation ─────────────────────────────────────────
    generate
        for (genvar r = 0; r < ROWS; r++) begin : g_pe_row
            for (genvar c = 0; c < COLS; c++) begin : g_pe_col
                pe #(
                    .DATA_W   (DATA_W),
                    .WEIGHT_W (WEIGHT_W),
                    .ACC_W    (ACC_W)
                ) u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .move_en        (move_en),
                    .psum_shift_en  (psum_shift_en),
                    .dst_sel        (dst_sel[r*COLS+c]),
                    .src_sel        (src_sel[r*COLS+c]),
                    .act_from_left  (act_from_left [r][c]),
                    .act_from_right (act_from_right[r][c]),
                    .act_from_up    (act_from_up   [r][c]),
                    .act_from_down  (act_from_down [r][c]),
                    .act_to_left    (act_to_left   [r][c]),
                    .act_to_right   (act_to_right  [r][c]),
                    .act_to_up      (act_to_up     [r][c]),
                    .act_to_down    (act_to_down   [r][c]),
                    .w_ld_en        (w_ld_en),
                    .w_in           (w_chain[r][c]),
                    .w_out          (w_chain[r+1][c]),
                    .psum_clr       (psum_clr),
                    .en_latched     (en)
                );
            end
        end
    endgenerate

    // ── psum drain ───────────────────────────────────────────────
    // PE[1][0] drives act_to_left when dst_sel = 2'b01 (to_left).
    // During psum_shift, direction=h-zigzag → grp2 dst_sel = to_left.
    assign psum_out0 = act_to_left[1][0];

endmodule
