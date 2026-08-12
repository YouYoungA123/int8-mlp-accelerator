`timescale 1ns / 1ps

// FPGA-fit implementation of one logical 32x32 INT8 matrix-vector tile.
//
// Only 8x8 = 64 multipliers exist physically.  The controller visits four
// input subtiles for each of four output subtiles, so one logical tile takes
// 16 active cycles.  The full weight and input vectors must remain stable
// from start until done.
module PE_array_8x8_serial (
    input  wire                      clk,
    input  wire                      rst,
    input  wire                      start,
    input  wire signed [8*1024-1:0]  weight,
    input  wire signed [8*32-1:0]    in,
    output reg                       busy,
    output reg                       done,
    output reg signed [32*32-1:0]    final_out
);

    reg [1:0] input_subtile;
    reg [1:0] output_subtile;
    reg signed [31:0] partial_sum [0:7];

    wire signed [15:0] product [0:63];
    reg  signed [31:0] row_sum [0:7];

    genvar row, col;
    generate
        for (row = 0; row < 8; row = row + 1) begin : gen_row
            for (col = 0; col < 8; col = col + 1) begin : gen_col
                // The attribute asks Vivado to map the signed multipliers to
                // DSP48 resources instead of building them from LUTs.
                (* use_dsp = "yes" *)
                wire signed [7:0] selected_weight;
                wire signed [7:0] selected_input;

                assign selected_weight = weight[
                    8 * (((output_subtile * 8) + row) * 32
                       + (input_subtile * 8) + col) +: 8];
                assign selected_input = in[
                    8 * ((input_subtile * 8) + col) +: 8];
                assign product[row*8+col] =
                    selected_weight * selected_input;
            end
        end
    endgenerate

    integer r, c;
    always @* begin
        for (r = 0; r < 8; r = r + 1) begin
            row_sum[r] = 32'sd0;
            for (c = 0; c < 8; c = c + 1)
                row_sum[r] = row_sum[r]
                    + $signed(product[r*8+c]);
        end
    end

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy            <= 1'b0;
            done            <= 1'b0;
            input_subtile   <= 2'd0;
            output_subtile  <= 2'd0;
            final_out       <= {32*32{1'b0}};
            for (i = 0; i < 8; i = i + 1)
                partial_sum[i] <= 32'sd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy           <= 1'b1;
                input_subtile  <= 2'd0;
                output_subtile <= 2'd0;
                for (i = 0; i < 8; i = i + 1)
                    partial_sum[i] <= 32'sd0;
            end else if (busy) begin
                for (i = 0; i < 8; i = i + 1) begin
                    if (input_subtile == 0)
                        partial_sum[i] <= row_sum[i];
                    else
                        partial_sum[i] <= partial_sum[i] + row_sum[i];

                    if (input_subtile == 3)
                        final_out[32*(output_subtile*8+i) +: 32]
                            <= partial_sum[i] + row_sum[i];
                end

                if (input_subtile == 3) begin
                    input_subtile <= 0;
                    if (output_subtile == 3) begin
                        output_subtile <= 0;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        output_subtile <= output_subtile + 1'b1;
                        for (i = 0; i < 8; i = i + 1)
                            partial_sum[i] <= 32'sd0;
                    end
                end else begin
                    input_subtile <= input_subtile + 1'b1;
                end
            end
        end
    end

endmodule
