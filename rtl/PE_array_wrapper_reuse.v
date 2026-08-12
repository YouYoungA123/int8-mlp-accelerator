`timescale 1ns / 1ps

// Batch-tiled weight-reuse version of the A/B/S three-buffer wrapper.
//
// A/B keep their original ping-pong role, but each bank now stores a complete
// batch tile instead of one sample.  For the active tile the layer flow is:
//
//   Layer 1 : active A/B -> S
//   Layer 2 : S          -> active A/B
//   Layer 3 : active A/B -> output SRAM
//
// On the first start, the DMA loads all weights and biases from DRAM before it
// fetches the first input tile. Each dram_req starts a fixed-length burst of
// DMA_BURST_WORDS consecutive 32-bit response beats. After model setup, one
// activation bank can be computed while the DMA fills the inactive bank.
// Within each layer a 32x32 weight tile is read from the on-chip weight SRAM
// only once and reused for every sample in the active batch tile.
module PE_array_wrapper_reuse #(
    parameter integer L1_INPUT_GROUPS   = 25,
    parameter integer L1_OUTPUT_GROUPS  = 4,
    parameter integer L2_INPUT_GROUPS   = 4,
    parameter integer L2_OUTPUT_GROUPS  = 2,
    parameter integer L3_INPUT_GROUPS   = 2,
    parameter integer L3_OUTPUT_GROUPS  = 1,
    parameter integer BATCH_TILE        = 4,
    parameter integer DMA_BURST_WORDS   = 8,
    parameter integer REQUANT_SHIFT     = 8,
    parameter [31:0]  DRAM_INPUT_BASE   = 32'h0000_0000,
    parameter [31:0]  DRAM_WEIGHT_BASE  = 32'h0010_0000,
    parameter [31:0]  DRAM_BIAS_BASE    = 32'h0020_0000,
    parameter integer ACT_WORD_DEPTH    = 1024,
    parameter integer ACT_ADDR_W        = 10,
    parameter integer WEIGHT_WORD_DEPTH = 32768,
    parameter integer BIAS_DEPTH        = 256,
    parameter integer OUTPUT_DEPTH      = 2048
)(
    input             clk,
    input             start,
    input             rst,
    input      [7:0]  instruction,
    input             inst_valid,

    output reg        dram_req,
    output reg [31:0] dram_addr,
    input      [31:0] dram_rdata,
    input             dram_rvalid,

    output     [31:0] result_checksum,
    output     [4:0]  debug_state,
    output reg        done
);

localparam [4:0] IDLE           = 5'd0;
localparam [4:0] FETCH          = 5'd1;
localparam [4:0] DECODE         = 5'd2;
localparam [4:0] WAIT_TILE      = 5'd3;
localparam [4:0] LOAD_WEIGHT    = 5'd4;
localparam [4:0] LOAD_PE        = 5'd5;
localparam [4:0] LOAD_INPUT     = 5'd6;
localparam [4:0] COMPUTE        = 5'd7;
localparam [4:0] ACCUMULATE     = 5'd8;
localparam [4:0] LOAD_BIAS_ADDR = 5'd9;
localparam [4:0] LOAD_BIAS_WAIT = 5'd10;
localparam [4:0] WRITE_RESULT   = 5'd11;
localparam [4:0] GROUP_DONE     = 5'd12;
localparam [4:0] LAYER_DONE     = 5'd13;
localparam [4:0] TILE_DONE      = 5'd14;
localparam [4:0] REAL_DONE      = 5'd15;
localparam [4:0] WAIT_MODEL     = 5'd16;

localparam [1:0] DMA_IDLE = 2'd0;
localparam [1:0] DMA_REQ  = 2'd1;
localparam [1:0] DMA_WAIT = 2'd2;

localparam [1:0] DMA_INPUT  = 2'd0;
localparam [1:0] DMA_WEIGHT = 2'd1;
localparam [1:0] DMA_BIAS   = 2'd2;

localparam [1:0] INST_BATCH  = 2'b00;
localparam [1:0] INST_INPUT  = 2'b01;
localparam [1:0] INST_OUTPUT = 2'b10;

localparam integer L1_WEIGHT_BASE = 0;
localparam integer L2_WEIGHT_BASE =
    L1_INPUT_GROUPS * L1_OUTPUT_GROUPS * 256;
localparam integer L3_WEIGHT_BASE = L2_WEIGHT_BASE
    + L2_INPUT_GROUPS * L2_OUTPUT_GROUPS * 256;
localparam integer L1_BIAS_BASE = 0;
localparam integer L2_BIAS_BASE = L1_OUTPUT_GROUPS * 32;
localparam integer L3_BIAS_BASE = L2_BIAS_BASE + L2_OUTPUT_GROUPS * 32;

localparam integer L1_INPUT_WORDS  = L1_INPUT_GROUPS * 8;
localparam integer L1_OUTPUT_WORDS = L1_OUTPUT_GROUPS * 8;
localparam integer L2_OUTPUT_WORDS = L2_OUTPUT_GROUPS * 8;
localparam integer TOTAL_WEIGHT_WORDS =
    (L1_INPUT_GROUPS * L1_OUTPUT_GROUPS
   + L2_INPUT_GROUPS * L2_OUTPUT_GROUPS
   + L3_INPUT_GROUPS * L3_OUTPUT_GROUPS) * 256;
localparam integer TOTAL_BIAS_WORDS =
    (L1_OUTPUT_GROUPS + L2_OUTPUT_GROUPS + L3_OUTPUT_GROUPS) * 32;
localparam integer DMA_BURST_CNT_W =
    (DMA_BURST_WORDS <= 1) ? 1 : $clog2(DMA_BURST_WORDS);

reg [4:0] state;
reg [1:0] dma_state;
reg [1:0] dma_mode;
reg [DMA_BURST_CNT_W-1:0] dma_burst_word_cnt;
reg       model_loaded;
assign debug_state = state;

reg [7:0] inst_reg;
reg [5:0] batch_size;
reg [5:0] programmed_input_groups;
reg [5:0] programmed_output_groups;

reg [1:0] layer_cnt;
reg [5:0] input_group_num;
reg [5:0] output_group_num;
reg [5:0] input_group_cnt;
reg [5:0] output_group_cnt;
reg [5:0] output_cnt;

reg [5:0] tile_base_sample;
reg [2:0] tile_sample_count;
reg [2:0] batch_in_tile;
reg [2:0] write_batch;
reg       active_buf_sel;
reg       buf_a_ready;
reg       buf_b_ready;

reg       dma_target_sel;
reg [5:0] dma_base_sample;
reg [2:0] dma_sample_count;
reg [14:0] dma_word_cnt;

reg act_a_we, act_b_we, act_s_we;
reg [ACT_ADDR_W-1:0] act_a_addr, act_b_addr, act_s_addr;
reg [31:0] act_a_data_in, act_b_data_in, act_s_data_in;
wire [31:0] act_a_data_out, act_b_data_out, act_s_data_out;

reg weight_we, bias_we, output_we;
reg [14:0] weight_addr;
reg [31:0] weight_data_in;
wire [31:0] weight_data_out;
reg [7:0] bias_addr;
reg [31:0] bias_data_in;
wire [31:0] bias_data_out;
reg [10:0] output_addr;
reg [31:0] output_data_in;
wire [31:0] output_data_out;

reg weight_load;
reg [8*32-1:0] in_vec;
reg [8*1024-1:0] weight_vec;
wire [32*32-1:0] final_out;

reg [8:0] weight_word_cnt;
reg [3:0] input_word_cnt;
reg [8:0] weight_index_d1, weight_index_d2;
reg [3:0] input_index_d1, input_index_d2;
reg weight_valid_d1, weight_valid_d2;
reg input_valid_d1, input_valid_d2;

reg signed [31:0] accum [0:BATCH_TILE-1][0:31];
reg [23:0] activation_pack;
reg signed [31:0] biased_value;
reg signed [7:0] quantized_value;
reg [31:0] result_checksum_reg;
integer i;
integer j;
integer b;

function signed [7:0] requantize_relu;
    input signed [31:0] value;
    reg signed [31:0] scaled;
    begin
        scaled = value >>> REQUANT_SHIFT;
        if (scaled < 0)
            requantize_relu = 8'sd0;
        else if (scaled > 127)
            requantize_relu = 8'sd127;
        else
            requantize_relu = scaled[7:0];
    end
endfunction

function [2:0] samples_in_tile;
    input [5:0] base_sample;
    reg [6:0] remaining;
    begin
        remaining = batch_size - base_sample;
        if (remaining >= BATCH_TILE)
            samples_in_tile = BATCH_TILE;
        else
            samples_in_tile = remaining[2:0];
    end
endfunction

function [5:0] layer_input_groups;
    input [1:0] layer;
    begin
        case (layer)
            2'd0: layer_input_groups = L1_INPUT_GROUPS;
            2'd1: layer_input_groups = L2_INPUT_GROUPS;
            default: layer_input_groups = L3_INPUT_GROUPS;
        endcase
    end
endfunction

function [5:0] layer_output_groups;
    input [1:0] layer;
    begin
        case (layer)
            2'd0: layer_output_groups = L1_OUTPUT_GROUPS;
            2'd1: layer_output_groups = L2_OUTPUT_GROUPS;
            default: layer_output_groups = L3_OUTPUT_GROUPS;
        endcase
    end
endfunction

function [14:0] layer_weight_base;
    input [1:0] layer;
    begin
        case (layer)
            2'd0: layer_weight_base = L1_WEIGHT_BASE;
            2'd1: layer_weight_base = L2_WEIGHT_BASE;
            default: layer_weight_base = L3_WEIGHT_BASE;
        endcase
    end
endfunction

function [7:0] layer_bias_base;
    input [1:0] layer;
    begin
        case (layer)
            2'd0: layer_bias_base = L1_BIAS_BASE;
            2'd1: layer_bias_base = L2_BIAS_BASE;
            default: layer_bias_base = L3_BIAS_BASE;
        endcase
    end
endfunction

function [ACT_ADDR_W-1:0] source_word_address;
    input [1:0] layer;
    input [2:0] batch_index;
    input [5:0] input_group;
    input [3:0] word_index;
    begin
        case (layer)
            2'd0: source_word_address =
                batch_index * L1_INPUT_WORDS + input_group * 8 + word_index;
            2'd1: source_word_address =
                batch_index * L1_OUTPUT_WORDS + input_group * 8 + word_index;
            default: source_word_address =
                batch_index * L2_OUTPUT_WORDS + input_group * 8 + word_index;
        endcase
    end
endfunction

always @(*) begin
    result_checksum_reg = 32'd0;
    for (j = 0; j < 32; j = j + 1)
        result_checksum_reg = result_checksum_reg ^ final_out[32*j +: 32];
end
assign result_checksum = result_checksum_reg;

SRAM_module #(.data_w(32), .depth(ACT_WORD_DEPTH), .addr_w(ACT_ADDR_W)) activation_a(
    .clk(clk), .we(act_a_we), .addr(act_a_addr),
    .data_in(act_a_data_in), .data_out(act_a_data_out));
SRAM_module #(.data_w(32), .depth(ACT_WORD_DEPTH), .addr_w(ACT_ADDR_W)) activation_b(
    .clk(clk), .we(act_b_we), .addr(act_b_addr),
    .data_in(act_b_data_in), .data_out(act_b_data_out));
SRAM_module #(.data_w(32), .depth(ACT_WORD_DEPTH), .addr_w(ACT_ADDR_W)) activation_s(
    .clk(clk), .we(act_s_we), .addr(act_s_addr),
    .data_in(act_s_data_in), .data_out(act_s_data_out));
SRAM_module #(.data_w(32), .depth(WEIGHT_WORD_DEPTH), .addr_w(15)) weight_sram(
    .clk(clk), .we(weight_we), .addr(weight_addr),
    .data_in(weight_data_in), .data_out(weight_data_out));
SRAM_module #(.data_w(32), .depth(BIAS_DEPTH), .addr_w(8)) bias_sram(
    .clk(clk), .we(bias_we), .addr(bias_addr),
    .data_in(bias_data_in), .data_out(bias_data_out));
SRAM_module #(.data_w(32), .depth(OUTPUT_DEPTH), .addr_w(11)) output_sram(
    .clk(clk), .we(output_we), .addr(output_addr),
    .data_in(output_data_in), .data_out(output_data_out));

PE_array_32 UUT(
    .rst(rst), .clk(clk), .weight_load(weight_load),
    .weight(weight_vec), .in(in_vec), .final_out(final_out));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= IDLE;
        dma_state <= DMA_IDLE;
        dma_mode <= DMA_INPUT;
        dma_burst_word_cnt <= 0;
        model_loaded <= 1'b0;
        done <= 1'b0;
        dram_req <= 1'b0;
        dram_addr <= DRAM_INPUT_BASE;
        inst_reg <= 0;
        batch_size <= BATCH_TILE;
        programmed_input_groups <= 0;
        programmed_output_groups <= 0;
        layer_cnt <= 0;
        input_group_num <= L1_INPUT_GROUPS;
        output_group_num <= L1_OUTPUT_GROUPS;
        input_group_cnt <= 0;
        output_group_cnt <= 0;
        output_cnt <= 0;
        tile_base_sample <= 0;
        tile_sample_count <= 0;
        batch_in_tile <= 0;
        write_batch <= 0;
        active_buf_sel <= 0;
        buf_a_ready <= 0;
        buf_b_ready <= 0;
        dma_target_sel <= 0;
        dma_base_sample <= 0;
        dma_sample_count <= 0;
        dma_word_cnt <= 0;
        act_a_we <= 0;
        act_b_we <= 0;
        act_s_we <= 0;
        act_a_addr <= 0;
        act_b_addr <= 0;
        act_s_addr <= 0;
        act_a_data_in <= 0;
        act_b_data_in <= 0;
        act_s_data_in <= 0;
        weight_we <= 0;
        bias_we <= 0;
        output_we <= 0;
        weight_addr <= 0;
        bias_addr <= 0;
        output_addr <= 0;
        weight_data_in <= 0;
        bias_data_in <= 0;
        output_data_in <= 0;
        weight_load <= 0;
        in_vec <= 0;
        weight_vec <= 0;
        weight_word_cnt <= 0;
        input_word_cnt <= 0;
        weight_index_d1 <= 0;
        weight_index_d2 <= 0;
        input_index_d1 <= 0;
        input_index_d2 <= 0;
        weight_valid_d1 <= 0;
        weight_valid_d2 <= 0;
        input_valid_d1 <= 0;
        input_valid_d2 <= 0;
        activation_pack <= 0;
        biased_value <= 0;
        quantized_value <= 0;
        for (b = 0; b < BATCH_TILE; b = b + 1)
            for (i = 0; i < 32; i = i + 1)
                accum[b][i] <= 0;
    end else begin
        done <= 1'b0;
        dram_req <= 1'b0;
        act_a_we <= 1'b0;
        act_b_we <= 1'b0;
        act_s_we <= 1'b0;
        weight_we <= 1'b0;
        bias_we <= 1'b0;
        output_we <= 1'b0;
        weight_load <= 1'b0;

        case (dma_state)
            DMA_IDLE: begin end
            DMA_REQ: begin
                dram_req <= 1'b1;
                case (dma_mode)
                    DMA_WEIGHT: dram_addr <= DRAM_WEIGHT_BASE
                        + (dma_word_cnt * 4);
                    DMA_BIAS: dram_addr <= DRAM_BIAS_BASE
                        + (dma_word_cnt * 4);
                    default: dram_addr <= DRAM_INPUT_BASE
                        + ((dma_base_sample * L1_INPUT_WORDS
                            + dma_word_cnt) * 4);
                endcase
                dma_state <= DMA_WAIT;
            end
            DMA_WAIT: begin
                if (dram_rvalid) begin
                    case (dma_mode)
                        DMA_WEIGHT: begin
                            weight_we <= 1'b1;
                            weight_addr <= dma_word_cnt;
                            weight_data_in <= dram_rdata;
                        end
                        DMA_BIAS: begin
                            bias_we <= 1'b1;
                            bias_addr <= dma_word_cnt[7:0];
                            bias_data_in <= dram_rdata;
                        end
                        default: begin
                            if (dma_target_sel == 1'b0) begin
                                act_a_we <= 1'b1;
                                act_a_addr <= dma_word_cnt[ACT_ADDR_W-1:0];
                                act_a_data_in <= dram_rdata;
                            end else begin
                                act_b_we <= 1'b1;
                                act_b_addr <= dma_word_cnt[ACT_ADDR_W-1:0];
                                act_b_data_in <= dram_rdata;
                            end
                        end
                    endcase

                    if ((dma_mode == DMA_WEIGHT
                            && dma_word_cnt == TOTAL_WEIGHT_WORDS - 1)
                        || (dma_mode == DMA_BIAS
                            && dma_word_cnt == TOTAL_BIAS_WORDS - 1)
                        || (dma_mode == DMA_INPUT
                            && dma_word_cnt ==
                                dma_sample_count * L1_INPUT_WORDS - 1)) begin
                        dma_word_cnt <= 0;
                        dma_burst_word_cnt <= 0;

                        if (dma_mode == DMA_WEIGHT) begin
                            dma_mode <= DMA_BIAS;
                            dma_state <= DMA_REQ;
                        end else if (dma_mode == DMA_BIAS) begin
                            model_loaded <= 1'b1;
                            dma_state <= DMA_IDLE;
                        end else begin
                            if (dma_target_sel == 1'b0)
                                buf_a_ready <= 1'b1;
                            else
                                buf_b_ready <= 1'b1;
                            dma_state <= DMA_IDLE;
                        end
                    end else begin
                        dma_word_cnt <= dma_word_cnt + 1'b1;
                        if (dma_burst_word_cnt == DMA_BURST_WORDS - 1) begin
                            dma_burst_word_cnt <= 0;
                            dma_state <= DMA_REQ;
                        end else begin
                            dma_burst_word_cnt <= dma_burst_word_cnt + 1'b1;
                        end
                    end
                end
            end
            default: dma_state <= DMA_IDLE;
        endcase

        case (state)
            IDLE: begin
                if (inst_valid) begin
                    inst_reg <= instruction;
                    state <= FETCH;
                end else if (start) begin
                    tile_base_sample <= 0;
                    active_buf_sel <= 0;
                    buf_a_ready <= 0;
                    buf_b_ready <= 0;
                    dma_word_cnt <= 0;
                    dma_burst_word_cnt <= 0;
                    if (!model_loaded) begin
                        dma_mode <= DMA_WEIGHT;
                        dma_state <= DMA_REQ;
                        state <= WAIT_MODEL;
                    end else begin
                        dma_mode <= DMA_INPUT;
                        dma_target_sel <= 0;
                        dma_base_sample <= 0;
                        dma_sample_count <= samples_in_tile(0);
                        dma_state <= DMA_REQ;
                        state <= WAIT_TILE;
                    end
                end
            end

            WAIT_MODEL: begin
                if (model_loaded && dma_state == DMA_IDLE) begin
                    dma_mode <= DMA_INPUT;
                    dma_target_sel <= 0;
                    dma_base_sample <= 0;
                    dma_sample_count <= samples_in_tile(0);
                    dma_word_cnt <= 0;
                    dma_burst_word_cnt <= 0;
                    dma_state <= DMA_REQ;
                    state <= WAIT_TILE;
                end
            end

            FETCH: state <= DECODE;

            DECODE: begin
                case (inst_reg[7:6])
                    INST_BATCH: batch_size <= inst_reg[5:0];
                    INST_INPUT: programmed_input_groups <= inst_reg[5:0];
                    INST_OUTPUT: programmed_output_groups <= inst_reg[5:0];
                    default: begin end
                endcase
                state <= IDLE;
            end

            WAIT_TILE: begin
                if ((!active_buf_sel && buf_a_ready) ||
                    ( active_buf_sel && buf_b_ready)) begin
                    tile_sample_count <= samples_in_tile(tile_base_sample);
                    if (active_buf_sel)
                        buf_b_ready <= 1'b0;
                    else
                        buf_a_ready <= 1'b0;

                    layer_cnt <= 0;
                    input_group_num <= L1_INPUT_GROUPS;
                    output_group_num <= L1_OUTPUT_GROUPS;
                    input_group_cnt <= 0;
                    output_group_cnt <= 0;
                    batch_in_tile <= 0;
                    weight_word_cnt <= 0;
                    weight_valid_d1 <= 0;
                    weight_valid_d2 <= 0;
                    for (b = 0; b < BATCH_TILE; b = b + 1)
                        for (i = 0; i < 32; i = i + 1)
                            accum[b][i] <= 0;
                    state <= LOAD_WEIGHT;

                    if ((tile_base_sample + samples_in_tile(tile_base_sample) < batch_size)
                        && dma_state == DMA_IDLE) begin
                        dma_target_sel <= ~active_buf_sel;
                        dma_base_sample <=
                            tile_base_sample + samples_in_tile(tile_base_sample);
                        dma_sample_count <= samples_in_tile(
                            tile_base_sample + samples_in_tile(tile_base_sample));
                        dma_word_cnt <= 0;
                        dma_burst_word_cnt <= 0;
                        dma_mode <= DMA_INPUT;
                        dma_state <= DMA_REQ;
                    end
                end
            end

            LOAD_WEIGHT: begin
                if (weight_word_cnt < 256) begin
                    weight_addr <= layer_weight_base(layer_cnt)
                        + output_group_cnt * input_group_num * 256
                        + input_group_cnt * 256
                        + weight_word_cnt;
                    weight_index_d1 <= weight_word_cnt;
                    weight_valid_d1 <= 1'b1;
                    weight_word_cnt <= weight_word_cnt + 1'b1;
                end else begin
                    weight_valid_d1 <= 1'b0;
                end

                weight_valid_d2 <= weight_valid_d1;
                weight_index_d2 <= weight_index_d1;
                if (weight_valid_d2)
                    weight_vec[32*weight_index_d2 +: 32] <= weight_data_out;

                if (weight_valid_d2 && weight_index_d2 == 255)
                    state <= LOAD_PE;
            end

            LOAD_PE: begin
                weight_load <= 1'b1;
                input_word_cnt <= 0;
                input_valid_d1 <= 0;
                input_valid_d2 <= 0;
                state <= LOAD_INPUT;
            end

            LOAD_INPUT: begin
                if (input_word_cnt < 8) begin
                    if (layer_cnt == 1)
                        act_s_addr <= source_word_address(
                            layer_cnt, batch_in_tile, input_group_cnt, input_word_cnt);
                    else if (active_buf_sel == 0)
                        act_a_addr <= source_word_address(
                            layer_cnt, batch_in_tile, input_group_cnt, input_word_cnt);
                    else
                        act_b_addr <= source_word_address(
                            layer_cnt, batch_in_tile, input_group_cnt, input_word_cnt);
                    input_index_d1 <= input_word_cnt;
                    input_valid_d1 <= 1'b1;
                    input_word_cnt <= input_word_cnt + 1'b1;
                end else begin
                    input_valid_d1 <= 1'b0;
                end

                input_valid_d2 <= input_valid_d1;
                input_index_d2 <= input_index_d1;
                if (input_valid_d2) begin
                    if (layer_cnt == 1)
                        in_vec[32*input_index_d2 +: 32] <= act_s_data_out;
                    else if (active_buf_sel == 0)
                        in_vec[32*input_index_d2 +: 32] <= act_a_data_out;
                    else
                        in_vec[32*input_index_d2 +: 32] <= act_b_data_out;
                end

                if (input_valid_d2 && input_index_d2 == 7)
                    state <= COMPUTE;
            end

            COMPUTE: state <= ACCUMULATE;

            ACCUMULATE: begin
                for (i = 0; i < 32; i = i + 1)
                    accum[batch_in_tile][i] <=
                        accum[batch_in_tile][i] + $signed(final_out[32*i +: 32]);

                if (batch_in_tile + 1 < tile_sample_count) begin
                    batch_in_tile <= batch_in_tile + 1'b1;
                    input_word_cnt <= 0;
                    input_valid_d1 <= 0;
                    input_valid_d2 <= 0;
                    state <= LOAD_INPUT;
                end else if (input_group_cnt + 1 < input_group_num) begin
                    input_group_cnt <= input_group_cnt + 1'b1;
                    batch_in_tile <= 0;
                    weight_word_cnt <= 0;
                    weight_valid_d1 <= 0;
                    weight_valid_d2 <= 0;
                    state <= LOAD_WEIGHT;
                end else begin
                    write_batch <= 0;
                    output_cnt <= 0;
                    activation_pack <= 0;
                    state <= LOAD_BIAS_ADDR;
                end
            end

            LOAD_BIAS_ADDR: begin
                bias_addr <= layer_bias_base(layer_cnt)
                    + output_group_cnt * 32 + output_cnt;
                state <= LOAD_BIAS_WAIT;
            end

            LOAD_BIAS_WAIT: state <= WRITE_RESULT;

            WRITE_RESULT: begin
                biased_value = $signed(accum[write_batch][output_cnt])
                    + $signed(bias_data_out);
                quantized_value = requantize_relu(biased_value);

                if (layer_cnt == 2) begin
                    output_we <= 1'b1;
                    output_addr <= (tile_base_sample + write_batch)
                        * L3_OUTPUT_GROUPS * 32
                        + output_group_cnt * 32 + output_cnt;
                    output_data_in <= biased_value;
                end else begin
                    case (output_cnt[1:0])
                        2'd0: activation_pack[7:0] <= quantized_value;
                        2'd1: activation_pack[15:8] <= quantized_value;
                        2'd2: activation_pack[23:16] <= quantized_value;
                        2'd3: begin
                            if (layer_cnt == 0) begin
                                act_s_we <= 1'b1;
                                act_s_addr <= write_batch * L1_OUTPUT_WORDS
                                    + output_group_cnt * 8 + output_cnt[4:2];
                                act_s_data_in <= {quantized_value, activation_pack};
                            end else if (active_buf_sel == 0) begin
                                act_a_we <= 1'b1;
                                act_a_addr <= write_batch * L2_OUTPUT_WORDS
                                    + output_group_cnt * 8 + output_cnt[4:2];
                                act_a_data_in <= {quantized_value, activation_pack};
                            end else begin
                                act_b_we <= 1'b1;
                                act_b_addr <= write_batch * L2_OUTPUT_WORDS
                                    + output_group_cnt * 8 + output_cnt[4:2];
                                act_b_data_in <= {quantized_value, activation_pack};
                            end
                        end
                    endcase
                end

                if (output_cnt == 31) begin
                    if (write_batch + 1 < tile_sample_count) begin
                        write_batch <= write_batch + 1'b1;
                        output_cnt <= 0;
                        activation_pack <= 0;
                        state <= LOAD_BIAS_ADDR;
                    end else begin
                        output_cnt <= 0;
                        state <= GROUP_DONE;
                    end
                end else begin
                    output_cnt <= output_cnt + 1'b1;
                    state <= LOAD_BIAS_ADDR;
                end
            end

            GROUP_DONE: begin
                if (output_group_cnt + 1 < output_group_num) begin
                    output_group_cnt <= output_group_cnt + 1'b1;
                    input_group_cnt <= 0;
                    batch_in_tile <= 0;
                    weight_word_cnt <= 0;
                    weight_valid_d1 <= 0;
                    weight_valid_d2 <= 0;
                    for (b = 0; b < BATCH_TILE; b = b + 1)
                        for (i = 0; i < 32; i = i + 1)
                            accum[b][i] <= 0;
                    state <= LOAD_WEIGHT;
                end else begin
                    state <= LAYER_DONE;
                end
            end

            LAYER_DONE: begin
                if (layer_cnt == 2) begin
                    state <= TILE_DONE;
                end else begin
                    layer_cnt <= layer_cnt + 1'b1;
                    input_group_num <= layer_input_groups(layer_cnt + 1'b1);
                    output_group_num <= layer_output_groups(layer_cnt + 1'b1);
                    input_group_cnt <= 0;
                    output_group_cnt <= 0;
                    batch_in_tile <= 0;
                    weight_word_cnt <= 0;
                    weight_valid_d1 <= 0;
                    weight_valid_d2 <= 0;
                    for (b = 0; b < BATCH_TILE; b = b + 1)
                        for (i = 0; i < 32; i = i + 1)
                            accum[b][i] <= 0;
                    state <= LOAD_WEIGHT;
                end
            end

            TILE_DONE: begin
                if (tile_base_sample + tile_sample_count >= batch_size) begin
                    state <= REAL_DONE;
                end else begin
                    tile_base_sample <= tile_base_sample + tile_sample_count;
                    active_buf_sel <= ~active_buf_sel;
                    state <= WAIT_TILE;
                end
            end

            REAL_DONE: begin
                done <= 1'b1;
                state <= IDLE;
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
