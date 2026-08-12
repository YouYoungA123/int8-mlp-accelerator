`timescale 1ns / 1ps

// Waveform-oriented verification for PE_array_wrapper_reuse.
//
// Purpose:
//   1) Capture the real request/response protocol used by this RTL.
//      There is no req_ready/rsp_ready port: dram_req is a one-cycle request
//      pulse and dram_rvalid marks each returned data beat.
//   2) Show model preload, input-tile DMA, inactive-bank writes, buf_ready,
//      and A/B ownership transfer in one simulation.
//   3) Keep the run short by using one input/output group per layer while
//      preserving the controller and DMA behavior.

module PE_array_wrapper_reuse_handshake_tb;

    localparam integer CLK_PERIOD       = 10;
    localparam integer DMA_BURST_WORDS  = 4;
    localparam integer RESPONSE_LATENCY = 2;
    localparam integer TEST_BATCH       = 3;
    localparam integer BATCH_TILE       = 2;
    localparam integer TIMEOUT_CYCLES   = 20000;

    localparam [1:0] DMA_IDLE   = 2'd0;
    localparam [1:0] DMA_REQ    = 2'd1;
    localparam [1:0] DMA_WAIT   = 2'd2;
    localparam [1:0] DMA_INPUT  = 2'd0;
    localparam [1:0] DMA_WEIGHT = 2'd1;
    localparam [1:0] DMA_BIAS   = 2'd2;

    localparam [4:0] WAIT_TILE   = 5'd3;
    localparam [4:0] LOAD_WEIGHT = 5'd4;

    reg         clk;
    reg         rst;
    reg         start;
    reg  [7:0]  instruction;
    reg         inst_valid;
    wire        dram_req;
    wire [31:0] dram_addr;
    reg  [31:0] dram_rdata;
    reg         dram_rvalid;
    wire [31:0] result_checksum;
    wire [4:0]  debug_state;
    wire        done;

    integer cycle_count;
    integer error_count;
    integer request_count;
    integer response_count;
    integer input_write_count;
    integer csv_file;

    reg         response_active;
    integer     response_delay;
    integer     response_beat;
    reg [31:0]  response_base_addr;
    reg         prev_dram_req;
    reg         prev_dram_rvalid;
    reg [1:0]   prev_dma_state;
    reg [1:0]   prev_dma_mode;
    reg         saw_a_ready;
    reg         saw_b_ready;
    reg         saw_bank_switch;
    reg         saw_b_consumed;

    PE_array_wrapper_reuse #(
        .L1_INPUT_GROUPS(1),
        .L1_OUTPUT_GROUPS(1),
        .L2_INPUT_GROUPS(1),
        .L2_OUTPUT_GROUPS(1),
        .L3_INPUT_GROUPS(1),
        .L3_OUTPUT_GROUPS(1),
        .BATCH_TILE(BATCH_TILE),
        .DMA_BURST_WORDS(DMA_BURST_WORDS),
        .REQUANT_SHIFT(8),
        .ACT_WORD_DEPTH(64),
        .ACT_ADDR_W(6),
        .WEIGHT_WORD_DEPTH(1024),
        .BIAS_DEPTH(128),
        .OUTPUT_DEPTH(128)
    ) dut (
        .clk(clk),
        .start(start),
        .rst(rst),
        .instruction(instruction),
        .inst_valid(inst_valid),
        .dram_req(dram_req),
        .dram_addr(dram_addr),
        .dram_rdata(dram_rdata),
        .dram_rvalid(dram_rvalid),
        .result_checksum(result_checksum),
        .debug_state(debug_state),
        .done(done)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Deterministic data makes the waveform readable. Functional arithmetic
    // correctness is covered by the regression suite; this TB checks protocol
    // sequencing and ownership transfer.
    function [31:0] make_dram_word;
        input [31:0] addr;
        input integer beat;
        begin
            make_dram_word = 32'h5A00_0000 ^ addr ^ beat;
        end
    endfunction

    // Fixed-length response model. A dram_req pulse is accepted immediately.
    // After RESPONSE_LATENCY idle cycles, exactly DMA_BURST_WORDS valid beats
    // are returned on consecutive clocks.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dram_rvalid       <= 1'b0;
            dram_rdata        <= 32'd0;
            response_active   <= 1'b0;
            response_delay    <= 0;
            response_beat     <= 0;
            response_base_addr<= 32'd0;
        end else begin
            dram_rvalid <= 1'b0;

            if (dram_req) begin
                if (response_active) begin
                    $display("ERROR: new dram_req while previous burst is active at cycle %0d", cycle_count);
                    error_count <= error_count + 1;
                end else begin
                    response_active    <= 1'b1;
                    response_delay     <= RESPONSE_LATENCY;
                    response_beat      <= 0;
                    response_base_addr <= dram_addr;
                end
            end

            if (response_active) begin
                if (response_delay > 0) begin
                    response_delay <= response_delay - 1;
                end else begin
                    dram_rvalid <= 1'b1;
                    dram_rdata  <= make_dram_word(response_base_addr, response_beat);
                    if (response_beat == DMA_BURST_WORDS - 1) begin
                        response_active <= 1'b0;
                        response_beat   <= 0;
                    end else begin
                        response_beat <= response_beat + 1;
                    end
                end
            end
        end
    end

    // Assertions and event tracking.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cycle_count      <= 0;
            error_count      <= 0;
            request_count    <= 0;
            response_count   <= 0;
            input_write_count<= 0;
            prev_dram_req    <= 1'b0;
            prev_dram_rvalid <= 1'b0;
            prev_dma_state   <= DMA_IDLE;
            prev_dma_mode    <= DMA_INPUT;
            saw_a_ready      <= 1'b0;
            saw_b_ready      <= 1'b0;
            saw_bank_switch  <= 1'b0;
            saw_b_consumed   <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            prev_dram_req <= dram_req;
            prev_dram_rvalid <= dram_rvalid;
            prev_dma_state <= dut.dma_state;
            prev_dma_mode <= dut.dma_mode;

            // dram_req is a pulse, not a level-held valid.
            if (dram_req && prev_dram_req) begin
                $display("ERROR: dram_req stayed high for multiple cycles at cycle %0d", cycle_count);
                error_count <= error_count + 1;
            end
            if (dram_req)
                request_count <= request_count + 1;
            if (dram_rvalid)
                response_count <= response_count + 1;

            // A DMA write must coincide with a valid response beat.
            if ((dut.weight_we || dut.bias_we ||
                 ((prev_dma_state == DMA_WAIT) &&
                  (prev_dma_mode == DMA_INPUT) && (dut.act_a_we || dut.act_b_we)))
                && !prev_dram_rvalid) begin
                $display("ERROR: DMA SRAM write without prior-cycle dram_rvalid at cycle %0d", cycle_count);
                error_count <= error_count + 1;
            end

            if (prev_dma_state == DMA_WAIT && prev_dma_mode == DMA_INPUT && prev_dram_rvalid &&
                (dut.act_a_we || dut.act_b_we))
                input_write_count <= input_write_count + 1;

            if (dut.buf_a_ready)
                saw_a_ready <= 1'b1;
            if (dut.buf_b_ready)
                saw_b_ready <= 1'b1;
            if (dut.active_buf_sel)
                saw_bank_switch <= 1'b1;
            if (dut.active_buf_sel && debug_state == LOAD_WEIGHT && !dut.buf_b_ready)
                saw_b_consumed <= 1'b1;

            if (cycle_count > TIMEOUT_CYCLES) begin
                $display("HANDSHAKE WAVE TEST TIMEOUT");
                $finish;
            end
        end
    end

    // CSV trace: convenient for plotting or checking exact clock boundaries.
    always @(negedge clk) begin
        if (!rst && csv_file != 0) begin
            $fwrite(csv_file,
                "%0d,%0d,%0d,%08x,%0d,%08x,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cycle_count, debug_state, dut.dma_state, dram_addr,
                dram_req, dram_rdata, dram_rvalid, dut.dma_mode,
                dut.dma_word_cnt, dut.dma_burst_word_cnt,
                dut.dma_target_sel, dut.act_a_we, dut.act_b_we,
                dut.buf_a_ready, dut.buf_b_ready, dut.active_buf_sel,
                dut.model_loaded);
        end
    end

    task program_batch;
        input [5:0] value;
        begin
            @(negedge clk);
            instruction <= {2'b00, value};
            inst_valid  <= 1'b1;
            @(negedge clk);
            inst_valid  <= 1'b0;
            wait (debug_state == 5'd0);
        end
    endtask

    initial begin
        rst         = 1'b1;
        start       = 1'b0;
        instruction = 8'd0;
        inst_valid  = 1'b0;
        csv_file = $fopen("handshake_trace.csv", "w");
        $fwrite(csv_file,
            "cycle,main_state,dma_state,dram_addr,dram_req,dram_rdata,dram_rvalid,dma_mode,dma_word_cnt,dma_burst_word_cnt,dma_target_sel,act_a_we,act_b_we,buf_a_ready,buf_b_ready,active_buf_sel,model_loaded\n");

        repeat (5) @(negedge clk);
        rst = 1'b0;
        program_batch(TEST_BATCH);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Stop as soon as the second tile has switched to B and WAIT_TILE has
        // consumed buf_b_ready. This keeps the saved waveform focused.
        wait (saw_b_consumed || done);
        repeat (5) @(posedge clk);

        $display("------------------------------------------------------------");
        $display("HANDSHAKE WAVE SUMMARY");
        $display("cycles=%0d requests=%0d responses=%0d input_writes=%0d",
                 cycle_count, request_count, response_count, input_write_count);
        $display("saw_a_ready=%0d saw_b_ready=%0d saw_bank_switch=%0d saw_b_consumed=%0d errors=%0d",
                 saw_a_ready, saw_b_ready, saw_bank_switch, saw_b_consumed, error_count);

        if (saw_a_ready && saw_b_ready && saw_bank_switch &&
            saw_b_consumed && error_count == 0)
            $display("HANDSHAKE WAVE TEST PASS");
        else
            $display("HANDSHAKE WAVE TEST FAIL");

        $fclose(csv_file);
        $finish;
    end

endmodule
