module aes_encrypt_round (
    input  logic [127:0] state_in,
    input  logic [127:0] round_key,
    input  logic         final_round,
    output logic [127:0] state_out
);
    logic [127:0] sub_state;
    logic [127:0] shifted_state;
    logic [127:0] mixed_state;
    logic [127:0] selected_state;

    aes_sub_bytes u_sub_bytes (
        .state_in  (state_in),
        .state_out (sub_state)
    );

    aes_shift_rows u_shift_rows (
        .state_in  (sub_state),
        .state_out (shifted_state)
    );

    aes_mix_columns u_mix_columns (
        .state_in  (shifted_state),
        .state_out (mixed_state)
    );

    assign selected_state = final_round ? shifted_state : mixed_state;

    aes_add_round_key u_add_round_key (
        .state_in  (selected_state),
        .round_key (round_key),
        .state_out (state_out)
    );
endmodule
