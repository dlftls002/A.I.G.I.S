module aes128_encrypt_block (
    input  logic          clk,
    input  logic          rst_n,
    input  logic [1407:0] round_keys,
    input  logic [127:0]  plaintext,
    input  logic          input_valid,
    output logic          input_ready,
    output logic [127:0]  ciphertext,
    output logic          output_valid,
    input  logic          output_ready,
    output logic          busy
);
    aes128_pipelined_encrypt_core u_encrypt_core (
        .clk(clk),
        .rst_n(rst_n),
        .round_keys(round_keys),
        .input_block(plaintext),
        .input_tag(8'h00),
        .input_valid(input_valid),
        .input_ready(input_ready),
        .output_block(ciphertext),
        .output_tag(),
        .output_valid(output_valid),
        .output_ready(output_ready),
        .busy(busy)
    );
endmodule
