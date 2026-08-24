`timescale 1ns/1ps

// Converts one legacy 128-bit payload into the common 48-byte secure frame.
// Wire order (MSB first): MAGIC(2) | TYPE(1) | LENGTH(1) | IV(12) | C(16) | TAG(16)
module aes_gcm_encrypt_packet (
    input  logic         clk,
    input  logic         rst_n,

    input  logic [127:0] key_data,
    input  logic         key_load,
    output logic         key_ready,
    output logic         key_valid,

    input  logic [7:0]   packet_type,
    input  logic [95:0]  packet_iv,
    input  logic [127:0] plaintext,
    input  logic         plaintext_valid,
    output logic         plaintext_ready,

    output logic [383:0] packet,
    output logic         packet_valid,
    input  logic         packet_ready,
    output logic         busy
);
    localparam logic [15:0] FRAME_MAGIC = 16'hA55A;
    localparam logic [7:0]  FRAME_LENGTH = 8'd16;

    logic [7:0]  type_reg;
    logic [95:0] iv_reg;
    logic [127:0] ciphertext;
    logic [127:0] tag;
    logic         ciphertext_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            type_reg <= 8'h00;
            iv_reg   <= 96'h0;
        end else if (plaintext_valid && plaintext_ready) begin
            type_reg <= packet_type;
            iv_reg   <= packet_iv;
        end
    end

    assign packet       = {FRAME_MAGIC, type_reg, FRAME_LENGTH,
                           iv_reg, ciphertext, tag};
    assign packet_valid = ciphertext_valid;

    aes128_gcm_encrypt_ip #(
        .BOARD_ID(32'h0000_0000)
    ) u_encrypt_ip (
        .clk              (clk),
        .rst_n            (rst_n),
        .key_data         (key_data),
        .key_load         (key_load),
        .key_clear        (1'b0),
        .key_ready        (key_ready),
        .key_valid        (key_valid),
        .key_busy         (),
        .auto_iv_en       (1'b0),
        .iv               (packet_iv),
        .active_iv        (),
        .plaintext        (plaintext),
        .plaintext_valid  (plaintext_valid),
        .plaintext_ready  (plaintext_ready),
        .ciphertext       (ciphertext),
        .tag              (tag),
        .ciphertext_valid (ciphertext_valid),
        .ciphertext_ready (packet_ready),
        .busy             (busy)
    );
endmodule

