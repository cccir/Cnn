// Optimized pe.sv
module pe #(
    parameter int DATA_W   = 6,
    parameter int WEIGHT_W = 2,
    parameter int ACC_W    = 13
)(
    input logic clk,rst_n,
    input logic move_en,
    input logic psum_shift_en,
    input logic [1:0] dst_sel,src_sel,
    input logic [ACC_W-1:0] act_from_left,act_from_right,act_from_up,act_from_down,
    output logic [ACC_W-1:0] act_to_left,act_to_right,act_to_up,act_to_down,
    input logic w_ld_en,
    input logic [WEIGHT_W-1:0] w_in,
    output logic [WEIGHT_W-1:0] w_out,
    input logic psum_clr,
    input logic en_latched
);
logic [ACC_W-1:0] move_reg,incoming,act_out_val;
logic signed [WEIGHT_W-1:0] w_reg;
logic signed [ACC_W-1:0] psum_out,act_ext,product;

always_comb begin
    unique case(src_sel)
      2'b00: incoming=act_from_left;
      2'b01: incoming=act_from_right;
      2'b10: incoming=act_from_up;
      default: incoming=act_from_down;
    endcase
end

always_ff @(posedge clk or negedge rst_n)
 if(!rst_n) w_reg<='0;
 else if(w_ld_en) w_reg<=$signed(w_in);

assign w_out=w_reg;

assign act_ext=$signed({{(ACC_W-DATA_W){1'b0}},move_reg[DATA_W-1:0]});

always_comb begin
    unique case(w_reg)
      2'sd0: product='0;
      2'sd1: product=act_ext;
      -2'sd1: product=-act_ext;
      -2'sd2: product=-(act_ext<<<1);
      default: product='0;
    endcase
end

always_ff @(posedge clk or negedge rst_n)
 if(!rst_n) psum_out<='0;
 else if(en_latched)
   if(psum_clr) psum_out<='0;
   else psum_out<=psum_out+product;

wire first_shift=psum_shift_en;

always_comb
  act_out_val = first_shift ? psum_out : move_reg;

always_ff @(posedge clk or negedge rst_n)
 if(!rst_n) move_reg<='0;
 else if(move_en)
   if(psum_shift_en) move_reg<=incoming;
   else move_reg<={{(ACC_W-DATA_W){1'b0}},incoming[DATA_W-1:0]};

always_comb begin
 act_to_right='0; act_to_left='0; act_to_up='0; act_to_down='0;
 unique case(dst_sel)
 2'b00: act_to_right=act_out_val;
 2'b01: act_to_left =act_out_val;
 2'b10: act_to_down =act_out_val;
 2'b11: act_to_up   =act_out_val;
 endcase
end
endmodule
