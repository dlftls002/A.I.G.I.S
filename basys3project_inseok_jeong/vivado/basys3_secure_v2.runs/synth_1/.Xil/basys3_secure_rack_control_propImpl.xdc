set_property SRC_FILE_INFO {cfile:D:/260807_AIGIS_inseok/basys3project_inseok_jeong/constraints/basys3_secure.xdc rfile:../../../../constraints/basys3_secure.xdc id:1} [current_design]
set_property src_info {type:XDC file:1 line:5 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN W5   IOSTANDARD LVCMOS33 } [get_ports clk]
set_property src_info {type:XDC file:1 line:15 export:INPUT save:INPUT read:READ} [current_design]
if {[llength [get_pins -quiet U_VGA_DECODER/u_pclk_gen/pclk_reg/Q]] && [llength [get_pins -quiet U_VGA_DECODER/u_pclk_gen/pclk_reg/C]]} {
create_generated_clock -name vga_rclk -source [get_pins -quiet U_VGA_DECODER/u_pclk_gen/pclk_reg/C] -divide_by 4 [get_pins -quiet U_VGA_DECODER/u_pclk_gen/pclk_reg/Q]
} else {
puts "WARNING: rclk 핀을 찾지 못해 vga_rclk를 제약하지 못했습니다."
}
set_property src_info {type:XDC file:1 line:22 export:INPUT save:INPUT read:READ} [current_design]
if {[llength [get_clocks -quiet {sys_clk_pin clk_100M_clk_wiz_0 clk_25M_clk_wiz_0 vga_rclk}]]} {
set_clock_groups -asynchronous -group [get_clocks cam_pclk] -group [get_clocks -quiet {sys_clk_pin clk_100M_clk_wiz_0 clk_25M_clk_wiz_0 vga_rclk}]
}
set_property src_info {type:XDC file:1 line:29 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports rst]
set_property src_info {type:XDC file:1 line:35 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports { sclk_in }];# Sch name = JC1
set_property src_info {type:XDC file:1 line:36 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN M18  IOSTANDARD LVCMOS33 } [get_ports { mosi_in }];# Sch name = JC2
set_property src_info {type:XDC file:1 line:37 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN N17  IOSTANDARD LVCMOS33 } [get_ports { cs_n_in }];# Sch name = JC3
set_property src_info {type:XDC file:1 line:38 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN P18  IOSTANDARD LVCMOS33 } [get_ports { miso_out }];# Sch name = JC4
set_property src_info {type:XDC file:1 line:44 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r1 }];# Sch name = JC7
set_property src_info {type:XDC file:1 line:45 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN M19   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r2 }];# Sch name = JC8
set_property src_info {type:XDC file:1 line:46 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN P17   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r3 }];# Sch name = JC9
set_property src_info {type:XDC file:1 line:47 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN R18   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r4 }];# Sch name = JC10
set_property src_info {type:XDC file:1 line:53 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN A14   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[0]}];#Sch name = JB1
set_property src_info {type:XDC file:1 line:54 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN A16   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[1]}];#Sch name = JB2
set_property src_info {type:XDC file:1 line:55 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN B15   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[2]}];#Sch name = JB3
set_property src_info {type:XDC file:1 line:56 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN B16   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[3]}];#Sch name = JB4
set_property src_info {type:XDC file:1 line:57 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN A15   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[0]}];#Sch name = JB7
set_property src_info {type:XDC file:1 line:58 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN A17   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[1]}];#Sch name = JB8
set_property src_info {type:XDC file:1 line:59 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN C15   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[2]}];#Sch name = JB9
set_property src_info {type:XDC file:1 line:60 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN C16   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[3]}];#Sch name = JB10
set_property src_info {type:XDC file:1 line:66 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN J1  IOSTANDARD LVCMOS33 } [get_ports {pdata[7]}]
set_property src_info {type:XDC file:1 line:67 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L2  IOSTANDARD LVCMOS33 } [get_ports {pdata[5]}]
set_property src_info {type:XDC file:1 line:68 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN J2  IOSTANDARD LVCMOS33 } [get_ports {pdata[3]}]
set_property src_info {type:XDC file:1 line:69 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN G2  IOSTANDARD LVCMOS33 } [get_ports {pdata[1]}]
set_property src_info {type:XDC file:1 line:70 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN H1  IOSTANDARD LVCMOS33 } [get_ports {pdata[6]}]
set_property src_info {type:XDC file:1 line:71 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN K2  IOSTANDARD LVCMOS33 } [get_ports {pdata[4]}]
set_property src_info {type:XDC file:1 line:72 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN H2  IOSTANDARD LVCMOS33 } [get_ports {pdata[2]}]
set_property src_info {type:XDC file:1 line:73 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN G3  IOSTANDARD LVCMOS33 } [get_ports {pdata[0]}]
set_property src_info {type:XDC file:1 line:79 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN J3   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {sda}]
set_property src_info {type:XDC file:1 line:80 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L3   IOSTANDARD LVCMOS33 } [get_ports {vsync}]
set_property src_info {type:XDC file:1 line:81 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN K3   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {scl}]
set_property src_info {type:XDC file:1 line:82 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN M3   IOSTANDARD LVCMOS33 } [get_ports {href}]
set_property src_info {type:XDC file:1 line:83 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN M1   IOSTANDARD LVCMOS33 } [get_ports {xclk}]
set_property src_info {type:XDC file:1 line:84 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN N1   IOSTANDARD LVCMOS33 } [get_ports {pclk}]
set_property src_info {type:XDC file:1 line:85 export:INPUT save:INPUT read:READ} [current_design]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets pclk_IBUF]
set_property src_info {type:XDC file:1 line:90 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN G19  IOSTANDARD LVCMOS33 } [get_ports {port_red[0]}]
set_property src_info {type:XDC file:1 line:91 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN H19  IOSTANDARD LVCMOS33 } [get_ports {port_red[1]}]
set_property src_info {type:XDC file:1 line:92 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN J19  IOSTANDARD LVCMOS33 } [get_ports {port_red[2]}]
set_property src_info {type:XDC file:1 line:93 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN N19  IOSTANDARD LVCMOS33 } [get_ports {port_red[3]}]
set_property src_info {type:XDC file:1 line:94 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN N18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[0]}]
set_property src_info {type:XDC file:1 line:95 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[1]}]
set_property src_info {type:XDC file:1 line:96 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN K18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[2]}]
set_property src_info {type:XDC file:1 line:97 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN J18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[3]}]
set_property src_info {type:XDC file:1 line:98 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN J17  IOSTANDARD LVCMOS33 } [get_ports {port_green[0]}]
set_property src_info {type:XDC file:1 line:99 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN H17  IOSTANDARD LVCMOS33 } [get_ports {port_green[1]}]
set_property src_info {type:XDC file:1 line:100 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN G17  IOSTANDARD LVCMOS33 } [get_ports {port_green[2]}]
set_property src_info {type:XDC file:1 line:101 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN D17  IOSTANDARD LVCMOS33 } [get_ports {port_green[3]}]
set_property src_info {type:XDC file:1 line:102 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN P19  IOSTANDARD LVCMOS33 } [get_ports h_sync]
set_property src_info {type:XDC file:1 line:103 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN R19  IOSTANDARD LVCMOS33 } [get_ports v_sync]
set_property src_info {type:XDC file:1 line:106 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property src_info {type:XDC file:1 line:107 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
