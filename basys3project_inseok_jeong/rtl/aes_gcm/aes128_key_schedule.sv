module aes128_key_schedule (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          key_set_valid,
    output logic          key_set_ready,
    input  logic [127:0]  key_set_data,
    input  logic          key_clear,
    output logic          key_valid,
    output logic          busy,
    output logic [1407:0] round_keys
);
    import aes_pkg::*;

    logic [127:0] working_key;
    logic [3:0] round_number;
    logic [127:0] generated_key;

    assign key_set_ready = !busy;
    assign generated_key = next_round_key(working_key, round_number);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            working_key <= '0;
            round_number <= '0;
            round_keys <= '0;
            key_valid <= 1'b0;
            busy <= 1'b0;
        end else begin
            if (key_clear) begin
                working_key <= '0;
                round_number <= '0;
                round_keys <= '0;
                key_valid <= 1'b0;
                busy <= 1'b0;
            end else if (key_set_valid && key_set_ready) begin
                working_key <= key_set_data;
                round_keys[1407 -: 128] <= key_set_data;
                round_number <= 4'd1;
                key_valid <= 1'b0;
                busy <= 1'b1;
            end else if (busy) begin
                working_key <= generated_key;
                round_keys[1407-(round_number*128) -: 128] <= generated_key;
                if (round_number == 4'd10) begin
                    round_number <= '0;
                    key_valid <= 1'b1;
                    busy <= 1'b0;
                end else begin
                    round_number <= round_number + 1'b1;
                end
            end
        end
    end
endmodule
