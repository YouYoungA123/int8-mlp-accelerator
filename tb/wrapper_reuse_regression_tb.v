`timescale 1ns / 1ps

`ifndef DATA_DIR
`ifndef DATA_DIR
`define DATA_DIR "verification/generated"
`endif
`endif

// Parameterized regression bench for PE_array_wrapper_reuse.
// STALL_MODE: 0=no stalls, 1=periodic rvalid stalls, 2=pseudo-random stalls.
module wrapper_reuse_regression_tb #(
    parameter integer BATCH = 8,
    parameter integer BATCH_TILE = 4,
    parameter integer STALL_MODE = 0,
    parameter integer RUNS = 1,
    parameter integer TIMEOUT_CYCLES = 250000
);

localparam integer MAX_BATCH = 8;
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
localparam integer BIAS_DRAM_WORD_BASE = WEIGHT_DRAM_WORD_BASE + TOTAL_WEIGHT_WORDS;
localparam integer TOTAL_DRAM_WORDS = BIAS_DRAM_WORD_BASE + TOTAL_BIAS_WORDS;
localparam integer TOTAL_OUTPUTS = BATCH * 32;
localparam integer L1_WORDS = L1_OUTPUT_GROUPS * 8;
localparam integer L2_WORDS = L2_OUTPUT_GROUPS * 8;
localparam integer EXPECTED_LOADS_PER_TILE =
      L1_INPUT_GROUPS * L1_OUTPUT_GROUPS
    + L2_INPUT_GROUPS * L2_OUTPUT_GROUPS
    + L3_INPUT_GROUPS * L3_OUTPUT_GROUPS;
localparam integer EXPECTED_TILE_COUNT = (BATCH + BATCH_TILE - 1) / BATCH_TILE;
localparam integer EXPECTED_WEIGHT_LOADS = EXPECTED_LOADS_PER_TILE * EXPECTED_TILE_COUNT;
localparam integer BASELINE_WEIGHT_LOADS = EXPECTED_LOADS_PER_TILE * BATCH;
localparam integer EXPECTED_INTERMEDIATE = BATCH * (L1_WORDS + L2_WORDS);
localparam integer EXPECTED_REQUESTS_FIRST_RUN =
    (TOTAL_INPUT_WORDS + TOTAL_WEIGHT_WORDS + TOTAL_BIAS_WORDS) / DMA_BURST_WORDS;
localparam integer EXPECTED_REQUESTS_LATER_RUN = TOTAL_INPUT_WORDS / DMA_BURST_WORDS;

localparam [4:0] ST_LOAD_WEIGHT    = 5'd4;
localparam [4:0] ST_LOAD_INPUT     = 5'd6;
localparam [4:0] ST_LAYER_DONE     = 5'd13;
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
reg [31:0] golden_output [0:MAX_BATCH*32-1];
reg [31:0] golden_activation1 [0:MAX_BATCH*L1_WORDS-1];
reg [31:0] golden_activation2 [0:MAX_BATCH*L2_WORDS-1];

integer state_cycles [0:31];
integer layer_cycles [0:2];
integer k, m, run_index, golden_index;
integer cycle_count, total_errors, run_errors, intermediate_errors;
integer intermediate_compares, weight_load_count, dram_request_count;
integer dma_busy_cycles, overlap_cycles, output_write_count;
integer active_bank_switches, last_active_bank;
integer burst_words_left, burst_dram_index, stall_counter;
integer expected_requests;
reg burst_active, profile_active, done_d;
reg [15:0] lfsr;

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

function integer allow_dram_beat;
    input unused;
    begin
        if (STALL_MODE == 0)
            allow_dram_beat = 1;
        else if (STALL_MODE == 1)
            allow_dram_beat = ((stall_counter % 4) != 2);
        else
            allow_dram_beat = lfsr[0] | lfsr[2];
    end
endfunction

