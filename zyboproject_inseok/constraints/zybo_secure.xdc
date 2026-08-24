## ZYBO 보드용 XDC 제약 조건 파일 (zybo_control_unit.xdc)
## 이 파일은 예시로 작성되었으며, 실제 연결할 PMOD/UART 핀 번호에 맞춰 수정이 필요합니다.

## Clock signal (ZYBO Z7 기준 K17 125MHz, 기존 ZYBO는 L16 50MHz 등)
set_property -dict { PACKAGE_PIN K17   IOSTANDARD LVCMOS33 } [get_ports { clk }]; 
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { clk }];

## Reset Button
set_property -dict { PACKAGE_PIN K18   IOSTANDARD LVCMOS33 } [get_ports { rst }];

## ===================================================================
## UART Interface (관제실 PC <-> ZYBO)
## PMOD JD 포트 사용
## ===================================================================
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { uart_rx_in }];
set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { uart_tx_out }];

## ===================================================================
## SPI Master Interface (ZYBO <-> Basys3)
## PMOD JE 포트 사용
## ===================================================================
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { sclk_out }];						 
set_property -dict { PACKAGE_PIN W16   IOSTANDARD LVCMOS33 } [get_ports { mosi_out }];                     
set_property -dict { PACKAGE_PIN J15   IOSTANDARD LVCMOS33 } [get_ports { cs_n_out }];                          
set_property -dict { PACKAGE_PIN H15   IOSTANDARD LVCMOS33 } [get_ports { miso_in  }];   

## ===================================================================
## SPI Slave Interface (Jetson Nano <-> ZYBO)
## PMOD JA 포트 사용
## ===================================================================
set_property -dict { PACKAGE_PIN N15   IOSTANDARD LVCMOS33 } [get_ports { sclk_in }]; 
set_property -dict { PACKAGE_PIN L14   IOSTANDARD LVCMOS33 } [get_ports { mosi_in }]; 
set_property -dict { PACKAGE_PIN K16   IOSTANDARD LVCMOS33 } [get_ports { cs_n_in }]; 
set_property -dict { PACKAGE_PIN K14   IOSTANDARD LVCMOS33 } [get_ports { miso_out }];
       