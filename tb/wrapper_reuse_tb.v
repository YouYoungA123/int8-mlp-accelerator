`timescale 1ns / 1ps

`ifndef DATA_DIR
`define DATA_DIR "verification/generated"
`endif

module wrapper_reuse_tb;

localparam integer BATCH = 8;
localparam integer BATCH_TILE = 4;
localparam integer L1_INPUT_GROUPS = 25;
localparam integer L1_OUTPUT_GROUPS = 4;
localparam integer L2_INPUT_GROUPS = 4;
localparam integer L2_OUTPUT_GROUPS = 2;
localparam integer L3_INPUT_GROUPS = 2;
localparam integer L3_OUTPUT_GROUPS = 1;
localparam integer INPUT_WORDS = L1_INPUT_GROUPS * 8;
localparam integer TOTAL_INPUT_WORDS = BATCH * INPUT_WORDS;
localparam integer DMA_BURST_WORDS = 8;
localparam integer TOTAL_WEIGHT_WORDS =
      L1_INPUT_GROUPS * L1_OUTPUT_GROUPS * 256
    + L2_INPUT_GROUPS * L2_OUTPUT_GROUPS * 256
    + L3_INPUT_GROUPS * L3_OUTPUT_GROUPS * 256;
localparam integer TOTAL_BIAS_WORDS =
    (L1_OUTPUT_GROUPS + L2_OUTPUT_GROUPS + L3_OUTPUT_GROUPS) * 32;
localparam integer INPUT_DRAM_WORD_BASE = 0;
localparam integer WEIGHT_DRAM_WORD_BASE = TOTAL_INPUT_WORDS;
localparam integer BIAS_DRAM_WORD_BASE =
    WEIGHT_DRAM_WORD_BASE + TOTAL_WEIGHT_WORDS;
localparam integer TOTAL_DRAM_WORDS =
    BIAS_DRAM_WORD_BASE + TOTAL_BIAS_WORDS;
localparam integer TOTAL_OUTPUTS = BATCH * 32;
localparam integer L1_WORDS = L1_OUTPUT_GROUPS * 8;
localparam integer L2_WORDS = L2_OUTPUT_GROUPS * 8;
localparam integer EXPECTED_WEIGHT_LOADS_PER_TILE =
      L1_INPUT_GROUPS * L1_OUTPUT_GROUPS
    + L2_INPUT_GROUPS * L2_OUTPUT_GROUPS
    + L3_INPUT_GROUPS * L3_OUTPUT_GROUPS;
localparam integer EXPECTED_TILE_COUNT = (BATCH + BATCH_TILE - 1) / BATCH_TILE;
localparam integer EXPECTED_WEIGHT_LOADS =
    EXPECTED_WEIGHT_LOADS_PER_TILE * EXPECTED_TILE_COUNT;
localparam integer BASELINE_WEIGHT_LOADS =
    EXPECTED_WEIGHT_LOADS_PER_TILE * BATCH;
localparam integer TIMEOUT_CYCLES = 300000;

localparam [4:0] ST_WAIT_TILE      = 5'd3;
localparam [4:0] ST_LOAD_WEIGHT    = 5'd4;
localparam [4:0] ST_LOAD_PE        = 5'd5;
localparam [4:0] ST_LOAD_INPUT     = 5'd6;
localparam [4:0] ST_COMPUTE        = 5'd7;
localparam [4:0] ST_ACCUMULATE     = 5'd8;
localparam [4:0] ST_LOAD_BIAS_ADDR = 5'd9;
localparam [4:0] ST_LOAD_BIAS_WAIT = 5'd10;
localparam [4:0] ST_WRITE_RESULT   = 5'd11;
localparam [4:0] ST_GROUP_DONE     = 5'd12;
localparam [4:0] ST_LAYER_DONE     = 5'd13;
localparam [4:0] ST_TILE_DONE      = 5'd14;
localparam [4:0] ST_REAL_DONE      = 5'd15;

reg clk, rst, start;
reg [7:0] instruction;
reg inst_valid;
wire dram_req;
wire [31:0] dram_addr;
reg [31:0] dram_rdata;
reg dram_rvalid;
wire [31:0] result_checksum;
wire [4:0] debug_state;
wire done;

reg [31:0] mock_dram [0:TOTAL_DRAM_WORDS-1];
reg [31:0] golden_output [0:TOTAL_OUTPUTS-1];
reg [31:0] golden_activation1 [0:BATCH*L1_WORDS-1];
reg [31:0] golden_activation2 [0:BATCH*L2_WORDS-1];

