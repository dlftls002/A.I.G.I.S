set root_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root_dir vivado_tests tb_spi_384]

create_project tb_spi_384 $project_dir -force -part xc7z020clg400-1
add_files -norecurse [list \
    [file join $root_dir rtl legacy spi_master.sv] \
    [file join $root_dir rtl legacy spi_slave.sv]]
add_files -fileset sim_1 -norecurse [file join $root_dir tb tb_spi_384.sv]
set_property top tb_spi_384 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation
run all
close_sim
close_project

set sim_log [file join $project_dir tb_spi_384.sim sim_1 behav xsim simulate.log]
set fh [open $sim_log r]
set text [read $fh]
close $fh
if {[string first "PASS: 384-bit full-duplex SPI transfers both secure frames exactly" $text] < 0} {
    error "SPI TEST FAILED: $sim_log"
}
puts "384-BIT SPI TEST VERIFIED"

