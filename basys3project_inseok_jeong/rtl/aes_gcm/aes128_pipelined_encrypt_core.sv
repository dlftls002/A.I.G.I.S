module aes128_pipelined_encrypt_core (
    input  logic          clk,
    input  logic          rst_n,
    input  logic [1407:0] round_keys,
    input  logic [127:0]  input_block,
    input  logic [7:0]    input_tag,
    input  logic          input_valid,
    output logic          input_ready,
    output logic [127:0]  output_block,
    output logic [7:0]    output_tag,
    output logic          output_valid,
    input  logic          output_ready,
    output logic          busy
);
    logic [127:0] stage_state [0:9];
    logic [7:0]   stage_tag [0:9];
    logic [9:0]   stage_valid;
    logic [127:0] round_input [0:9];
    logic [127:0] round_output [0:9];
    logic         pipeline_enable;
    integer       stage_index;

    assign pipeline_enable = !stage_valid[9] || output_ready;
    assign input_ready = pipeline_enable;
    assign output_block = stage_state[9];
    assign output_tag = stage_tag[9];
    assign output_valid = stage_valid[9];
    assign busy = |stage_valid;

    assign round_input[0] = input_block ^ round_keys[1407 -: 128];
    generate
        genvar round_index;
        for (round_index = 0; round_index < 10; round_index = round_index + 1) begin : g_round
            if (round_index > 0)
                assign round_input[round_index] = stage_state[round_index-1];

            aes_encrypt_round u_round (
                .state_in(round_input[round_index]),
                .round_key(round_keys[1407-((round_index+1)*128) -: 128]),
                .final_round(round_index == 9),
                .state_out(round_output[round_index])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stage_valid <= '0;
            for (stage_index = 0; stage_index < 10; stage_index = stage_index + 1) begin
                stage_state[stage_index] <= '0;
                stage_tag[stage_index] <= '0;
            end
        end else if (pipeline_enable) begin
            stage_valid[0] <= input_valid;
            if (input_valid) begin
                stage_state[0] <= round_output[0];
                stage_tag[0] <= input_tag;
            end

            for (stage_index = 1; stage_index < 10; stage_index = stage_index + 1) begin
                stage_valid[stage_index] <= stage_valid[stage_index-1];
                if (stage_valid[stage_index-1]) begin
                    stage_state[stage_index] <= round_output[stage_index];
                    stage_tag[stage_index] <= stage_tag[stage_index-1];
                end
            end
        end
    end
endmodule
