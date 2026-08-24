set_property SRC_FILE_INFO {cfile:D:/260805_AIGIS_inseok/zyboproject_inseok/constraints/zybo_secure.xdc rfile:../../../constraints/zybo_secure.xdc id:1} [current_design]
set_property src_info {type:XDC file:1 line:6 export:INPUT save:INPUT read:READ} [current_design]
create_clock -period 8.000 -name sys_clk_pin -waveform {0.000 4.000} -add [get_ports clk]
