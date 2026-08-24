`timescale 1ns/1ps

// Validates and decrypts one common 48-byte secure frame.
// A frame with a bad header is consumed without entering the AES-GCM core.
module aes_gcm_decrypt_packet (
    input  logic         clk,
    input  logic         rst_n,

    input  logic [127:0] key_data,
    input  logic         key_load,
    output logic         key_ready,
    output logic         key_valid,

    input  logic [7:0]   expected_type,
    input  logic [383:0] packet,
    input  logic         packet_valid,
    output logic         packet_ready,

    output logic [127:0] plaintext,
    output logic         plaintext_valid,
    output logic         auth_valid,
    input  logic         plaintext_ready,
    output logic         busy
);
    wire header_ok = (packet[383:368] == 16'hA55A) &&
                     (packet[367:360] == expected_type) &&
                     (packet[359:352] == 8'd16);

    logic aes_input_ready;

    // Invalid framing is discarded immediately. Valid framing obeys the
    // crypto core's ready/valid handshake.
    assign packet_ready = header_ok ? aes_input_ready : 1'b1;

    aes128_gcm_decrypt_ip u_decrypt_ip (
        .clk              (clk),
        .rst_n            (rst_n),
        .key_data         (key_data),
        .key_load         (key_load),
        .key_clear        (1'b0),
        .key_ready        (key_ready),
        .key_valid        (key_valid),
        .key_busy         (),
        .iv               (packet[351:256]),
        .ciphertext       (packet[255:128]),
        .tag              (packet[127:0]),
        .ciphertext_valid (packet_valid && header_ok),
        .ciphertext_ready (aes_input_ready),
        .plaintext        (plaintext),
        .auth_valid       (auth_valid),
        .plaintext_valid  (plaintext_valid),
        .plaintext_ready  (plaintext_ready),
        .busy             (busy)
    );
endmodule

