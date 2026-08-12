(* black_box = "true" *)
module design_1_mlp_board_system_0_1 (
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
    output wire [31:0] ps_bram_dout
);
endmodule
