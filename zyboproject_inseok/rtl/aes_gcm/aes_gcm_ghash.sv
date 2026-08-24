module aes_gcm_ghash (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          start,
    output logic          ready,
    input  logic [127:0]  hash_subkey,
    input  logic [127:0]  ciphertext,
    output logic [127:0]  ghash,
    output logic          output_valid
);
    logic [127:0] z;
    logic [127:0] v;
    logic [127:0] y;
    logic [127:0] h_reg;
    logic [7:0]   bit_index;
    logic         second_multiply;
    logic         busy;
    logic [127:0] z_step;
    logic [127:0] v_step;

    assign ready = !busy;
    assign z_step = y[127-bit_index] ? (z ^ v) : z;
    assign v_step = v[0]
        ? ((v >> 1) ^ 128'he1000000000000000000000000000000)
        : (v >> 1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            z <= '0;
            v <= '0;
            y <= '0;
            h_reg <= '0;
            bit_index <= '0;
            second_multiply <= 1'b0;
            busy <= 1'b0;
            ghash <= '0;
            output_valid <= 1'b0;
        end else begin
            output_valid <= 1'b0;
            if (start && ready) begin
                z <= 128'b0;
                v <= hash_subkey;
                y <= ciphertext;
                h_reg <= hash_subkey;
                bit_index <= 8'd0;
                second_multiply <= 1'b0;
                busy <= 1'b1;
            end else if (busy) begin
                if (bit_index == 8'd127) begin
                    if (!second_multiply) begin
                        // GHASH(C) followed by GHASH of the no-AAD length block.
                        z <= 128'b0;
                        v <= h_reg;
                        y <= z_step ^ {64'd0, 64'd128};
                        bit_index <= 8'd0;
                        second_multiply <= 1'b1;
                    end else begin
                        ghash <= z_step;
                        busy <= 1'b0;
                        output_valid <= 1'b1;
                    end
                end else begin
                    z <= z_step;
                    v <= v_step;
                    bit_index <= bit_index + 1'b1;
                end
            end
        end
    end
endmodule