integer state_cycles [0:31];
integer layer_cycles [0:2];
integer k, m, dram_index;
integer cycle_count, error_count, intermediate_errors;
integer intermediate_compares, weight_load_count;
integer dram_request_count, dma_busy_cycles, overlap_cycles;
integer output_write_count, active_bank_switches;
integer last_active_bank, golden_index, output_file;
reg profile_active;
reg burst_active;
integer burst_words_left;
integer burst_dram_index;

PE_array_wrapper_reuse #(
    .L1_INPUT_GROUPS(L1_INPUT_GROUPS),
    .L1_OUTPUT_GROUPS(L1_OUTPUT_GROUPS),
    .L2_INPUT_GROUPS(L2_INPUT_GROUPS),
    .L2_OUTPUT_GROUPS(L2_OUTPUT_GROUPS),
    .L3_INPUT_GROUPS(L3_INPUT_GROUPS),
    .L3_OUTPUT_GROUPS(L3_OUTPUT_GROUPS),
    .BATCH_TILE(BATCH_TILE),
    .DMA_BURST_WORDS(DMA_BURST_WORDS),
    .REQUANT_SHIFT(8),
    .DRAM_INPUT_BASE(INPUT_DRAM_WORD_BASE * 4),
    .DRAM_WEIGHT_BASE(WEIGHT_DRAM_WORD_BASE * 4),
    .DRAM_BIAS_BASE(BIAS_DRAM_WORD_BASE * 4),
    .ACT_WORD_DEPTH(1024),
    .ACT_ADDR_W(10),
    .OUTPUT_DEPTH(2048)
) uut (
    .clk(clk), .start(start), .rst(rst),
    .instruction(instruction), .inst_valid(inst_valid),
    .dram_req(dram_req), .dram_addr(dram_addr),
    .dram_rdata(dram_rdata), .dram_rvalid(dram_rvalid),
    .result_checksum(result_checksum),
    .debug_state(debug_state), .done(done)
);

always #5 clk = ~clk;

// Fixed 8-word burst DRAM model. One dram_req supplies eight consecutive
// 32-bit beats; dram_rvalid may be treated exactly like a per-beat valid.
always @(posedge clk) begin
    dram_rvalid <= 1'b0;

    if (!burst_active && dram_req) begin
        burst_active <= 1'b1;
        burst_words_left <= DMA_BURST_WORDS;
        burst_dram_index <= dram_addr >> 2;
    end else if (burst_active) begin
        dram_rvalid <= 1'b1;
        if (burst_dram_index >= 0 && burst_dram_index < TOTAL_DRAM_WORDS)
            dram_rdata <= mock_dram[burst_dram_index];
        else begin
            dram_rdata <= 32'hxxxx_xxxx;
            $display("DRAM RANGE ERROR index=%0d", burst_dram_index);
        end

        if (burst_words_left == 1) begin
            burst_active <= 1'b0;
            burst_words_left <= 0;
        end else begin
            burst_words_left <= burst_words_left - 1;
            burst_dram_index <= burst_dram_index + 1;
        end
    end
end

