# Recreate the Vivado 2022.2 project from repository sources.

set script_dir [file dirname [info script]]
set repo_dir   [file dirname $script_dir]
set build_dir  [file join $repo_dir build adventure_dma8]

create_project adventure_dma8 $build_dir -part xczu2cg-sfvc784-1-e -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -fileset sources_1 [list \
    [file join $repo_dir rtl PE.v] \
    [file join $repo_dir rtl adder_tree_32.v] \
    [file join $repo_dir rtl PE_array_32.v] \
    [file join $repo_dir rtl SRAM_module.v] \
    [file join $repo_dir rtl PE_array_wrapper_reuse.v]]
set_property top PE_array_wrapper_reuse [get_filesets sources_1]

add_files -fileset constrs_1 [file join $repo_dir constraints adventure.xdc]

add_files -fileset sim_1 [list \
    [file join $repo_dir tb wrapper_reuse_tb.v] \
    [file join $repo_dir tb wrapper_reuse_regression_tb.v] \
    [file join $repo_dir tb PE_array_wrapper_reuse_handshake_tb.v]]
set_property top tb_batch4 [get_filesets sim_1]
set data_dir [file join $repo_dir verification generated]
set_property verilog_define "DATA_DIR=\"[string map {\\ /} $data_dir]\"" [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project

puts "Created project: $build_dir/adventure_dma8.xpr"
