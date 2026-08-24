`timescale 1ns/1ps

module tb_crypto_packet;
    localparam logic [127:0] GOOD_KEY =
        128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
    localparam logic [127:0] BAD_KEY =
        128'hFFFA_FFFA_FFFA_FFFA_FFFA_FFFA_FFFA_FFFA;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic enc_key_load, good_key_load, bad_key_load;
    wire enc_key_ready, enc_key_valid;
    wire good_key_ready, good_key_valid;
    wire bad_key_ready, bad_key_valid;

    logic [127:0] plaintext;
    logic [95:0] iv;
    logic plaintext_valid;
    wire plaintext_ready;
    wire [383:0] encrypted_packet;
    wire encrypted_packet_valid;
    logic encrypted_packet_ready;

    logic [383:0] saved_packet;
    logic saved_valid;

    logic dec_packet_valid;
    wire good_packet_ready, bad_packet_ready;
    wire [127:0] good_plaintext, bad_plaintext;
    wire good_plaintext_valid, bad_plaintext_valid;
    wire good_auth, bad_auth;

    aes_gcm_encrypt_packet u_encrypt (
        .clk(clk), .rst_n(rst_n),
        .key_data(GOOD_KEY), .key_load(enc_key_load),
        .key_ready(enc_key_ready), .key_valid(enc_key_valid),
        .packet_type(8'h02), .packet_iv(iv),
        .plaintext(plaintext), .plaintext_valid(plaintext_valid),
        .plaintext_ready(plaintext_ready),
        .packet(encrypted_packet), .packet_valid(encrypted_packet_valid),
        .packet_ready(encrypted_packet_ready), .busy()
    );

    aes_gcm_decrypt_packet u_decrypt_good (
        .clk(clk), .rst_n(rst_n),
        .key_data(GOOD_KEY), .key_load(good_key_load),
        .key_ready(good_key_ready), .key_valid(good_key_valid),
        .expected_type(8'h02),
        .packet(saved_packet), .packet_valid(dec_packet_valid),
        .packet_ready(good_packet_ready),
        .plaintext(good_plaintext), .plaintext_valid(good_plaintext_valid),
        .auth_valid(good_auth), .plaintext_ready(1'b1), .busy()
    );

    aes_gcm_decrypt_packet u_decrypt_bad (
        .clk(clk), .rst_n(rst_n),
        .key_data(BAD_KEY), .key_load(bad_key_load),
        .key_ready(bad_key_ready), .key_valid(bad_key_valid),
        .expected_type(8'h02),
        .packet(saved_packet), .packet_valid(dec_packet_valid),
        .packet_ready(bad_packet_ready),
        .plaintext(bad_plaintext), .plaintext_valid(bad_plaintext_valid),
        .auth_valid(bad_auth), .plaintext_ready(1'b1), .busy()
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            saved_packet <= '0;
            saved_valid  <= 1'b0;
        end else if (encrypted_packet_valid && encrypted_packet_ready) begin
            saved_packet <= encrypted_packet;
            saved_valid  <= 1'b1;
        end
    end

    initial begin
        enc_key_load = 1'b0;
        good_key_load = 1'b0;
        bad_key_load = 1'b0;
        plaintext = 128'hA55A_0103_7373_6D00_0000_0000_0000_0000;
        iv = 96'h0200_0001_0000_0000_0000_0001;
        plaintext_valid = 1'b0;
        encrypted_packet_ready = 1'b1;
        dec_packet_valid = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        wait (enc_key_ready && good_key_ready && bad_key_ready);
        @(posedge clk);
        enc_key_load = 1'b1;
        good_key_load = 1'b1;
        bad_key_load = 1'b1;
        @(posedge clk);
        enc_key_load = 1'b0;
        good_key_load = 1'b0;
        bad_key_load = 1'b0;

        wait (enc_key_valid && good_key_valid && bad_key_valid);
        wait (plaintext_ready);
        @(posedge clk);
        plaintext_valid = 1'b1;
        @(posedge clk);
        plaintext_valid = 1'b0;

        wait (saved_valid);
        if (saved_packet[383:352] !== 32'hA55A_0210)
            $fatal(1, "48-byte frame header mismatch: %h", saved_packet[383:352]);

        wait (good_packet_ready && bad_packet_ready);
        @(posedge clk);
        dec_packet_valid = 1'b1;
        @(posedge clk);
        dec_packet_valid = 1'b0;

        wait (good_plaintext_valid && bad_plaintext_valid);
        if (!good_auth)
            $fatal(1, "Matching FFFF key failed authentication");
        if (good_plaintext !== plaintext)
            $fatal(1, "Matching FFFF key returned wrong plaintext");
        if (bad_auth)
            $fatal(1, "FFFA mismatch unexpectedly authenticated");
        if (bad_plaintext !== 128'h0)
            $fatal(1, "Failed authentication did not zeroize plaintext");

        $display("PASS: FFFF key decrypts, FFFA key is rejected and zeroized");
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "Simulation timeout");
    end
endmodule

