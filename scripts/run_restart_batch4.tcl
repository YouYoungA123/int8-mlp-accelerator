# Run two consecutive Batch-4 inferences without resetting the DUT.

set script_dir [file dirname [info script]]
set repo_dir [file dirname $script_dir]

if {[llength [get_projects -quiet]] == 0} {
    open_project [file join $repo_dir build adventure_dma8 adventure_dma8.xpr]
}

set_property top tb_batch4_restart [get_filesets sim_1]
set_property verilog_define "DATA_DIR=\"[string map {\\ /} [file join $repo_dir verification generated]]\"" [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all
