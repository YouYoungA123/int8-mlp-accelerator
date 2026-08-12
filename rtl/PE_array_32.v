`timescale 1ns / 1ps

module PE_array_32(
    input  wire                     rst,
    input  wire                     clk,
    input  wire                     weight_load,

    input  wire signed [8*1024-1:0] weight,
    input  wire signed [8*32-1:0]   in,

    output wire signed [32*32-1:0]  final_out
);

    wire signed [15:0] pe_out   [0:1023];
    wire signed [20:0] tree_out [0:31];

    genvar i, j;

    generate
        for (i = 0; i < 32; i = i + 1) begin : i_loop

            for (j = 0; j < 32; j = j + 1) begin : j_loop
                PE pe_inst (
                    .weight_load(weight_load),
                    .clk        (clk),
                    .rst        (rst),
                    .weight     (weight[8*(32*i+j) +: 8]),
                    .in         (in[8*j +: 8]),
                    .out        (pe_out[32*i+j])
                );
            end

            adder_tree_32 adder_inst (
                .in0 (pe_out[32*i+0]),
                .in1 (pe_out[32*i+1]),
                .in2 (pe_out[32*i+2]),
                .in3 (pe_out[32*i+3]),
                .in4 (pe_out[32*i+4]),
                .in5 (pe_out[32*i+5]),
                .in6 (pe_out[32*i+6]),
                .in7 (pe_out[32*i+7]),
                .in8 (pe_out[32*i+8]),
                .in9 (pe_out[32*i+9]),
                .in10(pe_out[32*i+10]),
                .in11(pe_out[32*i+11]),
                .in12(pe_out[32*i+12]),
                .in13(pe_out[32*i+13]),
                .in14(pe_out[32*i+14]),
                .in15(pe_out[32*i+15]),
                .in16(pe_out[32*i+16]),
                .in17(pe_out[32*i+17]),
                .in18(pe_out[32*i+18]),
                .in19(pe_out[32*i+19]),
                .in20(pe_out[32*i+20]),
                .in21(pe_out[32*i+21]),
                .in22(pe_out[32*i+22]),
                .in23(pe_out[32*i+23]),
                .in24(pe_out[32*i+24]),
                .in25(pe_out[32*i+25]),
                .in26(pe_out[32*i+26]),
                .in27(pe_out[32*i+27]),
                .in28(pe_out[32*i+28]),
                .in29(pe_out[32*i+29]),
                .in30(pe_out[32*i+30]),
                .in31(pe_out[32*i+31]),
                .out (tree_out[i])
            );

            assign final_out[32*i +: 32]
                = {{11{tree_out[i][20]}}, tree_out[i]};

        end
    endgenerate

endmodule