`timescale 1ns / 1ps

// Target datapath for AXU2CGB: 8 output lanes x 16 input lanes = 128 MACs.
// Two valid cycles complete eight outputs of a logical 32-input tile.
module PE_array_8x16_mac (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     clear,
    input  wire                     first_in,
    input  wire                     valid_in,
    input  wire signed [8*128-1:0]  weight_subtile,
    input  wire signed [8*16-1:0]   input_subtile,
    output reg                      valid_out,
    output wire signed [32*8-1:0]   result
);
    // Register the selected bank before the multiplier array.  This cuts the
    // weight-bank mux and the DSP datapath into separate timing stages.
    reg signed [8*128-1:0] weight_pipe;
    reg signed [8*16-1:0]  input_pipe;
    reg                     valid_pipe;
    reg                     first_pipe;
    reg                     valid_sum;
    reg                     first_sum;
    (* use_dsp = "yes" *) wire signed [15:0] product [0:127];
    reg  signed [17:0] partial_sum [0:31];
    reg  signed [19:0] row_sum [0:7];
    reg  signed [31:0] accumulator [0:7];

    genvar row, col;
    generate
        for (row = 0; row < 8; row = row + 1) begin : gen_row
            for (col = 0; col < 16; col = col + 1) begin : gen_col
                wire signed [7:0] w;
                wire signed [7:0] x;
                assign w = weight_pipe[8*(row*16+col) +: 8];
                assign x = input_pipe[8*col +: 8];
                assign product[row*16+col] = w * x;
            end
            assign result[32*row +: 32] = accumulator[row];
        end
    endgenerate

    integer r, c;
    always @* begin
        for (r = 0; r < 8; r = r + 1) begin
            row_sum[r] = 0;
            for (c = 0; c < 4; c = c + 1)
                row_sum[r] = row_sum[r] + $signed(partial_sum[r*4+c]);
        end
    end

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_out <= 1'b0;
            valid_pipe <= 1'b0;
            first_pipe <= 1'b0;
            valid_sum <= 1'b0;
            first_sum <= 1'b0;
            weight_pipe <= 0;
            input_pipe <= 0;
            for (i = 0; i < 32; i = i + 1)
                partial_sum[i] <= 0;
            for (i = 0; i < 8; i = i + 1)
                accumulator[i] <= 0;
        end else begin
            valid_pipe <= valid_in;
            first_pipe <= first_in;
            if (valid_in) begin
                weight_pipe <= weight_subtile;
                input_pipe <= input_subtile;
            end
            valid_sum <= valid_pipe;
            first_sum <= first_pipe;
            if (valid_pipe)
                for (i = 0; i < 32; i = i + 1)
                    partial_sum[i] <=
                        $signed(product[(i/4)*16+(i%4)*4+0])
                      + $signed(product[(i/4)*16+(i%4)*4+1])
                      + $signed(product[(i/4)*16+(i%4)*4+2])
                      + $signed(product[(i/4)*16+(i%4)*4+3]);
            valid_out <= valid_sum;
            if (clear) begin
                valid_out <= 1'b0;
                valid_pipe <= 1'b0;
                valid_sum <= 1'b0;
                for (i = 0; i < 8; i = i + 1)
                    accumulator[i] <= 0;
            end else if (valid_sum) begin
                for (i = 0; i < 8; i = i + 1)
                    accumulator[i] <= first_sum
                        ? row_sum[i] : accumulator[i] + row_sum[i];
            end
        end
    end
endmodule
