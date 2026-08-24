module aes128_gcm_decrypt_ip (
    input  logic          clk,
    input  logic          rst_n,

    input  logic [127:0]  key_data,
    input  logic          key_load,
    input  logic          key_clear,
    output logic          key_ready,
    output logic          key_valid,
    output logic          key_busy,

    input  logic [95:0]   iv,
    input  logic [127:0]  ciphertext,
    input  logic [127:0]  tag,
    input  logic          ciphertext_valid,
    output logic          ciphertext_ready,

    output logic [127:0]  plaintext,
    output logic          auth_valid,
    output logic          plaintext_valid,
    input  logic          plaintext_ready,
    output logic          busy
);
    logic [1407:0] round_keys;
    logic          core_rst_n;
    logic          key_schedule_ready;
    logic          gcm_input_ready;

    assign core_rst_n = rst_n && key_valid;
    assign key_ready = key_schedule_ready && !busy;
    assign ciphertext_ready =
        gcm_input_ready && key_valid && !key_load && !key_clear;

    aes128_key_schedule u_key_schedule (
        .clk(clk),
        .rst_n(rst_n),
        .key_set_valid(key_load && !busy),
        .key_set_ready(key_schedule_ready),
        .key_set_data(key_data),
        .key_clear(key_clear),
        .key_valid(key_valid),
        .busy(key_busy),
        .round_keys(round_keys)
    );

    aes128_gcm_decrypt_block u_gcm_decrypt (
        .clk(clk),
        .rst_n(core_rst_n),
        .round_keys(round_keys),
        .iv(iv),
        .ciphertext(ciphertext),
        .tag(tag),
        .input_valid(ciphertext_valid && ciphertext_ready),
        .input_ready(gcm_input_ready),
        .plaintext(plaintext),
        .auth_valid(auth_valid),
        .output_valid(plaintext_valid),
        .output_ready(plaintext_ready),
        .busy(busy)
    );
endmodule
