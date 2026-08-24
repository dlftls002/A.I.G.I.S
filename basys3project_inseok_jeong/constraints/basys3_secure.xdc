## Basys3 보드용 XDC 제약 조건 파일 (basys3_rack_control.xdc)
## 이 파일은 예시로 작성되었으며, 실제 연결할 PMOD 핀 번호에 맞춰 수정이 필요합니다.

## Clock signal (Basys3는 W5 핀에 100MHz 기본 내장)
set_property -dict { PACKAGE_PIN W5   IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## =============================================================
## 클럭 제약 (카메라 연동 시 필수)
## =============================================================
create_clock -add -name cam_pclk -period 40.000 -waveform {0 20} [get_ports pclk]

set rclk_q [get_pins -quiet U_VGA_DECODER/u_pclk_gen/pclk_reg/Q]
set rclk_c [get_pins -quiet U_VGA_DECODER/u_pclk_gen/pclk_reg/C]
if {[llength $rclk_q] && [llength $rclk_c]} {
    create_generated_clock -name vga_rclk -source $rclk_c -divide_by 4 $rclk_q
} else {
    puts "WARNING: rclk 핀을 찾지 못해 vga_rclk를 제약하지 못했습니다."
}

set mmcm_clks [get_clocks -quiet {sys_clk_pin clk_100M_clk_wiz_0 clk_25M_clk_wiz_0 vga_rclk}]
if {[llength $mmcm_clks]} {
    set_clock_groups -asynchronous \
        -group [get_clocks cam_pclk] \
        -group $mmcm_clks
}

## Reset Button (예: 중앙 버튼 BTNC)
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports rst]

## ===================================================================
## SPI Slave Interface (ZYBO <-> Basys3)
## PMOD JC 핀 그룹 
## ===================================================================
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports { sclk_in }];# Sch name = JC1
set_property -dict { PACKAGE_PIN M18  IOSTANDARD LVCMOS33 } [get_ports { mosi_in }];# Sch name = JC2
set_property -dict { PACKAGE_PIN N17  IOSTANDARD LVCMOS33 } [get_ports { cs_n_in }];# Sch name = JC3
set_property -dict { PACKAGE_PIN P18  IOSTANDARD LVCMOS33 } [get_ports { miso_out }];# Sch name = JC4

## ===================================================================
## 서보모터 PWM 출력 핀 (Rack 1 ~ 4)
## PMOD JC 핀 그룹 
## ===================================================================
set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r1 }];# Sch name = JC7
set_property -dict { PACKAGE_PIN M19   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r2 }];# Sch name = JC8
set_property -dict { PACKAGE_PIN P17   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r3 }];# Sch name = JC9
set_property -dict { PACKAGE_PIN R18   IOSTANDARD LVCMOS33 } [get_ports { servo_pwm_r4 }];# Sch name = JC10

## ===================================================================
## DHT11 & 화재 진압 서보모터
## PMOD JB 핀 그룹 
## ===================================================================
set_property -dict { PACKAGE_PIN A14   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[0]}];#Sch name = JB1
set_property -dict { PACKAGE_PIN A16   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[1]}];#Sch name = JB2
set_property -dict { PACKAGE_PIN B15   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[2]}];#Sch name = JB3
set_property -dict { PACKAGE_PIN B16   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {dhtio[3]}];#Sch name = JB4
set_property -dict { PACKAGE_PIN A15   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[0]}];#Sch name = JB7
set_property -dict { PACKAGE_PIN A17   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[1]}];#Sch name = JB8
set_property -dict { PACKAGE_PIN C15   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[2]}];#Sch name = JB9
set_property -dict { PACKAGE_PIN C16   IOSTANDARD LVCMOS33 } [get_ports {fire_servo_pwm[3]}];#Sch name = JB10

## ===================================================================
## OV7670 카메라 픽셀 데이터 
## PMOD JA 핀 그룹 (Basys-3-Master.xdc 가져옴)
## ===================================================================
set_property -dict { PACKAGE_PIN J1  IOSTANDARD LVCMOS33 } [get_ports {pdata[7]}]
set_property -dict { PACKAGE_PIN L2  IOSTANDARD LVCMOS33 } [get_ports {pdata[5]}]
set_property -dict { PACKAGE_PIN J2  IOSTANDARD LVCMOS33 } [get_ports {pdata[3]}]
set_property -dict { PACKAGE_PIN G2  IOSTANDARD LVCMOS33 } [get_ports {pdata[1]}]
set_property -dict { PACKAGE_PIN H1  IOSTANDARD LVCMOS33 } [get_ports {pdata[6]}]
set_property -dict { PACKAGE_PIN K2  IOSTANDARD LVCMOS33 } [get_ports {pdata[4]}]
set_property -dict { PACKAGE_PIN H2  IOSTANDARD LVCMOS33 } [get_ports {pdata[2]}]
set_property -dict { PACKAGE_PIN G3  IOSTANDARD LVCMOS33 } [get_ports {pdata[0]}]

## ===================================================================
## OV7670 카메라 SCCB 및 제어 신호
## PMOD JXADC 핀 그룹 사용 (기존 JB 충돌 회피)
## ===================================================================
set_property -dict { PACKAGE_PIN J3   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {sda}]
set_property -dict { PACKAGE_PIN L3   IOSTANDARD LVCMOS33 } [get_ports {vsync}]
set_property -dict { PACKAGE_PIN K3   IOSTANDARD LVCMOS33 PULLUP true } [get_ports {scl}]
set_property -dict { PACKAGE_PIN M3   IOSTANDARD LVCMOS33 } [get_ports {href}]
set_property -dict { PACKAGE_PIN M1   IOSTANDARD LVCMOS33 } [get_ports {xclk}]
set_property -dict { PACKAGE_PIN N1   IOSTANDARD LVCMOS33 } [get_ports {pclk}]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets pclk_IBUF]

## ===================================================================
## VGA 커넥터
## ===================================================================
set_property -dict { PACKAGE_PIN G19  IOSTANDARD LVCMOS33 } [get_ports {port_red[0]}]
set_property -dict { PACKAGE_PIN H19  IOSTANDARD LVCMOS33 } [get_ports {port_red[1]}]
set_property -dict { PACKAGE_PIN J19  IOSTANDARD LVCMOS33 } [get_ports {port_red[2]}]
set_property -dict { PACKAGE_PIN N19  IOSTANDARD LVCMOS33 } [get_ports {port_red[3]}]
set_property -dict { PACKAGE_PIN N18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[0]}]
set_property -dict { PACKAGE_PIN L18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[1]}]
set_property -dict { PACKAGE_PIN K18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[2]}]
set_property -dict { PACKAGE_PIN J18  IOSTANDARD LVCMOS33 } [get_ports {port_blue[3]}]
set_property -dict { PACKAGE_PIN J17  IOSTANDARD LVCMOS33 } [get_ports {port_green[0]}]
set_property -dict { PACKAGE_PIN H17  IOSTANDARD LVCMOS33 } [get_ports {port_green[1]}]
set_property -dict { PACKAGE_PIN G17  IOSTANDARD LVCMOS33 } [get_ports {port_green[2]}]
set_property -dict { PACKAGE_PIN D17  IOSTANDARD LVCMOS33 } [get_ports {port_green[3]}]
set_property -dict { PACKAGE_PIN P19  IOSTANDARD LVCMOS33 } [get_ports h_sync]
set_property -dict { PACKAGE_PIN R19  IOSTANDARD LVCMOS33 } [get_ports v_sync]

## Switches
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
