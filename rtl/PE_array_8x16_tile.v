`timescale 1ns / 1ps

// Compatibility controller: maps one logical 32x32 tile onto the physical
// 8x16 MAC. The packed vectors are retained for bit-exact wrapper verification;
// the board version will replace this selection boundary with banked BRAM.
module PE_array_8x16_tile (
    input  wire                      clk,
    input  wire                      rst,
    input  wire                      start,
    input  wire signed [8*1024-1:0]  weight,
    input  wire signed [8*32-1:0]    in,
    output reg                       busy,
    output reg                       done,
    output reg signed [32*32-1:0]    final_out
);
    reg [1:0] output_subtile;
    reg       input_subtile;
    reg [2:0] phase;
    wire      mac_valid;
    wire      mac_first;
    reg [8*128-1:0] weight_slice;
    reg [8*16-1:0] input_slice;
    wire mac_valid_out;
    wire signed [32*8-1:0] mac_result;

    PE_array_8x16_mac mac (
        .clk(clk), .rst(rst), .clear(1'b0),
        .first_in(mac_first), .valid_in(mac_valid),
        .weight_subtile(weight_slice), .input_subtile(input_slice),
        .valid_out(mac_valid_out), .result(mac_result)
    );

    assign mac_valid = busy && (phase < 2);
    assign mac_first = (phase == 0);

    integer r;
    always @* begin
        // Keep every source range constant.  Arithmetic part-selects driven by
        // output_subtile/input_subtile make Vivado build and optimize a very
        // large 8192-to-1024-bit mux.  This explicit eight-way bank mux has the
        // same bit mapping while keeping the synthesis structure bounded.
        input_slice = input_subtile ? in[128 +: 128] : in[0 +: 128];
        weight_slice = 0;
        case ({output_subtile, input_subtile})
            3'd0: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*r +: 128];
            3'd1: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*r+128 +: 128];
            3'd2: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*(8+r) +: 128];
            3'd3: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*(8+r)+128 +: 128];
            3'd4: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*(16+r) +: 128];
            3'd5: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*(16+r)+128 +: 128];
            3'd6: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*(24+r) +: 128];
            default: for (r = 0; r < 8; r = r + 1)
                weight_slice[128*r +: 128] = weight[256*(24+r)+128 +: 128];
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            output_subtile <= 0;
            input_subtile <= 0;
            phase <= 0;
            busy <= 0;
            done <= 0;
            final_out <= 0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                output_subtile <= 0;
                input_subtile <= 0;
                phase <= 0;
                busy <= 1;
            end else if (busy) begin
                if (phase == 4) begin
                    case (output_subtile)
                        2'd0: final_out[0   +: 256] <= mac_result;
                        2'd1: final_out[256 +: 256] <= mac_result;
                        2'd2: final_out[512 +: 256] <= mac_result;
                        default: final_out[768 +: 256] <= mac_result;
                    endcase
                    if (output_subtile == 3) begin
                        busy <= 0;
                        done <= 1;
                    end else begin
                        output_subtile <= output_subtile + 1'b1;
                        input_subtile <= 0;
                        phase <= 0;
                    end
                end else begin
                    if (phase == 0) begin
                        input_subtile <= 1;
                        phase <= 1;
                    end else if (phase == 1) begin
                        phase <= 2;
                    end else if (phase == 2) begin
                        phase <= 3;
                    end else begin
                        // Input register plus registered four-product sums.
                        phase <= 4;
                    end
                end
            end
        end
    end
endmodule
