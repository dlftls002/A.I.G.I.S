`timescale 1ns/1ps

// Two-domain 30-second session-key coordinator for the ZYBO PL.
//
// One global random R is generated for each epoch and both security domains
// derive the same target key:
//
//     session_key = MASTER_KEY ^ R
//
// Domain A (PC + Basys3) and Domain B (Jetson) perform independent
// handshakes and keep independent active-key state.  A missing Jetson never
// blocks PC/Basys rack control.  The Jetson FSM continuously retries the
// current epoch and may join later using the same R.
module zybo_session_manager #(
    parameter integer SYS_CLK_FREQ = 125_000_000,
    parameter integer SESSION_SECONDS = 30,
    parameter logic [127:0] MASTER_KEY =
        128'h6C8E_9CF5_7093_2BD5_A3F1_04D7_B89E_62C1,
    parameter logic [127:0] LFSR_SEED =
        128'hA3C5_19E7_42D8_B60F_1357_9BDF_2468_ACE1
)(
    input  logic         clk,
    input  logic         rst_n,

    input  logic         pc_basys_crypto_key_active,
    output logic [127:0] pc_basys_requested_key,
    output logic         pc_basys_key_reload,
    input  logic         pc_basys_key_reload_done,

    input  logic         jetson_crypto_key_active,
    output logic [127:0] jetson_requested_key,
    output logic         jetson_key_reload,
    input  logic         jetson_key_reload_done,

    output logic         pc_basys_traffic_enable,
    output logic         jetson_traffic_enable,
    output logic [127:0] current_random,

    output logic         tx_valid,
    input  logic         tx_ready,
    output logic [1:0]   tx_dest,       // 0: PC, 1: Basys, 2: Jetson
    output logic [7:0]   tx_type,
    output logic [127:0] tx_payload,

    input  logic         rx_valid,
    input  logic [1:0]   rx_source,     // 0: PC, 1: Basys, 2: Jetson
    input  logic [7:0]   rx_type,
    input  logic [127:0] rx_payload
);
    localparam logic [1:0] DST_PC = 2'd0;
    localparam logic [1:0] DST_BASYS = 2'd1;
    localparam logic [1:0] DST_JETSON = 2'd2;

    localparam logic [7:0] PC_KEY_UPDATE   = 8'h12;
    localparam logic [7:0] PC_READY        = 8'h13;
    localparam logic [7:0] PC_KEY_COMMIT   = 8'h14;
    localparam logic [7:0] PC_COMMIT_ACK   = 8'h15;
    localparam logic [7:0] PC_KEY_CONFIRM  = 8'h16;
    localparam logic [7:0] PC_CONFIRM_ACK  = 8'h17;

    localparam logic [7:0] BASYS_KEY_UPDATE  = 8'h22;
    localparam logic [7:0] BASYS_READY       = 8'h23;
    localparam logic [7:0] BASYS_POLL_OLD    = 8'h24;
    localparam logic [7:0] BASYS_KEY_COMMIT  = 8'h25;
    localparam logic [7:0] BASYS_COMMIT_ACK  = 8'h26;
    localparam logic [7:0] BASYS_KEY_CONFIRM = 8'h27;
    localparam logic [7:0] BASYS_CONFIRM_ACK = 8'h28;
    localparam logic [7:0] BASYS_POLL_NEW    = 8'h29;

    localparam logic [7:0] JETSON_KEY_UPDATE  = 8'h32;
    localparam logic [7:0] JETSON_READY       = 8'h33;
    localparam logic [7:0] JETSON_KEY_COMMIT  = 8'h34;
    localparam logic [7:0] JETSON_COMMIT_ACK  = 8'h35;
    localparam logic [7:0] JETSON_KEY_CONFIRM = 8'h36;
    localparam logic [7:0] JETSON_CONFIRM_ACK = 8'h37;

    // 0x36/0x37 prove that both sides actually installed the new session key.
    // These are plaintext values before the top-level Jetson AES-GCM path.
    localparam logic [127:0] JETSON_CHALLENGE_CONST =
        128'h5A5A_5A5A_5A5A_5A5A_A5A5_A5A5_A5A5_A5A5;
    localparam logic [127:0] JETSON_RESPONSE_CONST =
        128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;

    localparam integer RETRY_CYCLES = SYS_CLK_FREQ / 50; // 20 ms
    localparam integer SECOND_W = $clog2(SYS_CLK_FREQ + 1);
    localparam integer ELAPSED_W = $clog2(SESSION_SECONDS + 1);
    localparam integer RETRY_W = $clog2(RETRY_CYCLES + 1);

    typedef enum logic [4:0] {
        G_BOOT,
        G_RUN,
        G_SEND_PC_UPDATE,
        G_WAIT_PC_READY,
        G_SEND_BASYS_UPDATE,
        G_WAIT_BASYS_READY,
        G_SEND_BASYS_POLL_OLD_READY,
        G_SEND_PC_COMMIT,
        G_WAIT_PC_COMMIT_ACK,
        G_SEND_BASYS_COMMIT,
        G_WAIT_BASYS_COMMIT_ACK,
        G_SEND_BASYS_POLL_OLD_COMMIT,
        G_SWITCH_LOCAL,
        G_WAIT_LOCAL_KEY,
        G_SEND_PC_CONFIRM,
        G_WAIT_PC_CONFIRM_ACK,
        G_SEND_BASYS_CONFIRM,
        G_WAIT_BASYS_CONFIRM_ACK,
        G_SEND_BASYS_POLL_NEW
    } group_state_t;

    typedef enum logic [3:0] {
        J_WAIT_EPOCH,
        J_SEND_UPDATE,
        J_WAIT_READY,
        J_SEND_COMMIT,
        J_WAIT_COMMIT_ACK,
        J_SWITCH_LOCAL,
        J_WAIT_LOCAL_KEY,
        J_SEND_CONFIRM,
        J_WAIT_CONFIRM_ACK,
        J_RUN
    } jetson_state_t;

    group_state_t group_state;
    jetson_state_t jetson_state;
    logic [127:0] lfsr;
    logic [127:0] pending_random;
    logic [31:0] epoch_generation;
    logic [31:0] jetson_generation_seen;
    logic [SECOND_W-1:0] second_counter;
    logic [ELAPSED_W-1:0] elapsed_seconds;
    logic [RETRY_W-1:0] group_retry_counter;
    logic [RETRY_W-1:0] jetson_retry_counter;

    logic group_tx_valid;
    logic [1:0] group_tx_dest;
    logic [7:0] group_tx_type;
    logic jetson_tx_valid;
    logic [7:0] jetson_tx_type;
    wire group_tx_fire;
    wire jetson_tx_fire;

    wire lfsr_feedback = lfsr[127] ^ lfsr[102] ^ lfsr[75] ^ lfsr[50];
    // Register authenticated management events before feeding the FSMs.
    // This breaks the 128-bit payload comparator out of the state-decode
    // timing path without changing the link protocol.
    logic pc_ready_seen;
    logic pc_commit_seen;
    logic pc_confirm_seen;
    logic basys_ready_seen;
    logic basys_commit_seen;
    logic basys_confirm_seen;
    logic jetson_ready_seen;
    logic jetson_commit_seen;
    logic jetson_confirm_seen;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_ready_seen      <= 1'b0;
            pc_commit_seen     <= 1'b0;
            pc_confirm_seen    <= 1'b0;
            basys_ready_seen   <= 1'b0;
            basys_commit_seen  <= 1'b0;
            basys_confirm_seen <= 1'b0;
            jetson_ready_seen  <= 1'b0;
            jetson_commit_seen <= 1'b0;
            jetson_confirm_seen <= 1'b0;
        end else begin
            pc_ready_seen <= rx_valid && rx_source == DST_PC &&
                             rx_type == PC_READY && rx_payload == pending_random;
            pc_commit_seen <= rx_valid && rx_source == DST_PC &&
                              rx_type == PC_COMMIT_ACK &&
                              rx_payload == pending_random;
            pc_confirm_seen <= rx_valid && rx_source == DST_PC &&
                               rx_type == PC_CONFIRM_ACK &&
                               rx_payload == pending_random;
            basys_ready_seen <= rx_valid && rx_source == DST_BASYS &&
                                rx_type == BASYS_READY;
            basys_commit_seen <= rx_valid && rx_source == DST_BASYS &&
                                 rx_type == BASYS_COMMIT_ACK;
            basys_confirm_seen <= rx_valid && rx_source == DST_BASYS &&
                                  rx_type == BASYS_CONFIRM_ACK;
            jetson_ready_seen <= rx_valid && rx_source == DST_JETSON &&
                                 rx_type == JETSON_READY &&
                                 rx_payload == 128'h0;
            jetson_commit_seen <= rx_valid && rx_source == DST_JETSON &&
                                  rx_type == JETSON_COMMIT_ACK &&
                                  rx_payload == 128'h0;
            jetson_confirm_seen <= rx_valid && rx_source == DST_JETSON &&
                                   rx_type == JETSON_CONFIRM_ACK &&
                                   rx_payload == ((pending_random ^
                                                   JETSON_CHALLENGE_CONST) ^
                                                  JETSON_RESPONSE_CONST);
        end
    end

    assign pc_basys_requested_key = MASTER_KEY ^ pending_random;
    assign jetson_requested_key = MASTER_KEY ^ pending_random;
    assign pc_basys_traffic_enable = (group_state == G_RUN);
    assign jetson_traffic_enable = (jetson_state == J_RUN) &&
                                   (jetson_generation_seen == epoch_generation);

    always_comb begin
        group_tx_valid = 1'b0;
        group_tx_dest  = DST_PC;
        group_tx_type  = 8'h00;
        case (group_state)
            G_SEND_PC_UPDATE: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_PC;
                group_tx_type = PC_KEY_UPDATE;
            end
            G_SEND_BASYS_UPDATE: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_BASYS;
                group_tx_type = BASYS_KEY_UPDATE;
            end
            G_SEND_BASYS_POLL_OLD_READY,
            G_SEND_BASYS_POLL_OLD_COMMIT: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_BASYS;
                group_tx_type = BASYS_POLL_OLD;
            end
            G_SEND_PC_COMMIT: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_PC;
                group_tx_type = PC_KEY_COMMIT;
            end
            G_SEND_BASYS_COMMIT: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_BASYS;
                group_tx_type = BASYS_KEY_COMMIT;
            end
            G_SEND_PC_CONFIRM: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_PC;
                group_tx_type = PC_KEY_CONFIRM;
            end
            G_SEND_BASYS_CONFIRM: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_BASYS;
                group_tx_type = BASYS_KEY_CONFIRM;
            end
            G_SEND_BASYS_POLL_NEW: begin
                group_tx_valid = 1'b1; group_tx_dest = DST_BASYS;
                group_tx_type = BASYS_POLL_NEW;
            end
            default: begin end
        endcase
    end

    always_comb begin
        jetson_tx_valid = 1'b0;
        jetson_tx_type  = 8'h00;
        case (jetson_state)
            J_SEND_UPDATE: begin
                jetson_tx_valid = 1'b1; jetson_tx_type = JETSON_KEY_UPDATE;
            end
            J_SEND_COMMIT: begin
                jetson_tx_valid = 1'b1; jetson_tx_type = JETSON_KEY_COMMIT;
            end
            J_SEND_CONFIRM: begin
                jetson_tx_valid = 1'b1; jetson_tx_type = JETSON_KEY_CONFIRM;
            end
            default: begin end
        endcase
    end

    // Domain A has priority only for its single management frame.  During
    // response waits the independent Jetson FSM can use the shared request
    // interface, so an absent Jetson cannot stall the PC/Basys state machine.
    always_comb begin
        tx_valid   = 1'b0;
        tx_dest    = DST_PC;
        tx_type    = 8'h00;
        tx_payload = pending_random;
        if (group_tx_valid) begin
            tx_valid = 1'b1;
            tx_dest  = group_tx_dest;
            tx_type  = group_tx_type;
        end else if (jetson_tx_valid) begin
            tx_valid = 1'b1;
            tx_dest  = DST_JETSON;
            tx_type  = jetson_tx_type;
            // UPDATE carries clear R, COMMIT carries zero.  KEY_CONFIRM is a
            // challenge plaintext that the top level encrypts with the newly
            // installed Jetson session key before putting it on SPI.
            if (jetson_tx_type == JETSON_KEY_COMMIT)
                tx_payload = 128'h0;
            else if (jetson_tx_type == JETSON_KEY_CONFIRM)
                tx_payload = pending_random ^ JETSON_CHALLENGE_CONST;
        end
    end

    assign group_tx_fire = group_tx_valid && tx_valid && tx_ready &&
                           tx_dest == group_tx_dest;
    assign jetson_tx_fire = jetson_tx_valid && tx_valid && tx_ready &&
                            tx_dest == DST_JETSON;

    // PC + Basys domain.  This FSM owns the single global 30-second epoch.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group_state          <= G_BOOT;
            lfsr                 <= LFSR_SEED;
            pending_random       <= 128'h0;
            current_random       <= 128'h0;
            epoch_generation     <= 32'h0;
            second_counter       <= '0;
            elapsed_seconds      <= '0;
            group_retry_counter  <= '0;
            pc_basys_key_reload  <= 1'b0;
        end else begin
            lfsr <= {lfsr[126:0], lfsr_feedback};
            pc_basys_key_reload <= 1'b0;

            case (group_state)
                G_BOOT: begin
                    second_counter <= '0;
                    elapsed_seconds <= '0;
                    group_retry_counter <= '0;
                    if (pc_basys_crypto_key_active) begin
                        pending_random <= (lfsr == 128'h0) ? LFSR_SEED : lfsr;
                        epoch_generation <= epoch_generation + 1'b1;
                        group_state <= G_SEND_PC_UPDATE;
                    end
                end

                G_RUN: begin
                    group_retry_counter <= '0;
                    if (second_counter == SYS_CLK_FREQ - 1) begin
                        second_counter <= '0;
                        if (elapsed_seconds == SESSION_SECONDS - 1) begin
                            elapsed_seconds <= '0;
                            pending_random <= (lfsr == 128'h0) ? LFSR_SEED : lfsr;
                            epoch_generation <= epoch_generation + 1'b1;
                            group_state <= G_SEND_PC_UPDATE;
                        end else begin
                            elapsed_seconds <= elapsed_seconds + 1'b1;
                        end
                    end else begin
                        second_counter <= second_counter + 1'b1;
                    end
                end

                G_SEND_PC_UPDATE: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_PC_READY;
                end
                G_WAIT_PC_READY: begin
                    if (pc_ready_seen) begin
                        group_retry_counter <= '0; group_state <= G_SEND_BASYS_UPDATE;
                    end else if (group_retry_counter == RETRY_CYCLES - 1) begin
                        group_retry_counter <= '0; group_state <= G_SEND_PC_UPDATE;
                    end else group_retry_counter <= group_retry_counter + 1'b1;
                end

                G_SEND_BASYS_UPDATE: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_BASYS_READY;
                end
                G_WAIT_BASYS_READY: begin
                    if (basys_ready_seen) begin
                        group_retry_counter <= '0; group_state <= G_SEND_PC_COMMIT;
                    end else if (group_retry_counter == RETRY_CYCLES - 1) begin
                        group_retry_counter <= '0;
                        group_state <= G_SEND_BASYS_POLL_OLD_READY;
                    end else group_retry_counter <= group_retry_counter + 1'b1;
                end
                G_SEND_BASYS_POLL_OLD_READY: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_BASYS_READY;
                end

                G_SEND_PC_COMMIT: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_PC_COMMIT_ACK;
                end
                G_WAIT_PC_COMMIT_ACK: begin
                    if (pc_commit_seen) begin
                        group_retry_counter <= '0; group_state <= G_SEND_BASYS_COMMIT;
                    end else if (group_retry_counter == RETRY_CYCLES - 1) begin
                        group_retry_counter <= '0; group_state <= G_SEND_PC_COMMIT;
                    end else group_retry_counter <= group_retry_counter + 1'b1;
                end

                G_SEND_BASYS_COMMIT: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_BASYS_COMMIT_ACK;
                end
                G_WAIT_BASYS_COMMIT_ACK: begin
                    if (basys_commit_seen) begin
                        group_retry_counter <= '0; group_state <= G_SWITCH_LOCAL;
                    end else if (group_retry_counter == RETRY_CYCLES - 1) begin
                        group_retry_counter <= '0;
                        group_state <= G_SEND_BASYS_POLL_OLD_COMMIT;
                    end else group_retry_counter <= group_retry_counter + 1'b1;
                end
                G_SEND_BASYS_POLL_OLD_COMMIT: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_BASYS_COMMIT_ACK;
                end

                G_SWITCH_LOCAL: begin
                    pc_basys_key_reload <= 1'b1;
                    group_state <= G_WAIT_LOCAL_KEY;
                end
                G_WAIT_LOCAL_KEY: begin
                    if (pc_basys_key_reload_done) begin
                        group_retry_counter <= '0;
                        group_state <= G_SEND_PC_CONFIRM;
                    end
                end

                G_SEND_PC_CONFIRM: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_PC_CONFIRM_ACK;
                end
                G_WAIT_PC_CONFIRM_ACK: begin
                    if (pc_confirm_seen) begin
                        group_retry_counter <= '0; group_state <= G_SEND_BASYS_CONFIRM;
                    end else if (group_retry_counter == RETRY_CYCLES - 1) begin
                        group_retry_counter <= '0; group_state <= G_SEND_PC_CONFIRM;
                    end else group_retry_counter <= group_retry_counter + 1'b1;
                end

                G_SEND_BASYS_CONFIRM: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_BASYS_CONFIRM_ACK;
                end
                G_WAIT_BASYS_CONFIRM_ACK: begin
                    if (basys_confirm_seen) begin
                        current_random <= pending_random;
                        second_counter <= '0;
                        elapsed_seconds <= '0;
                        group_retry_counter <= '0;
                        group_state <= G_RUN;
                    end else if (group_retry_counter == RETRY_CYCLES - 1) begin
                        group_retry_counter <= '0; group_state <= G_SEND_BASYS_POLL_NEW;
                    end else group_retry_counter <= group_retry_counter + 1'b1;
                end
                G_SEND_BASYS_POLL_NEW: if (group_tx_fire) begin
                    group_retry_counter <= '0; group_state <= G_WAIT_BASYS_CONFIRM_ACK;
                end

                default: group_state <= G_BOOT;
            endcase
        end
    end

    // Jetson domain.  A new global epoch restarts only this FSM; it never
    // modifies or gates the PC/Basys domain.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            jetson_state           <= J_WAIT_EPOCH;
            jetson_generation_seen <= 32'h0;
            jetson_retry_counter   <= '0;
            jetson_key_reload      <= 1'b0;
        end else begin
            jetson_key_reload <= 1'b0;

            if (epoch_generation != jetson_generation_seen &&
                jetson_crypto_key_active) begin
                jetson_generation_seen <= epoch_generation;
                jetson_retry_counter <= '0;
                jetson_state <= J_SEND_UPDATE;
            end else begin
                case (jetson_state)
                    J_WAIT_EPOCH: begin
                        jetson_retry_counter <= '0;
                    end

                    J_SEND_UPDATE: if (jetson_tx_fire) begin
                        jetson_retry_counter <= '0; jetson_state <= J_WAIT_READY;
                    end
                    J_WAIT_READY: begin
                        if (jetson_ready_seen) begin
                            jetson_retry_counter <= '0; jetson_state <= J_SEND_COMMIT;
                        end else if (jetson_retry_counter == RETRY_CYCLES - 1) begin
                            jetson_retry_counter <= '0; jetson_state <= J_SEND_UPDATE;
                        end else jetson_retry_counter <= jetson_retry_counter + 1'b1;
                    end

                    J_SEND_COMMIT: if (jetson_tx_fire) begin
                        jetson_retry_counter <= '0; jetson_state <= J_WAIT_COMMIT_ACK;
                    end
                    J_WAIT_COMMIT_ACK: begin
                        if (jetson_commit_seen) begin
                            jetson_retry_counter <= '0; jetson_state <= J_SWITCH_LOCAL;
                        end else if (jetson_retry_counter == RETRY_CYCLES - 1) begin
                            jetson_retry_counter <= '0; jetson_state <= J_SEND_COMMIT;
                        end else jetson_retry_counter <= jetson_retry_counter + 1'b1;
                    end

                    J_SWITCH_LOCAL: begin
                        jetson_key_reload <= 1'b1;
                        jetson_state <= J_WAIT_LOCAL_KEY;
                    end
                    J_WAIT_LOCAL_KEY: begin
                        if (jetson_key_reload_done) begin
                            jetson_retry_counter <= '0;
                            jetson_state <= J_SEND_CONFIRM;
                        end
                    end

                    J_SEND_CONFIRM: if (jetson_tx_fire) begin
                        jetson_retry_counter <= '0; jetson_state <= J_WAIT_CONFIRM_ACK;
                    end
                    J_WAIT_CONFIRM_ACK: begin
                        if (jetson_confirm_seen) begin
                            jetson_retry_counter <= '0; jetson_state <= J_RUN;
                        end else if (jetson_retry_counter == RETRY_CYCLES - 1) begin
                            jetson_retry_counter <= '0; jetson_state <= J_SEND_CONFIRM;
                        end else jetson_retry_counter <= jetson_retry_counter + 1'b1;
                    end

                    J_RUN: begin
                        jetson_retry_counter <= '0;
                    end

                    default: jetson_state <= J_WAIT_EPOCH;
                endcase
            end
        end
    end
endmodule
