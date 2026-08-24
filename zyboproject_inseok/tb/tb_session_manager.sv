`timescale 1ns/1ps

module tb_session_manager;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic pc_basys_crypto_key_active = 1'b0;
    wire [127:0] pc_basys_requested_key;
    wire pc_basys_key_reload;
    logic pc_basys_key_reload_done = 1'b0;
    logic jetson_crypto_key_active = 1'b0;
    wire [127:0] jetson_requested_key;
    wire jetson_key_reload;
    logic jetson_key_reload_done = 1'b0;
    wire pc_basys_traffic_enable;
    wire jetson_traffic_enable;
    wire [127:0] current_random;
    wire tx_valid;
    logic tx_ready = 1'b1;
    wire [1:0] tx_dest;
    wire [7:0] tx_type;
    wire [127:0] tx_payload;
    logic rx_valid = 1'b0;
    logic [1:0] rx_source = 2'd0;
    logic [7:0] rx_type = 8'h00;
    logic [127:0] rx_payload = 128'h0;

    logic basys_ready_pending = 1'b0;
    logic basys_commit_pending = 1'b0;
    logic basys_confirm_pending = 1'b0;
    logic respond_jetson = 1'b0;
    integer completed_group_sessions = 0;
    integer completed_jetson_sessions = 0;
    integer enable_jetson_countdown = -1;
    logic previous_group_normal = 1'b0;
    logic previous_jetson_normal = 1'b0;

    localparam logic [127:0] MASTER_KEY =
        128'h6C8E_9CF5_7093_2BD5_A3F1_04D7_B89E_62C1;
    localparam logic [127:0] CHALLENGE_CONST =
        128'h5A5A_5A5A_5A5A_5A5A_A5A5_A5A5_A5A5_A5A5;
    localparam logic [127:0] RESPONSE_CONST =
        128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

    zybo_session_manager #(
        .SYS_CLK_FREQ(100),
        .SESSION_SECONDS(3)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .pc_basys_crypto_key_active(pc_basys_crypto_key_active),
        .pc_basys_requested_key(pc_basys_requested_key),
        .pc_basys_key_reload(pc_basys_key_reload),
        .pc_basys_key_reload_done(pc_basys_key_reload_done),
        .jetson_crypto_key_active(jetson_crypto_key_active),
        .jetson_requested_key(jetson_requested_key),
        .jetson_key_reload(jetson_key_reload),
        .jetson_key_reload_done(jetson_key_reload_done),
        .pc_basys_traffic_enable(pc_basys_traffic_enable),
        .jetson_traffic_enable(jetson_traffic_enable),
        .current_random(current_random),
        .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx_dest(tx_dest), .tx_type(tx_type), .tx_payload(tx_payload),
        .rx_valid(rx_valid), .rx_source(rx_source),
        .rx_type(rx_type), .rx_payload(rx_payload)
    );

    always_ff @(posedge clk) begin
        rx_valid <= 1'b0;
        pc_basys_key_reload_done <= 1'b0;
        jetson_key_reload_done <= 1'b0;

        if (pc_basys_key_reload)
            pc_basys_key_reload_done <= 1'b1;
        if (jetson_key_reload)
            jetson_key_reload_done <= 1'b1;

        if (enable_jetson_countdown > 0)
            enable_jetson_countdown <= enable_jetson_countdown - 1;
        else if (enable_jetson_countdown == 0) begin
            respond_jetson <= 1'b1;
            enable_jetson_countdown <= -1;
        end

        if (tx_valid && tx_ready) begin
            case (tx_type)
                8'h12: begin
                    rx_valid <= 1'b1; rx_source <= 2'd0;
                    rx_type <= 8'h13; rx_payload <= tx_payload;
                end
                8'h22: basys_ready_pending <= 1'b1;
                8'h24: begin
                    if (basys_ready_pending) begin
                        rx_valid <= 1'b1; rx_source <= 2'd1; rx_type <= 8'h23;
                        rx_payload <= 128'h0; basys_ready_pending <= 1'b0;
                    end else if (basys_commit_pending) begin
                        rx_valid <= 1'b1; rx_source <= 2'd1; rx_type <= 8'h26;
                        rx_payload <= 128'h0; basys_commit_pending <= 1'b0;
                    end
                end
                8'h14: begin
                    rx_valid <= 1'b1; rx_source <= 2'd0;
                    rx_type <= 8'h15; rx_payload <= tx_payload;
                end
                8'h25: basys_commit_pending <= 1'b1;
                8'h16: begin
                    rx_valid <= 1'b1; rx_source <= 2'd0;
                    rx_type <= 8'h17; rx_payload <= tx_payload;
                end
                8'h27: basys_confirm_pending <= 1'b1;
                8'h29: if (basys_confirm_pending) begin
                    rx_valid <= 1'b1; rx_source <= 2'd1; rx_type <= 8'h28;
                    rx_payload <= 128'h0; basys_confirm_pending <= 1'b0;
                end

                8'h32: if (respond_jetson) begin
                    if (tx_payload == 128'h0)
                        $fatal(1, "JETSON KEY_UPDATE must carry R");
                    rx_valid <= 1'b1; rx_source <= 2'd2;
                    rx_type <= 8'h33; rx_payload <= 128'h0;
                end
                8'h34: if (respond_jetson) begin
                    if (tx_payload != 128'h0)
                        $fatal(1, "JETSON KEY_COMMIT payload must be zero");
                    rx_valid <= 1'b1; rx_source <= 2'd2;
                    rx_type <= 8'h35; rx_payload <= 128'h0;
                end
                8'h36: if (respond_jetson) begin
                    if (tx_payload !== ((jetson_requested_key ^ MASTER_KEY) ^
                                        CHALLENGE_CONST))
                        $fatal(1, "JETSON KEY_CONFIRM challenge mismatch");
                    // The top level AES-GCM decrypts 0x37 first; this unit
                    // test feeds the resulting authenticated plaintext.
                    rx_valid <= 1'b1; rx_source <= 2'd2;
                    rx_type <= 8'h37;
                    rx_payload <= tx_payload ^ RESPONSE_CONST;
                end
                default: begin end
            endcase
        end

        previous_group_normal <= pc_basys_traffic_enable;
        previous_jetson_normal <= jetson_traffic_enable;

        if (!previous_group_normal && pc_basys_traffic_enable) begin
            completed_group_sessions <= completed_group_sessions + 1;
            if (current_random == 128'h0)
                $fatal(1, "current_random must not be zero");
            if (pc_basys_requested_key !== (MASTER_KEY ^ current_random))
                $fatal(1, "PC/Basys session key XOR mismatch");

            if (completed_group_sessions == 0) begin
                if (jetson_traffic_enable)
                    $fatal(1, "Jetson must not gate or join first PC/Basys session");
                $display("PASS: PC/Basys entered RUN while Jetson was absent");
                enable_jetson_countdown <= 5;
            end else if (completed_group_sessions == 1 &&
                         completed_jetson_sessions >= 1) begin
                $display("PASS: independent groups reused one R and timer rekeyed");
                $finish;
            end
        end

        if (!previous_jetson_normal && jetson_traffic_enable) begin
            completed_jetson_sessions <= completed_jetson_sessions + 1;
            if (completed_jetson_sessions == 0 && !pc_basys_traffic_enable)
                $fatal(1, "Late Jetson join unexpectedly stopped PC/Basys traffic");
            if (completed_jetson_sessions == 0 &&
                jetson_requested_key !== (MASTER_KEY ^ current_random))
                $fatal(1, "Jetson did not join the current common R");
            $display("PASS: Jetson joined later without blocking PC/Basys");
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        pc_basys_crypto_key_active = 1'b1;
        jetson_crypto_key_active = 1'b1;
        repeat (2500) @(posedge clk);
        $fatal(1, "session manager timeout");
    end
endmodule