task send_batch_instruction;
    input [5:0] value;
    begin
        @(negedge clk); instruction = {2'b00, value}; inst_valid = 1'b1;
        @(negedge clk); inst_valid = 1'b0;
        repeat (3) @(negedge clk);
    end
endtask

always @(posedge clk) begin
    if (rst) begin
        profile_active <= 0;
        weight_load_count = 0;
        dram_request_count = 0;
        dma_busy_cycles = 0;
        overlap_cycles = 0;
        output_write_count = 0;
        active_bank_switches = 0;
        last_active_bank = 0;
        for (m = 0; m < 32; m = m + 1)
            state_cycles[m] = 0;
        for (m = 0; m < 3; m = m + 1)
            layer_cycles[m] = 0;
    end else begin
        if (start) begin
            profile_active <= 1;
            last_active_bank = uut.active_buf_sel;
        end

        if (profile_active && !done) begin
            state_cycles[debug_state] = state_cycles[debug_state] + 1;
            if (debug_state >= ST_LOAD_WEIGHT && debug_state <= ST_LAYER_DONE)
                layer_cycles[uut.layer_cnt] = layer_cycles[uut.layer_cnt] + 1;
            if (uut.weight_load)
                weight_load_count = weight_load_count + 1;
            if (dram_req)
                dram_request_count = dram_request_count + 1;
            if (uut.dma_state != 0)
                dma_busy_cycles = dma_busy_cycles + 1;
            if (uut.dma_state != 0 &&
                debug_state >= ST_LOAD_WEIGHT && debug_state <= ST_LAYER_DONE)
                overlap_cycles = overlap_cycles + 1;
            if (uut.output_we)
                output_write_count = output_write_count + 1;
            if (uut.active_buf_sel != last_active_bank) begin
                active_bank_switches = active_bank_switches + 1;
                last_active_bank = uut.active_buf_sel;
            end
        end

        if (profile_active && done)
            profile_active <= 0;
    end
end

// Check every intermediate batch tile before S or the active bank is reused.
always @(negedge clk) begin
    if (profile_active && debug_state == ST_LAYER_DONE) begin
        if (uut.layer_cnt == 0) begin
            for (m = 0; m < uut.tile_sample_count * L1_WORDS; m = m + 1) begin
                golden_index = uut.tile_base_sample * L1_WORDS + m;
                intermediate_compares = intermediate_compares + 1;
                if (uut.activation_s.mem[m] !== golden_activation1[golden_index]) begin
                    if (intermediate_errors < 20)
                        $display("L1 MISMATCH tile_base=%0d word=%0d RTL=%08h GOLD=%08h",
                            uut.tile_base_sample, m, uut.activation_s.mem[m],
                            golden_activation1[golden_index]);
                    intermediate_errors = intermediate_errors + 1;
                end
            end
        end else if (uut.layer_cnt == 1) begin
            for (m = 0; m < uut.tile_sample_count * L2_WORDS; m = m + 1) begin
                golden_index = uut.tile_base_sample * L2_WORDS + m;
                intermediate_compares = intermediate_compares + 1;
                if (uut.active_buf_sel == 0) begin
                    if (uut.activation_a.mem[m] !== golden_activation2[golden_index]) begin
                        if (intermediate_errors < 20)
                            $display("L2-A MISMATCH tile_base=%0d word=%0d RTL=%08h GOLD=%08h",
                                uut.tile_base_sample, m, uut.activation_a.mem[m],
                                golden_activation2[golden_index]);
                        intermediate_errors = intermediate_errors + 1;
                    end
                end else begin
                    if (uut.activation_b.mem[m] !== golden_activation2[golden_index]) begin
                        if (intermediate_errors < 20)
                            $display("L2-B MISMATCH tile_base=%0d word=%0d RTL=%08h GOLD=%08h",
                                uut.tile_base_sample, m, uut.activation_b.mem[m],
                                golden_activation2[golden_index]);
                        intermediate_errors = intermediate_errors + 1;
                    end
                end
            end
        end
    end
end

initial begin
    clk = 0; rst = 1; start = 0; instruction = 0; inst_valid = 0;
    dram_rdata = 0; dram_rvalid = 0; dram_index = 0;
    burst_active = 0; burst_words_left = 0; burst_dram_index = 0;
    cycle_count = 0; error_count = 0; intermediate_errors = 0;
    intermediate_compares = 0; profile_active = 0; output_file = 0;

    $readmemh({`DATA_DIR, "/input_dram_packed32.hex"},
              mock_dram, INPUT_DRAM_WORD_BASE,
              INPUT_DRAM_WORD_BASE + TOTAL_INPUT_WORDS - 1);
    $readmemh({`DATA_DIR, "/weight_packed32.hex"},
              mock_dram, WEIGHT_DRAM_WORD_BASE,
              WEIGHT_DRAM_WORD_BASE + TOTAL_WEIGHT_WORDS - 1);
    $readmemh({`DATA_DIR, "/bias_int32.hex"},
              mock_dram, BIAS_DRAM_WORD_BASE,
              BIAS_DRAM_WORD_BASE + TOTAL_BIAS_WORDS - 1);
    $readmemh({`DATA_DIR, "/golden_output_int32.hex"}, golden_output);
    $readmemh({`DATA_DIR, "/golden_activation1_packed32.hex"},
              golden_activation1);
    $readmemh({`DATA_DIR, "/golden_activation2_packed32.hex"},
              golden_activation2);
    for (k = 0; k < TOTAL_OUTPUTS; k = k + 1)
        uut.output_sram.mem[k] = 32'hxxxx_xxxx;

    repeat (4) @(negedge clk); rst = 0;
    send_batch_instruction(BATCH);
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;

    while (!done && cycle_count < TIMEOUT_CYCLES) begin
        @(negedge clk); cycle_count = cycle_count + 1;
    end
    if (!done) begin
        $display("TEST FAIL: timeout state=%0d dma=%0d layer=%0d tile=%0d batch=%0d",
            debug_state, uut.dma_state, uut.layer_cnt,
            uut.tile_base_sample, uut.batch_in_tile);
        $finish;
    end
    @(negedge clk);

    for (k = 0; k < TOTAL_OUTPUTS; k = k + 1)
        if (uut.output_sram.mem[k] !== golden_output[k]) begin
            if (error_count < 20)
                $display("OUTPUT MISMATCH sample=%0d output=%0d RTL=%08h GOLD=%08h",
                    k/32, k%32, uut.output_sram.mem[k], golden_output[k]);
            error_count = error_count + 1;
        end

    if (weight_load_count !== EXPECTED_WEIGHT_LOADS) begin
        $display("WEIGHT LOAD COUNT ERROR RTL=%0d EXPECTED=%0d",
            weight_load_count, EXPECTED_WEIGHT_LOADS);
        error_count = error_count + 1;
    end
    if (dram_request_count !==
        (TOTAL_INPUT_WORDS + TOTAL_WEIGHT_WORDS + TOTAL_BIAS_WORDS)
            / DMA_BURST_WORDS) begin
        $display("DRAM REQUEST COUNT ERROR RTL=%0d EXPECTED=%0d",
            dram_request_count,
            (TOTAL_INPUT_WORDS + TOTAL_WEIGHT_WORDS + TOTAL_BIAS_WORDS)
                / DMA_BURST_WORDS);
        error_count = error_count + 1;
    end
    if (active_bank_switches !== EXPECTED_TILE_COUNT-1) begin
        $display("A/B SWITCH COUNT ERROR RTL=%0d EXPECTED=%0d",
            active_bank_switches, EXPECTED_TILE_COUNT-1);
        error_count = error_count + 1;
    end
    error_count = error_count + intermediate_errors;

    output_file = $fopen({`DATA_DIR, "/rtl_output_reuse_int32.hex"}, "w");
    if (output_file != 0) begin
        for (k = 0; k < TOTAL_OUTPUTS; k = k + 1)
            $fwrite(output_file, "%08h\n", uut.output_sram.mem[k]);
        $fclose(output_file);
    end

    $display("============================================================");
    $display("A/B/S BATCH-TILED WEIGHT-REUSE RESULT");
    $display("topology                 : 800 -> 128 -> 64 -> 32");
    $display("samples / batch tile     : %0d / %0d", BATCH, BATCH_TILE);
    $display("total cycles             : %0d", cycle_count);
    $display("cycles per inference     : %0f", $itor(cycle_count)/BATCH);
    $display("weight loads (reuse)     : %0d", weight_load_count);
    $display("weight loads (baseline)  : %0d", BASELINE_WEIGHT_LOADS);
    $display("weight-load reduction    : %0.2f %%",
        100.0 * (BASELINE_WEIGHT_LOADS-weight_load_count)/BASELINE_WEIGHT_LOADS);
    $display("A/B active-bank switches : %0d", active_bank_switches);
    $display("DRAM burst requests      : %0d", dram_request_count);
    $display("DRAM words transferred   : %0d",
        TOTAL_INPUT_WORDS + TOTAL_WEIGHT_WORDS + TOTAL_BIAS_WORDS);
    $display("DMA busy cycles          : %0d", dma_busy_cycles);
    $display("DMA/compute overlap      : %0d", overlap_cycles);
    $display("Layer 1 cycles           : %0d", layer_cycles[0]);
    $display("Layer 2 cycles           : %0d", layer_cycles[1]);
    $display("Layer 3 cycles           : %0d", layer_cycles[2]);
    $display("LOAD_WEIGHT cycles       : %0d", state_cycles[ST_LOAD_WEIGHT]);
    $display("LOAD_INPUT cycles        : %0d", state_cycles[ST_LOAD_INPUT]);
    $display("final output writes      : %0d", output_write_count);
    $display("intermediate compares    : %0d", intermediate_compares);
    $display("intermediate errors      : %0d", intermediate_errors);
    if (error_count == 0)
        $display("result                   : TEST PASS");
    else
        $display("result                   : TEST FAIL (%0d errors)", error_count);
    $display("============================================================");
    $finish;
end

endmodule
