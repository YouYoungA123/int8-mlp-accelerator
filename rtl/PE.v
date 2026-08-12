module PE(
input weight_load,
input clk,
input rst,
input signed [7:0] weight,
input signed [7:0] in,
output signed [15:0] out);
reg signed [7:0] weight_reg;
always @(posedge clk or posedge rst) begin
    if (rst)
        weight_reg<=8'b0;
    else if (weight_load)
        weight_reg<=weight;
end
assign out=weight_reg*in;
endmodule
