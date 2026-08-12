# Run from the Vivado Tcl Console after opening adventure_dma8.xpr.
# This runs only the waveform-oriented handshake test.

set suite_dir [file dirname [info script]]
set repo_dir [file dirname $suite_dir]
set tb_file [file join $repo_dir tb PE_array_wrapper_reuse_handshake_tb.v]

if {[llength [get_projects -quiet]] == 0} {
    open_project [file join $repo_dir build adventure_dma8 adventure_dma8.xpr]
}

if {[llength [get_files -quiet $tb_file]] == 0} {
    add_files -fileset sim_1 -norecurse $tb_file
}
set_property file_type {Verilog} [get_files $tb_file]
set_property top PE_array_wrapper_reuse_handshake_tb [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral

if {[llength [get_wave_configs -quiet]] == 0} {
    create_wave_config
}

set dut /PE_array_wrapper_reuse_handshake_tb/dut
add_wave -divider {External DRAM protocol}
add_wave /PE_array_wrapper_reuse_handshake_tb/clk
add_wave /PE_array_wrapper_reuse_handshake_tb/rst
add_wave /PE_array_wrapper_reuse_handshake_tb/start
add_wave /PE_array_wrapper_reuse_handshake_tb/dram_req
add_wave -radix hex /PE_array_wrapper_reuse_handshake_tb/dram_addr
add_wave /PE_array_wrapper_reuse_handshake_tb/dram_rvalid
add_wave -radix hex /PE_array_wrapper_reuse_handshake_tb/dram_rdata

add_wave -divider {DMA control}
add_wave -radix unsigned $dut/dma_state
add_wave -radix unsigned $dut/dma_mode
add_wave -radix unsigned $dut/dma_word_cnt
add_wave -radix unsigned $dut/dma_burst_word_cnt
add_wave $dut/dma_target_sel
add_wave $dut/model_loaded

add_wave -divider {Inactive-bank writes}
add_wave $dut/act_a_we
add_wave $dut/act_b_we
add_wave -radix unsigned $dut/act_a_addr
add_wave -radix unsigned $dut/act_b_addr

add_wave -divider {Ownership and Main FSM}
add_wave -radix unsigned /PE_array_wrapper_reuse_handshake_tb/debug_state
add_wave $dut/buf_a_ready
add_wave $dut/buf_b_ready
add_wave $dut/active_buf_sel
add_wave -radix unsigned $dut/tile_base_sample
add_wave -radix unsigned $dut/tile_sample_count

run all
zoom_fit
