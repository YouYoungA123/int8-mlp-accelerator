`timescale 1ns / 1ps
module SRAM_module #(
parameter data_w=8,
parameter depth=32,
parameter addr_w=5
)(input clk,
input we,
input [addr_w-1:0] addr,
input signed [data_w-1:0] data_in,
output reg signed [data_w-1:0] data_out);
reg [data_w-1:0] mem [0:depth-1];
always @(posedge clk) begin
    if(we)
        mem[addr]<=data_in;
    data_out<=mem[addr];
end
endmodule
