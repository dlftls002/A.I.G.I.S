set root_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root_dir vivado]

create_project basys3_secure_v2 $project_dir -force -part xc7a35tcpg236-1
set_property board_part digilentinc.com:basys3:part0:1.2 [current_project]

set aes_dir    [file join $root_dir rtl aes_gcm]
set secure_dir [file join $root_dir rtl secure]
set legacy_dir [file join $root_dir rtl legacy]
set vision_dir [file join $legacy_dir vision RTL]

set rtl_files [list \
    [file join $aes_dir aes_pkg.sv] \
    [file join $aes_dir aes_add_round_key.sv] \
    [file join $aes_dir aes_sub_bytes.sv] \
    [file join $aes_dir aes_shift_rows.sv] \
    [file join $aes_dir aes_mix_columns.sv] \
    [file join $aes_dir aes_encrypt_round.sv] \
    [file join $aes_dir aes128_pipelined_encrypt_core.sv] \
    [file join $aes_dir aes128_encrypt_block.sv] \
    [file join $aes_dir aes128_key_schedule.sv] \
    [file join $aes_dir aes_gcm_ghash.sv] \
    [file join $aes_dir aes128_gcm_encrypt_block.sv] \
    [file join $aes_dir aes128_gcm_decrypt_block.sv] \
    [file join $aes_dir aes128_gcm_encrypt_ip.sv] \
    [file join $aes_dir aes128_gcm_decrypt_ip.sv] \
    [file join $legacy_dir spi_slave.sv] \
    [file join $legacy_dir rack_servo_controller.sv] \
    [file join $legacy_dir fire_servo_controller.sv] \
    [file join $legacy_dir dht11_controller.v] \
    [file join $vision_dir CAM_Set CAM_Set.sv] \
    [file join $vision_dir CAM_Set OV7670MemController.sv] \
    [file join $vision_dir CAM_Set OV7670_Controller.sv] \
    [file join $vision_dir CAM_Set OV7670_attribute_setting.sv] \
    [file join $vision_dir CAM_Set UpScaleImgReader.sv] \
    [file join $vision_dir CAM_Set frameBuffer.sv] \
    [file join $vision_dir CAM_Set sccb_master.sv] \
    [file join $vision_dir VGA_Decoder.sv] \
    [file join $vision_dir LED_Set led_zone_pkg.sv] \
    [file join $vision_dir UI_Set Drone_detector Drone_Classification_Color.sv] \
    [file join $vision_dir LED_Set led_zone_monitor.sv] \
    [file join $vision_dir LED_Set unit_status.sv] \
    [file join $vision_dir LED_Set status_packer.sv] \
    [file join $vision_dir LED_Set LED_Set.sv] \
    [file join $vision_dir Frame_Set Frame_Set.sv] \
    [file join $secure_dir aes_gcm_encrypt_packet.sv] \
    [file join $secure_dir aes_gcm_decrypt_packet.sv] \
    [file join $secure_dir basys3_secure_rack_control.sv]]

add_files -norecurse $rtl_files
import_ip -files [file join $root_dir ip clk_wiz_0 clk_wiz_0.xci]
# The original camera project lets Clock Wizard instantiate an IBUF on clk_in1.
# In this integrated top the same board clock also drives the AES/SPI logic, so
# leave input buffering to the top-level port and share that buffered clock.
set_property -dict [list \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.CLK_IN1_BOARD_INTERFACE {Custom}] [get_ips clk_wiz_0]
set_property generate_synth_checkpoint false [get_files clk_wiz_0.xci]
generate_target all [get_ips clk_wiz_0]
add_files -fileset constrs_1 -norecurse \
    [file join $root_dir constraints basys3_secure.xdc]

set_property top basys3_secure_rack_control [get_filesets sources_1]
set_property target_language Verilog [current_project]
update_compile_order -fileset sources_1

puts "CREATED: [file join $project_dir basys3_secure_v2.xpr]"
close_project
