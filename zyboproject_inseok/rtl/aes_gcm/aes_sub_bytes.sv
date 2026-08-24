module aes_sub_bytes (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);
    import aes_pkg::*;
    integer i;
    always_comb begin
        for (i = 0; i < 16; i = i + 1)
            state_out[127-(i*8) -: 8] = sbox(state_in[127-(i*8) -: 8]);
    end
endmodule
