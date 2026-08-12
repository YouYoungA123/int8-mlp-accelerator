# Run from the Vivado Tcl console after opening adventure_dma8.xpr:
#   source C:/.../reuse_tb_suite/run_regression.tcl

set suite_dir [file dirname [info script]]
set repo_dir [file dirname $suite_dir]
set tb_file [file join $repo_dir tb wrapper_reuse_regression_tb.v]
set data_dir [file join $repo_dir verification generated]

if {[llength [get_projects -quiet]] == 0} {
    open_project [file join $repo_dir build adventure_dma8 adventure_dma8.xpr]
}

if {[llength [get_files -quiet $tb_file]] == 0} {
    add_files -fileset sim_1 -norecurse $tb_file
}
set_property file_type {Verilog} [get_files $tb_file]
set_property verilog_define "DATA_DIR=\"[string map {\\ /} $data_dir]\"" [get_filesets sim_1]

set cases {
    tb_batch1
    tb_batch4
    tb_batch5
    tb_batch7
    tb_batch8
    tb_batch5_periodic_stall
    tb_batch8_random_stall
    tb_batch4_restart
}

set failed {}
foreach top $cases {
    puts "============================================================"
    puts "RUNNING $top"
    puts "============================================================"
    set_property top $top [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    run all
    close_sim

    set log_path [file join [get_property DIRECTORY [current_project]] "[get_property NAME [current_project]].sim" sim_1 behav xsim simulate.log]
    if {[file exists $log_path]} {
        set fh [open $log_path r]
        set text [read $fh]
        close $fh
        if {[string first "REGRESSION TEST PASS" $text] < 0} {
            lappend failed $top
        }
    } else {
        lappend failed $top
    }
}

puts "============================================================"
if {[llength $failed] == 0} {
    puts "ALL REGRESSION CASES PASS"
} else {
    puts "FAILED CASES: $failed"
}
puts "============================================================"
