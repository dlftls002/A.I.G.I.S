set root_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root_dir vivado_jetson_secure zybo_secure_jetson.xpr]

synth_design -top zybo_secure_control_unit_v2 -part xc7z020clg400-1
opt_design
place_design
phys_opt_design
route_design
report_utilization -file [file join $root_dir zybo_secure_v2_impl_utilization.rpt]
report_timing_summary -file [file join $root_dir zybo_secure_v2_impl_timing.rpt]
write_bitstream -force [file join $root_dir zybo_secure_control_unit_v2.bit]

puts "ZYBO BITSTREAM VERIFIED: [file join $root_dir zybo_secure_control_unit_v2.bit]"
close_project
