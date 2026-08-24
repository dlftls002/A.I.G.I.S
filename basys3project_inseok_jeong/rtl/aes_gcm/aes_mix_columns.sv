module aes_mix_columns (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);
    import aes_pkg::*;
    logic [7:0] a0, a1, a2, a3;
    integer column;

    always_comb begin
        state_out = '0;
        for (column = 0; column < 4; column = column + 1) begin
            a0 = state_in[127-(column*32) -: 8];
            a1 = state_in[119-(column*32) -: 8];
            a2 = state_in[111-(column*32) -: 8];
            a3 = state_in[103-(column*32) -: 8];
            state_out[127-(column*32) -: 8] =
                gf_mul(a0, 8'h02) ^ gf_mul(a1, 8'h03) ^ a2 ^ a3;
            state_out[119-(column*32) -: 8] =
                a0 ^ gf_mul(a1, 8'h02) ^ gf_mul(a2, 8'h03) ^ a3;
            state_out[111-(column*32) -: 8] =
                a0 ^ a1 ^ gf_mul(a2, 8'h02) ^ gf_mul(a3, 8'h03);
            state_out[103-(column*32) -: 8] =
                gf_mul(a0, 8'h03) ^ a1 ^ a2 ^ gf_mul(a3, 8'h02);
        end
    end
endmodule
