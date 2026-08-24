set root_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root_dir vivado_jetson_secure]

create_project zybo_secure_jetson $project_dir -force -part xc7z020clg400-1

set aes_dir    [file join $root_dir rtl aes_gcm]
set secure_dir [file join $root_dir rtl secure]
set legacy_dir [file join $root_dir rtl legacy]

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
    [file join $legacy_dir uart_rx.sv] \
    [file join $legacy_dir uart_tx.sv] \
    [file join $legacy_dir spi_slave.sv] \
    [file join $legacy_dir spi_master.sv] \
    [file join $legacy_dir pxc_sync_fifo.sv] \
    [file join $secure_dir aes_gcm_encrypt_packet.sv] \
    [file join $secure_dir aes_gcm_decrypt_packet.sv] \
    [file join $secure_dir secure_uart_frame_rx.sv] \
    [file join $secure_dir secure_uart_frame_tx.sv] \
    [file join $secure_dir zybo_session_manager.sv] \
    [file join $secure_dir zybo_secure_control_unit_v2.sv]]

add_files -norecurse $rtl_files
add_files -fileset constrs_1 -norecurse \
    [file join $root_dir constraints zybo_secure.xdc]

set_property top zybo_secure_control_unit_v2 [get_filesets sources_1]
set_property target_language Verilog [current_project]
update_compile_order -fileset sources_1

puts "CREATED: [file join $project_dir zybo_secure_jetson.xpr]"
close_project
