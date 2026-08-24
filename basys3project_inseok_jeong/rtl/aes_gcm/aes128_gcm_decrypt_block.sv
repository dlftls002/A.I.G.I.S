module aes128_gcm_decrypt_block (
    input  logic          clk,
    input  logic          rst_n,
    input  logic [1407:0] round_keys,

    input  logic [95:0]   iv,
    input  logic [127:0]  ciphertext,
    input  logic [127:0]  tag,
    input  logic          input_valid,
    output logic          input_ready,

    output logic [127:0]  plaintext,
    output logic          auth_valid,
    output logic          output_valid,
    input  logic          output_ready,
    output logic          busy
);
    typedef enum logic [3:0] {
        IDLE,
        HASH_SUBMIT,
        HASH_WAIT,
        MASK_SUBMIT,
        MASK_WAIT,
        STREAM_SUBMIT,
        STREAM_WAIT,
        GHASH_SUBMIT,
        GHASH_WAIT,
        RESULT
    } state_t;

    state_t state;
    logic [95:0]  iv_reg;
    logic [127:0] ciphertext_reg;
    logic [127:0] received_tag;
    logic [127:0] hash_subkey;
    logic [127:0] tag_mask;
    logic [127:0] plaintext_reg;
    logic [127:0] ghash_value;
    logic [127:0] expected_tag;
    logic         ghash_start;
    logic         ghash_ready;
    logic         ghash_valid;
    logic [127:0] aes_input;
    logic         aes_input_valid;
    logic         aes_input_ready;
    logic [127:0] aes_output;
    logic         aes_output_valid;
    logic         aes_output_ready;

    assign input_ready = state == IDLE;
    assign output_valid = state == RESULT;
    assign busy = state != IDLE;
    assign plaintext = auth_valid ? plaintext_reg : 128'b0;
    assign expected_tag = tag_mask ^ ghash_value;

    always_comb begin
        aes_input = 128'b0;
        aes_input_valid = 1'b0;
        aes_output_ready = 1'b0;
        case (state)
            HASH_SUBMIT: begin
                aes_input = 128'b0;
                aes_input_valid = 1'b1;
            end
            HASH_WAIT:
                aes_output_ready = 1'b1;
            MASK_SUBMIT: begin
                aes_input = {iv_reg, 32'h00000001};
                aes_input_valid = 1'b1;
            end
            MASK_WAIT:
                aes_output_ready = 1'b1;
            STREAM_SUBMIT: begin
                aes_input = {iv_reg, 32'h00000002};
                aes_input_valid = 1'b1;
            end
            STREAM_WAIT:
                aes_output_ready = 1'b1;
            default: begin end
        endcase
    end

    aes128_encrypt_block u_aes_encrypt (
        .clk(clk),
        .rst_n(rst_n),
        .round_keys(round_keys),
        .plaintext(aes_input),
        .input_valid(aes_input_valid),
        .input_ready(aes_input_ready),
        .ciphertext(aes_output),
        .output_valid(aes_output_valid),
        .output_ready(aes_output_ready),
        .busy()
    );

    aes_gcm_ghash u_ghash (
        .clk(clk),
        .rst_n(rst_n),
        .start(ghash_start),
        .ready(ghash_ready),
        .hash_subkey(hash_subkey),
        .ciphertext(ciphertext_reg),
        .ghash(ghash_value),
        .output_valid(ghash_valid)
    );

    assign ghash_start = state == GHASH_SUBMIT;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            iv_reg <= '0;
            ciphertext_reg <= '0;
            received_tag <= '0;
            hash_subkey <= '0;
            tag_mask <= '0;
            plaintext_reg <= '0;
            auth_valid <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    auth_valid <= 1'b0;
                    if (input_valid) begin
                        iv_reg <= iv;
                        ciphertext_reg <= ciphertext;
                        received_tag <= tag;
                        state <= HASH_SUBMIT;
                    end
                end
                HASH_SUBMIT:
                    if (aes_input_ready)
                        state <= HASH_WAIT;
                HASH_WAIT: begin
                    if (aes_output_valid) begin
                        hash_subkey <= aes_output;
                        state <= MASK_SUBMIT;
                    end
                end
                MASK_SUBMIT:
                    if (aes_input_ready)
                        state <= MASK_WAIT;
                MASK_WAIT: begin
                    if (aes_output_valid) begin
                        tag_mask <= aes_output;
                        state <= STREAM_SUBMIT;
                    end
                end
                STREAM_SUBMIT:
                    if (aes_input_ready)
                        state <= STREAM_WAIT;
                STREAM_WAIT: begin
                    if (aes_output_valid) begin
                        plaintext_reg <= ciphertext_reg ^ aes_output;
                        state <= GHASH_SUBMIT;
                    end
                end
                GHASH_SUBMIT:
                    if (ghash_ready)
                        state <= GHASH_WAIT;
                GHASH_WAIT: begin
                    if (ghash_valid) begin
                        auth_valid <= received_tag == expected_tag;
                        state <= RESULT;
                    end
                end
                RESULT:
                    if (output_ready)
                        state <= IDLE;
                default:
                    state <= IDLE;
            endcase
        end
    end
endmodule
