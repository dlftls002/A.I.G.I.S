set root_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root_dir vivado_tests tb_crypto_packet]
set aes_dir    [file join $root_dir rtl aes_gcm]
set secure_dir [file join $root_dir rtl secure]

create_project tb_crypto_packet $project_dir -force -part xc7z020clg400-1
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
    [file join $secure_dir aes_gcm_encrypt_packet.sv] \
    [file join $secure_dir aes_gcm_decrypt_packet.sv]]

add_files -norecurse $rtl_files
add_files -fileset sim_1 -norecurse [file join $root_dir tb tb_crypto_packet.sv]
set_property top tb_crypto_packet [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation
run all
close_sim
close_project

set sim_log [file join $project_dir tb_crypto_packet.sim sim_1 behav xsim simulate.log]
set fh [open $sim_log r]
set text [read $fh]
close $fh
if {[string first "PASS: FFFF key decrypts, FFFA key is rejected and zeroized" $text] < 0} {
    error "PACKET TEST FAILED: $sim_log"
}
puts "PACKET TEST VERIFIED"

