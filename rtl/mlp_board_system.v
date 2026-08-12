`timescale 1ns / 1ps

// Complete first-bring-up PL subsystem: a 128 KiB true-dual-port memory plus
// the MLP board core. Port A belongs to AXI BRAM Controller (PS access), while
// port B is private to the accelerator.
module mlp_board_system (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] control_word,
    output wire [31:0] status_word,
    output wire [31:0] checksum_word,

    input  wire        ps_bram_clk,
    input  wire        ps_bram_rst,
    input  wire        ps_bram_en,
    input  wire [3:0]  ps_bram_we,
    input  wire [16:0] ps_bram_addr,
    input  wire [31:0] ps_bram_din,
    output reg  [31:0] ps_bram_dout
);
    (* ram_style = "block" *) reg [31:0] memory [0:32767];

    wire        mlp_bram_en;
    wire [3:0]  mlp_bram_we;
    wire [16:0] mlp_bram_addr;
    wire [31:0] mlp_bram_din;
    reg  [31:0] mlp_bram_dout;

    integer byte_lane;
    always @(posedge ps_bram_clk) begin
        if (ps_bram_en) begin
            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1)
                if (ps_bram_we[byte_lane])
                    memory[ps_bram_addr[16:2]][8*byte_lane +: 8]
                        <= ps_bram_din[8*byte_lane +: 8];
            ps_bram_dout <= memory[ps_bram_addr[16:2]];
        end
        if (ps_bram_rst)
            ps_bram_dout <= 32'd0;
    end

    always @(posedge clk) begin
        if (mlp_bram_en) begin
            if (|mlp_bram_we)
                memory[mlp_bram_addr[16:2]] <= mlp_bram_din;
            mlp_bram_dout <= memory[mlp_bram_addr[16:2]];
        end
        if (rst)
            mlp_bram_dout <= 32'd0;
    end

    mlp_board_core core (
        .clk(clk), .rst(rst),
        .control_word(control_word),
        .status_word(status_word),
        .checksum_word(checksum_word),
        .bram_en(mlp_bram_en),
        .bram_we(mlp_bram_we),
        .bram_addr(mlp_bram_addr),
        .bram_din(mlp_bram_din),
        .bram_dout(mlp_bram_dout)
    );
endmodule
