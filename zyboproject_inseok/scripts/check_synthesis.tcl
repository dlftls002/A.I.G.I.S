set root_dir [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root_dir vivado_jetson_secure zybo_secure_jetson.xpr]
synth_design -top zybo_secure_control_unit_v2 -part xc7z020clg400-1
report_utilization -file [file join $root_dir zybo_secure_v2_utilization.rpt]
report_timing_summary -file [file join $root_dir zybo_secure_v2_timing.rpt]
puts "ZYBO SYNTHESIS VERIFIED"
close_project