// Fixed-length burst model with optional rvalid backpressure.
always @(posedge clk) begin
    dram_rvalid <= 1'b0;
    lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    if (!burst_active && dram_req) begin
        burst_active <= 1'b1;
        burst_words_left <= DMA_BURST_WORDS;
        burst_dram_index <= dram_addr >> 2;
        stall_counter <= 0;
    end else if (burst_active) begin
        stall_counter <= stall_counter + 1;
        if (allow_dram_beat(1'b0)) begin
            dram_rvalid <= 1'b1;
            if (burst_dram_index >= 0 && burst_dram_index < TOTAL_DRAM_WORDS)
                dram_rdata <= mock_dram[burst_dram_index];
            else begin
                dram_rdata <= 32'hxxxx_xxxx;
                $display("ASSERT DRAM_RANGE index=%0d", burst_dram_index);
                total_errors = total_errors + 1;
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
end

task send_batch_instruction;
    input [5:0] value;
    begin
        @(negedge clk); instruction = {2'b00, value}; inst_valid = 1'b1;
        @(negedge clk); inst_valid = 1'b0;
        repeat (3) @(negedge clk);
    end
endtask

task clear_run_counters;
    begin
        cycle_count = 0;
        run_errors = 0;
        intermediate_errors = 0;
        intermediate_compares = 0;
        weight_load_count = 0;
        dram_request_count = 0;
        dma_busy_cycles = 0;
        overlap_cycles = 0;
        output_write_count = 0;
        active_bank_switches = 0;
        last_active_bank = uut.active_buf_sel;
        for (m = 0; m < 32; m = m + 1) state_cycles[m] = 0;
        for (m = 0; m < 3; m = m + 1) layer_cycles[m] = 0;
        for (m = 0; m < TOTAL_OUTPUTS; m = m + 1)
            uut.output_sram.mem[m] = 32'hxxxx_xxxx;
    end
endtask

task check_final_outputs;
    begin
        for (k = 0; k < TOTAL_OUTPUTS; k = k + 1) begin
            if (uut.output_sram.mem[k] !== golden_output[k]) begin
                if (run_errors < 20)
                    $display("OUTPUT MISMATCH run=%0d sample=%0d output=%0d RTL=%08h GOLD=%08h",
                        run_index, k/32, k%32, uut.output_sram.mem[k], golden_output[k]);
                run_errors = run_errors + 1;
            end
        end
    end
endtask

// Profiling and protocol assertions.
always @(posedge clk) begin
    done_d <= done;
    if (done && done_d) begin
        $display("ASSERT DONE_NOT_ONE_CYCLE");
        total_errors = total_errors + 1;
    end
    if (profile_active && !done) begin
        state_cycles[debug_state] = state_cycles[debug_state] + 1;
        if (debug_state >= ST_LOAD_WEIGHT && debug_state <= ST_LAYER_DONE)
            layer_cycles[uut.layer_cnt] = layer_cycles[uut.layer_cnt] + 1;
        if (uut.weight_load) weight_load_count = weight_load_count + 1;
        if (dram_req) dram_request_count = dram_request_count + 1;
        if (uut.dma_state != 0) dma_busy_cycles = dma_busy_cycles + 1;
        if (uut.dma_state != 0 && debug_state >= ST_LOAD_WEIGHT && debug_state <= ST_LAYER_DONE)
            overlap_cycles = overlap_cycles + 1;
        if (uut.output_we) output_write_count = output_write_count + 1;
        if (uut.active_buf_sel != last_active_bank) begin
            active_bank_switches = active_bank_switches + 1;
            last_active_bank = uut.active_buf_sel;
        end

        if (debug_state >= ST_LOAD_WEIGHT && debug_state <= ST_LAYER_DONE &&
            (uut.tile_sample_count == 0 || uut.tile_sample_count > BATCH_TILE)) begin
            $display("ASSERT BAD_TILE_COUNT value=%0d", uut.tile_sample_count);
            total_errors = total_errors + 1;
        end
        if (debug_state >= ST_LOAD_INPUT && debug_state <= ST_LAYER_DONE &&
            uut.batch_in_tile >= uut.tile_sample_count) begin
            $display("ASSERT BATCH_INDEX_RANGE batch=%0d count=%0d state=%0d",
                uut.batch_in_tile, uut.tile_sample_count, debug_state);
            total_errors = total_errors + 1;
        end
        if (uut.output_we && uut.output_addr >= TOTAL_OUTPUTS) begin
            $display("ASSERT OUTPUT_ADDR_RANGE addr=%0d max=%0d", uut.output_addr, TOTAL_OUTPUTS-1);
            total_errors = total_errors + 1;
        end
        if (uut.output_we && (^uut.output_data_in === 1'bx)) begin
            $display("ASSERT OUTPUT_X addr=%0d", uut.output_addr);
            total_errors = total_errors + 1;
        end
        if (uut.dma_state != 0 && uut.dma_mode == 0 &&
            debug_state >= ST_LOAD_WEIGHT && debug_state <= ST_LAYER_DONE &&
            uut.dma_target_sel == uut.active_buf_sel) begin
            $display("ASSERT DMA_ACTIVE_BANK_CONFLICT state=%0d bank=%0d",
                debug_state, uut.active_buf_sel);
            total_errors = total_errors + 1;
        end
    end
end

// Compare every intermediate tile before its storage is reused.
always @(negedge clk) begin
    if (profile_active && debug_state == ST_LAYER_DONE) begin
        if (uut.layer_cnt == 0) begin
            for (m = 0; m < uut.tile_sample_count * L1_WORDS; m = m + 1) begin
                golden_index = uut.tile_base_sample * L1_WORDS + m;
                intermediate_compares = intermediate_compares + 1;
                if (uut.activation_s.mem[m] !== golden_activation1[golden_index]) begin
                    if (intermediate_errors < 20)
                        $display("L1 MISMATCH run=%0d tile=%0d word=%0d", run_index, uut.tile_base_sample, m);
                    intermediate_errors = intermediate_errors + 1;
                end
            end
        end else if (uut.layer_cnt == 1) begin
            for (m = 0; m < uut.tile_sample_count * L2_WORDS; m = m + 1) begin
                golden_index = uut.tile_base_sample * L2_WORDS + m;
                intermediate_compares = intermediate_compares + 1;
                if (uut.active_buf_sel == 0) begin
                    if (uut.activation_a.mem[m] !== golden_activation2[golden_index])
                        intermediate_errors = intermediate_errors + 1;
                end else begin
                    if (uut.activation_b.mem[m] !== golden_activation2[golden_index])
                        intermediate_errors = intermediate_errors + 1;
                end
            end
        end
    end
end

initial begin
    clk = 0; rst = 1; start = 0; instruction = 0; inst_valid = 0;
    dram_rdata = 0; dram_rvalid = 0; burst_active = 0;
    burst_words_left = 0; burst_dram_index = 0; stall_counter = 0;
    profile_active = 0; done_d = 0; total_errors = 0; lfsr = 16'h1ACE;

    if (BATCH < 1 || BATCH > MAX_BATCH) begin
        $display("TEST CONFIG ERROR: BATCH must be 1..%0d", MAX_BATCH);
        $finish;
    end

    $readmemh({`DATA_DIR, "/input_dram_packed32.hex"},
        mock_dram, INPUT_DRAM_WORD_BASE, INPUT_DRAM_WORD_BASE + TOTAL_INPUT_WORDS - 1);
    $readmemh({`DATA_DIR, "/weight_packed32.hex"},
        mock_dram, WEIGHT_DRAM_WORD_BASE, WEIGHT_DRAM_WORD_BASE + TOTAL_WEIGHT_WORDS - 1);
    $readmemh({`DATA_DIR, "/bias_int32.hex"},
        mock_dram, BIAS_DRAM_WORD_BASE, BIAS_DRAM_WORD_BASE + TOTAL_BIAS_WORDS - 1);
    $readmemh({`DATA_DIR, "/golden_output_int32.hex"}, golden_output);
    $readmemh({`DATA_DIR, "/golden_activation1_packed32.hex"}, golden_activation1);
    $readmemh({`DATA_DIR, "/golden_activation2_packed32.hex"}, golden_activation2);

    repeat (4) @(negedge clk); rst = 0;
    send_batch_instruction(BATCH);

    for (run_index = 0; run_index < RUNS; run_index = run_index + 1) begin
        clear_run_counters();
        @(negedge clk); start = 1; profile_active = 1;
        @(negedge clk); start = 0;
        while (!done && cycle_count < TIMEOUT_CYCLES) begin
            @(negedge clk); cycle_count = cycle_count + 1;
        end
        profile_active = 0;
        if (!done) begin
            $display("TEST FAIL: timeout run=%0d state=%0d dma=%0d tile=%0d batch=%0d",
                run_index, debug_state, uut.dma_state, uut.tile_base_sample, uut.batch_in_tile);
            total_errors = total_errors + 1;
        end else begin
            @(negedge clk);
            check_final_outputs();
            expected_requests = (run_index == 0) ? EXPECTED_REQUESTS_FIRST_RUN : EXPECTED_REQUESTS_LATER_RUN;
            if (weight_load_count != EXPECTED_WEIGHT_LOADS) begin
                $display("WEIGHT LOAD ERROR run=%0d got=%0d expected=%0d",
                    run_index, weight_load_count, EXPECTED_WEIGHT_LOADS);
                run_errors = run_errors + 1;
            end
            if (dram_request_count != expected_requests) begin
                $display("DRAM REQUEST ERROR run=%0d got=%0d expected=%0d",
                    run_index, dram_request_count, expected_requests);
                run_errors = run_errors + 1;
            end
            if (active_bank_switches != EXPECTED_TILE_COUNT-1) begin
                $display("BANK SWITCH ERROR run=%0d got=%0d expected=%0d",
                    run_index, active_bank_switches, EXPECTED_TILE_COUNT-1);
                run_errors = run_errors + 1;
            end
            if (output_write_count != TOTAL_OUTPUTS) begin
                $display("OUTPUT WRITE ERROR run=%0d got=%0d expected=%0d",
                    run_index, output_write_count, TOTAL_OUTPUTS);
                run_errors = run_errors + 1;
            end
            if (intermediate_compares != EXPECTED_INTERMEDIATE) begin
                $display("INTERMEDIATE COUNT ERROR run=%0d got=%0d expected=%0d",
                    run_index, intermediate_compares, EXPECTED_INTERMEDIATE);
                run_errors = run_errors + 1;
            end
            run_errors = run_errors + intermediate_errors;
            total_errors = total_errors + run_errors;

            $display("------------------------------------------------------------");
            $display("CASE batch=%0d tile=%0d stall=%0d run=%0d", BATCH, BATCH_TILE, STALL_MODE, run_index);
            $display("cycles=%0d cycles/inference=%0f", cycle_count, $itor(cycle_count)/BATCH);
            $display("weight_loads=%0d baseline=%0d reduction=%0.2f %%",
                weight_load_count, BASELINE_WEIGHT_LOADS,
                100.0*(BASELINE_WEIGHT_LOADS-weight_load_count)/BASELINE_WEIGHT_LOADS);
            $display("dram_requests=%0d dma_busy=%0d overlap=%0d", dram_request_count, dma_busy_cycles, overlap_cycles);
            $display("layer_cycles=%0d/%0d/%0d load_weight=%0d load_input=%0d",
                layer_cycles[0], layer_cycles[1], layer_cycles[2],
                state_cycles[ST_LOAD_WEIGHT], state_cycles[ST_LOAD_INPUT]);
            $display("outputs=%0d intermediate=%0d errors=%0d",
                output_write_count, intermediate_compares, run_errors);
        end
        repeat (4) @(negedge clk);
    end

    if (total_errors == 0)
        $display("REGRESSION TEST PASS batch=%0d tile=%0d stall=%0d runs=%0d", BATCH, BATCH_TILE, STALL_MODE, RUNS);
    else
        $display("REGRESSION TEST FAIL errors=%0d batch=%0d tile=%0d stall=%0d runs=%0d",
            total_errors, BATCH, BATCH_TILE, STALL_MODE, RUNS);
    $finish;
end

endmodule

module tb_batch1;
    wrapper_reuse_regression_tb #(.BATCH(1)) test();
endmodule

module tb_batch4;
    wrapper_reuse_regression_tb #(.BATCH(4)) test();
endmodule

module tb_batch5;
    wrapper_reuse_regression_tb #(.BATCH(5)) test();
endmodule

module tb_batch7;
    wrapper_reuse_regression_tb #(.BATCH(7)) test();
endmodule

module tb_batch8;
    wrapper_reuse_regression_tb #(.BATCH(8)) test();
endmodule

module tb_batch5_periodic_stall;
    wrapper_reuse_regression_tb #(.BATCH(5), .STALL_MODE(1)) test();
endmodule

module tb_batch8_random_stall;
    wrapper_reuse_regression_tb #(.BATCH(8), .STALL_MODE(2), .TIMEOUT_CYCLES(400000)) test();
endmodule

module tb_batch4_restart;
    wrapper_reuse_regression_tb #(.BATCH(4), .RUNS(2)) test();
endmodule
