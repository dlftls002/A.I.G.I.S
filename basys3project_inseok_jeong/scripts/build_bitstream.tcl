set root_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root_dir vivado basys3_secure_v2.xpr]

synth_design -top basys3_secure_rack_control -part xc7a35tcpg236-1
opt_design
place_design
phys_opt_design
route_design
report_utilization -file [file join $root_dir basys3_secure_v2_impl_utilization.rpt]
report_timing_summary -file [file join $root_dir basys3_secure_v2_impl_timing.rpt]
write_bitstream -force [file join $root_dir basys3_secure_rack_control.bit]

puts "BASYS3 BITSTREAM VERIFIED: [file join $root_dir basys3_secure_rack_control.bit]"
close_project
