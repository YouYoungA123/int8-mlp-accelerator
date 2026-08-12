`timescale 1ns / 1ps

// AXU2CGB first-bring-up shell.
// The PS writes model/input data through AXI BRAM Controller port A. This
// module owns port B and converts the accelerator's simple read request into
// synchronous BRAM reads. Final INT32 outputs are written back into the same
// BRAM so that the PS can read them without a second output peripheral.
module mlp_board_core #(
    parameter [31:0] INPUT_BASE  = 32'h0000_0000,
    parameter [31:0] WEIGHT_BASE = 32'h0000_2000,
    parameter [31:0] BIAS_BASE   = 32'h0001_E000,
    parameter [31:0] OUTPUT_BASE = 32'h0001_F000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] control_word,
    output wire [31:0] status_word,
    output wire [31:0] checksum_word,

    output wire        bram_en,
    output wire [3:0]  bram_we,
    output wire [16:0] bram_addr,
    output wire [31:0] bram_din,
    input  wire [31:0] bram_dout
);
    localparam CTRL_IDLE  = 3'd0;
    localparam CTRL_INST  = 3'd1;
    localparam CTRL_WAIT1 = 3'd2;
    localparam CTRL_WAIT2 = 3'd3;
    localparam CTRL_START = 3'd4;
    localparam CTRL_RUN   = 3'd5;

    reg [2:0] ctrl_state;
    reg start_d;
    reg inst_valid;
    reg accel_start;
    reg done_sticky;
    reg busy_sticky;
    reg read_pending;
    reg [5:0] batch_latched;

    wire start_event = control_word[0] & ~start_d;
    wire [5:0] requested_batch =
        (control_word[6:1] == 0) ? 6'd1 : control_word[6:1];
    wire soft_reset = control_word[31];

    wire dram_req;
    wire [31:0] dram_addr;
    wire [31:0] checksum;
    wire [4:0] debug_state;
    wire accel_done;
    wire result_we;
    wire [10:0] result_addr;
    wire [31:0] result_data;

    wire [7:0] batch_instruction = {2'b00, batch_latched};
    wire [16:0] read_addr = dram_addr[16:0];
    wire [16:0] write_addr = OUTPUT_BASE[16:0] + {result_addr, 2'b00};

    assign bram_en = dram_req | result_we;
    assign bram_we = result_we ? 4'hf : 4'h0;
    assign bram_addr = result_we ? write_addr : read_addr;
    assign bram_din = result_data;

    assign status_word = {
        16'd0, batch_latched, debug_state, 2'd0, busy_sticky, done_sticky
    };
    assign checksum_word = checksum;

    PE_array_wrapper_fpga #(
        .DRAM_INPUT_BASE(INPUT_BASE),
        .DRAM_WEIGHT_BASE(WEIGHT_BASE),
        .DRAM_BIAS_BASE(BIAS_BASE)
    ) accelerator (
        .clk(clk),
        .rst(rst | soft_reset),
        .start(accel_start),
        .instruction(batch_instruction),
        .inst_valid(inst_valid),
        .dram_req(dram_req),
        .dram_addr(dram_addr),
        .dram_rdata(bram_dout),
        .dram_rvalid(read_pending),
        .result_checksum(checksum),
        .debug_state(debug_state),
        .result_we(result_we),
        .result_addr(result_addr),
        .result_data(result_data),
        .done(accel_done)
    );

    always @(posedge clk) begin
        if (rst | soft_reset) begin
            ctrl_state <= CTRL_IDLE;
            start_d <= 1'b0;
            inst_valid <= 1'b0;
            accel_start <= 1'b0;
            done_sticky <= 1'b0;
            busy_sticky <= 1'b0;
            read_pending <= 1'b0;
            batch_latched <= 6'd1;
        end else begin
            start_d <= control_word[0];
            read_pending <= dram_req & ~result_we;
            inst_valid <= 1'b0;
            accel_start <= 1'b0;

            case (ctrl_state)
                CTRL_IDLE: begin
                    if (start_event) begin
                        batch_latched <= requested_batch;
                        done_sticky <= 1'b0;
                        busy_sticky <= 1'b1;
                        ctrl_state <= CTRL_INST;
                    end
                end
                CTRL_INST: begin
                    inst_valid <= 1'b1;
                    ctrl_state <= CTRL_WAIT1;
                end
                CTRL_WAIT1: ctrl_state <= CTRL_WAIT2;
                CTRL_WAIT2: ctrl_state <= CTRL_START;
                CTRL_START: begin
                    accel_start <= 1'b1;
                    ctrl_state <= CTRL_RUN;
                end
                CTRL_RUN: begin
                    if (accel_done) begin
                        done_sticky <= 1'b1;
                        busy_sticky <= 1'b0;
                        ctrl_state <= CTRL_IDLE;
                    end
                end
                default: ctrl_state <= CTRL_IDLE;
            endcase
        end
    end
endmodule
