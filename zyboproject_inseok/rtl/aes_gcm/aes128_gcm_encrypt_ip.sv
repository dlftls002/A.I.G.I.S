module aes128_gcm_encrypt_ip #(
    parameter logic [31:0] BOARD_ID = 32'hA5A5_0001
)(
    input  logic          clk,
    input  logic          rst_n,

    // Key Interface
    input  logic [127:0]  key_data,
    input  logic          key_load,
    input  logic          key_clear,
    output logic          key_ready,
    output logic          key_valid,
    output logic          key_busy,

    // Auto-IV Control & Packet Interface
    input  logic          auto_iv_en,      // 1: Auto 64-bit Counter IV (PL Mode), 0: External IV Input (PS Mode)
    input  logic [95:0]   iv,              // External IV input (used when auto_iv_en == 0)
    output logic [95:0]   active_iv,       // Active IV applied to current transaction (attach to packet header)

    // Data Interface
    input  logic [127:0]  plaintext,
    input  logic          plaintext_valid,
    output logic          plaintext_ready,

    output logic [127:0]  ciphertext,
    output logic [127:0]  tag,
    output logic          ciphertext_valid,
    input  logic          ciphertext_ready,
    output logic          busy
);
    logic [1407:0] round_keys;
    logic          core_rst_n;
    logic          key_schedule_ready;
    logic          gcm_input_ready;

    // 64-bit Hardware Auto-IV Counter
    logic [63:0] iv_counter;
    logic [95:0] auto_generated_iv;

    assign auto_generated_iv = {BOARD_ID, iv_counter};
    assign active_iv = auto_iv_en ? auto_generated_iv : iv;

    // Increment IV Counter when an encryption transaction completes successfully
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iv_counter <= 64'd0;
        end else if (key_clear) begin
            iv_counter <= 64'd0;
        end else if (ciphertext_valid && ciphertext_ready && auto_iv_en) begin
            iv_counter <= iv_counter + 1'b1;
        end
    end

    assign core_rst_n = rst_n && key_valid;
    assign key_ready = key_schedule_ready && !busy;
    assign plaintext_ready =
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

    aes128_gcm_encrypt_block u_gcm_encrypt (
        .clk(clk),
        .rst_n(core_rst_n),
        .round_keys(round_keys),
        .iv(active_iv),
        .plaintext(plaintext),
        .input_valid(plaintext_valid && plaintext_ready),
        .input_ready(gcm_input_ready),
        .ciphertext(ciphertext),
        .tag(tag),
        .output_valid(ciphertext_valid),
        .output_ready(ciphertext_ready),
        .busy(busy)
    );
endmodule
