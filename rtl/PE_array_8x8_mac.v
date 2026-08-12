`timescale 1ns / 1ps

// Physical 8x8 MAC datapath. One cycle consumes one 8x8 weight subtile and
// one 8-element input subtile. Four accumulate cycles complete eight logical
// outputs for a 32-element input vector.
module PE_array_8x8_mac (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    clear,
    input  wire                    valid_in,
    input  wire signed [8*64-1:0]  weight_subtile,
    input  wire signed [8*8-1:0]   input_subtile,
    output reg                     valid_out,
    output wire signed [32*8-1:0]  result
);
    wire signed [15:0] product [0:63];
    reg  signed [31:0] row_sum [0:7];
    reg  signed [31:0] accumulator [0:7];

    genvar row, col;
    generate
        for (row = 0; row < 8; row = row + 1) begin : gen_row
            for (col = 0; col < 8; col = col + 1) begin : gen_col
                (* use_dsp = "yes" *)
                wire signed [7:0] w;
                wire signed [7:0] x;
                assign w = weight_subtile[8*(row*8+col) +: 8];
                assign x = input_subtile[8*col +: 8];
                assign product[row*8+col] = w * x;
            end
            assign result[32*row +: 32] = accumulator[row];
        end
    endgenerate

    integer r, c;
    always @* begin
        for (r = 0; r < 8; r = r + 1) begin
            row_sum[r] = 0;
            for (c = 0; c < 8; c = c + 1)
                row_sum[r] = row_sum[r] + $signed(product[r*8+c]);
        end
    end

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            valid_out <= 1'b0;
            for (i = 0; i < 8; i = i + 1)
                accumulator[i] <= 0;
        end else begin
            valid_out <= valid_in;
            if (clear) begin
                for (i = 0; i < 8; i = i + 1)
                    accumulator[i] <= 0;
                valid_out <= 1'b0;
            end else if (valid_in) begin
                for (i = 0; i < 8; i = i + 1)
                    accumulator[i] <= accumulator[i] + row_sum[i];
            end
        end
    end
endmodule
