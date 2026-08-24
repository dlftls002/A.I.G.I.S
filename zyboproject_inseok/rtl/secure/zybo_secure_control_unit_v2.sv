`timescale 1ns/1ps

// Version-2 secure ZYBO control unit.
//
// All links use one common 48-byte physical frame. TYPE is always clear.
// Application frame:
//   A5 5A | TYPE | 10 | IV[95:0] | CIPHERTEXT[127:0] | TAG[127:0]
// Clear session-management frame (0x31..0x35; no AES):
//   A5 5A | TYPE | 10 | 96'b0 | R[127:0] | 128'b0
// Jetson 0x36/0x37 use the application frame shape with the new session key
// so both endpoints prove AES-GCM encrypt/decrypt operation before RUN.
//
// PC/Basys and Jetson use independent AES engine/key domains. ZYBO PL
// generates one common R and coordinates two independent handshakes:
//     session_key = MASTER_KEY ^ R
module zybo_secure_control_unit_v2 #(
    parameter integer SYS_CLK_FREQ   = 125_000_000,
    parameter integer SPI_CLK_FREQ   = 100_000,
    parameter integer UART_BAUD_RATE = 115200,
    parameter logic [127:0] MASTER_KEY =
        128'h6C8E_9CF5_7093_2BD5_A3F1_04D7_B89E_62C1
)(
    input  wire clk,
    input  wire rst,

    // 384-bit full-duplex secure SPI slave link from Jetson Nano.
    input  wire sclk_in,
    input  wire mosi_in,
    input  wire cs_n_in,
    output wire miso_out,

    // 48-byte secure UART link to the control-room PC.
    output wire uart_tx_out,
    input  wire uart_rx_in,

    // 384-bit full-duplex secure SPI master link to Basys3.
    output wire sclk_out,
    output wire mosi_out,
    output wire cs_n_out,
    input  wire miso_in
);
    localparam integer SPI_CLK_DIV = SYS_CLK_FREQ / (2 * SPI_CLK_FREQ);

    localparam logic [7:0] TYPE_PC_TX    = 8'h02;
    localparam logic [7:0] TYPE_PC_RX    = 8'h03;
    localparam logic [7:0] TYPE_BASYS_TX = 8'h04;
    localparam logic [7:0] TYPE_BASYS_RX = 8'h05;
    localparam logic [7:0] TYPE_JETSON_RX = 8'h01;
    localparam logic [7:0] TYPE_JETSON_TX = 8'h06;
    localparam logic [7:0] TYPE_JETSON_KEY_CONFIRM = 8'h36;
    localparam logic [7:0] TYPE_JETSON_CONFIRM_ACK = 8'h37;

    localparam logic [1:0] SRC_PC     = 2'd0;
    localparam logic [1:0] SRC_BASYS  = 2'd1;
    localparam logic [1:0] SRC_JETSON = 2'd2;
    localparam logic [1:0] DST_PC     = 2'd0;
    localparam logic [1:0] DST_BASYS  = 2'd1;
    localparam logic [1:0] DST_JETSON = 2'd2;

    wire rst_n = ~rst;

    // ------------------------------------------------------------------
    // PC + Basys AES-GCM key initialization and session re-keying
    // ------------------------------------------------------------------
    logic enc_key_load;
    logic dec_key_load;
    wire  enc_key_ready;
    wire  enc_key_valid;
    wire  dec_key_ready;
    wire  dec_key_valid;
    logic [127:0] active_key;
    wire  [127:0] requested_session_key;
    wire          session_key_reload;
    logic         session_key_reload_done;

    // Jetson has a separate key state. This lets PC/Basys enter RUN even
    // while Jetson is absent or still completing its own handshake.
    logic jetson_enc_key_load;
    logic jetson_dec_key_load;
    wire  jetson_enc_key_ready;
    wire  jetson_enc_key_valid;
    wire  jetson_dec_key_ready;
    wire  jetson_dec_key_valid;
    logic [127:0] jetson_active_key;
    wire  [127:0] requested_jetson_session_key;
    wire          jetson_session_key_reload;
    logic         jetson_session_key_reload_done;

    typedef enum logic [1:0] {
        KEY_WAIT_READY,
        KEY_PULSE,
        KEY_WAIT_VALID,
        KEY_ACTIVE
    } key_state_t;
    key_state_t key_state;
    key_state_t jetson_key_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_state    <= KEY_WAIT_READY;
            enc_key_load <= 1'b0;
            dec_key_load <= 1'b0;
            active_key   <= MASTER_KEY;
            session_key_reload_done <= 1'b0;
        end else begin
            enc_key_load <= 1'b0;
            dec_key_load <= 1'b0;
            session_key_reload_done <= 1'b0;
            case (key_state)
                KEY_WAIT_READY: begin
                    if (enc_key_ready && dec_key_ready) begin
                        enc_key_load <= 1'b1;
                        dec_key_load <= 1'b1;
                        key_state    <= KEY_PULSE;
                    end
                end
                KEY_PULSE:
                    key_state <= KEY_WAIT_VALID;
                KEY_WAIT_VALID: begin
                    if (enc_key_valid && dec_key_valid) begin
                        key_state <= KEY_ACTIVE;
                        session_key_reload_done <= 1'b1;
                    end
                end
                KEY_ACTIVE: begin
                    if (session_key_reload) begin
                        active_key <= requested_session_key;
                        key_state <= KEY_WAIT_READY;
                    end
                end
                default:
                    key_state <= KEY_WAIT_READY;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            jetson_key_state    <= KEY_WAIT_READY;
            jetson_enc_key_load <= 1'b0;
            jetson_dec_key_load <= 1'b0;
            jetson_active_key   <= MASTER_KEY;
            jetson_session_key_reload_done <= 1'b0;
        end else begin
            jetson_enc_key_load <= 1'b0;
            jetson_dec_key_load <= 1'b0;
            jetson_session_key_reload_done <= 1'b0;
            case (jetson_key_state)
                KEY_WAIT_READY: begin
                    if (jetson_enc_key_ready && jetson_dec_key_ready) begin
                        jetson_enc_key_load <= 1'b1;
                        jetson_dec_key_load <= 1'b1;
                        jetson_key_state    <= KEY_PULSE;
                    end
                end
                KEY_PULSE:
                    jetson_key_state <= KEY_WAIT_VALID;
                KEY_WAIT_VALID: begin
                    if (jetson_enc_key_valid && jetson_dec_key_valid) begin
                        jetson_key_state <= KEY_ACTIVE;
                        jetson_session_key_reload_done <= 1'b1;
                    end
                end
                KEY_ACTIVE: begin
                    if (jetson_session_key_reload) begin
                        jetson_active_key <= requested_jetson_session_key;
                        jetson_key_state <= KEY_WAIT_READY;
                    end
                end
                default:
                    jetson_key_state <= KEY_WAIT_READY;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 30-second key coordinator. R travels in clear in 0x32.  Jetson
    // 0x36/0x37 are routed through the dedicated AES-GCM engines.
    // ------------------------------------------------------------------
    wire         session_normal_enable;
    wire         jetson_session_normal_enable;
    wire [127:0] session_current_random;
    wire         session_tx_valid;
    wire         session_tx_ready;
    wire [1:0]   session_tx_dest;
    wire [7:0]   session_tx_type;
    wire [127:0] session_tx_payload;
    logic        session_rx_valid;
    logic [1:0]  session_rx_source;
    logic [7:0]  session_rx_type;
    logic [127:0] session_rx_payload;
    logic         session_rx_pipe_valid;
    logic [1:0]   session_rx_pipe_source;
    logic [7:0]   session_rx_pipe_type;
    logic [127:0] session_rx_pipe_payload;
    wire [383:0] session_clear_frame = {
        16'hA55A, session_tx_type, 8'h10, 96'h0,
        session_tx_payload, 128'h0
    };
    wire session_clear_pc_valid = session_tx_valid &&
                                  session_tx_dest == DST_PC;
    wire session_clear_basys_valid = session_tx_valid &&
                                     session_tx_dest == DST_BASYS;
    wire session_jetson_confirm_valid = session_tx_valid &&
                                        session_tx_dest == DST_JETSON &&
                                        session_tx_type == TYPE_JETSON_KEY_CONFIRM;
    wire session_clear_jetson_valid = session_tx_valid &&
                                      session_tx_dest == DST_JETSON &&
                                      session_tx_type != TYPE_JETSON_KEY_CONFIRM;
    wire pc_uart_tx_packet_ready;
    logic jetson_management_pending;

    zybo_session_manager #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .SESSION_SECONDS(30),
        .MASTER_KEY(MASTER_KEY)
    ) u_session_manager (
        .clk                  (clk),
        .rst_n                (rst_n),
        .pc_basys_crypto_key_active(key_state == KEY_ACTIVE),
        .pc_basys_requested_key    (requested_session_key),
        .pc_basys_key_reload       (session_key_reload),
        .pc_basys_key_reload_done  (session_key_reload_done),
        .jetson_crypto_key_active  (jetson_key_state == KEY_ACTIVE),
        .jetson_requested_key      (requested_jetson_session_key),
        .jetson_key_reload         (jetson_session_key_reload),
        .jetson_key_reload_done    (jetson_session_key_reload_done),
        .pc_basys_traffic_enable   (session_normal_enable),
        .jetson_traffic_enable     (jetson_session_normal_enable),
        .current_random            (session_current_random),
        .tx_valid             (session_tx_valid),
        .tx_ready             (session_tx_ready),
        .tx_dest              (session_tx_dest),
        .tx_type              (session_tx_type),
        .tx_payload           (session_tx_payload),
        .rx_valid             (session_rx_pipe_valid),
        .rx_source            (session_rx_pipe_source),
        .rx_type              (session_rx_pipe_type),
        .rx_payload           (session_rx_pipe_payload)
    );

    // Stage clear management events next to the session manager. This keeps
    // the wide 128-bit R comparator off the long UART/SPI receive route.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            session_rx_pipe_valid   <= 1'b0;
            session_rx_pipe_source  <= SRC_PC;
            session_rx_pipe_type    <= 8'h00;
            session_rx_pipe_payload <= 128'h0;
        end else begin
            session_rx_pipe_valid <= session_rx_valid;
            if (session_rx_valid) begin
                session_rx_pipe_source  <= session_rx_source;
                session_rx_pipe_type    <= session_rx_type;
                session_rx_pipe_payload <= session_rx_payload;
            end
        end
    end

    // ------------------------------------------------------------------
    // Secure Jetson SPI slave transport. Jetson is the SPI master, so ZYBO
    // preloads one encrypted response which is shifted out on the next poll.
    // ------------------------------------------------------------------
    logic [7:0]   door_cmd_to_jetson;
    wire [383:0]  jetson_spi_rx_packet;
    wire          jetson_spi_rx_valid;
    logic [383:0] jetson_spi_tx_packet;
    logic [383:0] jetson_hold_packet;
    logic         jetson_hold_valid;

    spi_slave #(
        .DATA_WIDTH(384),
        .CPOL(1'b0),
        .CPHA(1'b0)
    ) u_spi_slave_jetson (
        .clk     (clk),
        .rst_n   (rst_n),
        .sclk    (sclk_in),
        .cs_n    (cs_n_in),
        .mosi    (mosi_in),
        .miso    (miso_out),
        .rx_data (jetson_spi_rx_packet),
        .rx_valid(jetson_spi_rx_valid),
        .tx_data (jetson_spi_tx_packet)
    );

    // Authenticated Jetson application payloads retain the original 128-bit
    // PC packet mapping. The Jetson software must construct these 16 bytes.
    logic         jetson_packet_wr;
    logic [127:0] jetson_packet_data;
    wire          jetson_fifo_full;
    wire          jetson_fifo_empty;
    wire [127:0]  jetson_fifo_data;
    logic         jetson_fifo_rd;

    pxc_sync_fifo #(.DATA_WIDTH(128), .DEPTH(4)) u_jetson_pc_fifo (
        .clk    (clk),
        .rst    (rst),
        .wr_en  (jetson_packet_wr),
        .wr_data(jetson_packet_data),
        .full   (jetson_fifo_full),
        .rd_en  (jetson_fifo_rd),
        .rd_data(jetson_fifo_data),
        .empty  (jetson_fifo_empty)
    );

    // ------------------------------------------------------------------
    // Secure PC UART receive path
    // ------------------------------------------------------------------
    wire [7:0]   pc_uart_rx_byte;
    wire         pc_uart_rx_byte_valid;
    wire [383:0] pc_uart_rx_packet;
    wire         pc_uart_rx_packet_valid;
    logic        pc_uart_rx_packet_ready;

    uart_rx #(
        .CLK_FREQ (SYS_CLK_FREQ),
        .BAUD_RATE(UART_BAUD_RATE)
    ) u_pc_uart_rx (
        .clk     (clk),
        .rst_n   (rst_n),
        .rx      (uart_rx_in),
        .rx_data (pc_uart_rx_byte),
        .rx_valid(pc_uart_rx_byte_valid)
    );

    secure_uart_frame_rx u_pc_frame_rx (
        .clk         (clk),
        .rst_n       (rst_n),
        .byte_data   (pc_uart_rx_byte),
        .byte_valid  (pc_uart_rx_byte_valid),
        .packet      (pc_uart_rx_packet),
        .packet_valid(pc_uart_rx_packet_valid),
        .packet_ready(pc_uart_rx_packet_ready)
    );

    // ------------------------------------------------------------------
    // Secure Basys3 SPI master transport
    // ------------------------------------------------------------------
    logic [383:0] basys_spi_tx_packet;
    logic         basys_spi_tx_pending;
    logic         basys_spi_start;
    wire          basys_spi_busy;
    wire [383:0]  basys_spi_rx_packet;
    wire          basys_spi_rx_valid;

    spi_master #(
        .DATA_WIDTH(384),
        .CPOL(1'b0),
        .CPHA(1'b0),
        .CLK_DIV(SPI_CLK_DIV)
    ) u_spi_master_basys3 (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (basys_spi_start),
        .tx_data (basys_spi_tx_packet),
        .busy    (basys_spi_busy),
        .done    (),
        .rx_data (basys_spi_rx_packet),
        .rx_valid(basys_spi_rx_valid),
        .sclk    (sclk_out),
        .cs_n    (cs_n_out),
        .mosi    (mosi_out),
        .miso    (miso_in)
    );

    logic [383:0] basys_hold_packet;
    logic         basys_hold_valid;

    wire pc_clear_header = pc_uart_rx_packet[383:368] == 16'hA55A &&
                           pc_uart_rx_packet[359:352] == 8'h10;
    wire pc_clear_management_valid = pc_uart_rx_packet_valid &&
        pc_clear_header &&
        (pc_uart_rx_packet[367:360] == 8'h13 ||
         pc_uart_rx_packet[367:360] == 8'h15 ||
         pc_uart_rx_packet[367:360] == 8'h17);

    wire basys_clear_header = basys_hold_packet[383:368] == 16'hA55A &&
                              basys_hold_packet[359:352] == 8'h10;
    wire basys_clear_management_valid = basys_hold_valid &&
        basys_clear_header &&
        (basys_hold_packet[367:360] == 8'h23 ||
         basys_hold_packet[367:360] == 8'h26 ||
         basys_hold_packet[367:360] == 8'h28);

    wire jetson_clear_header = jetson_hold_packet[383:368] == 16'hA55A &&
                               jetson_hold_packet[359:352] == 8'h10;
    wire jetson_clear_management_valid = jetson_hold_valid &&
        jetson_clear_header &&
        (jetson_hold_packet[367:360] == 8'h31 ||
         jetson_hold_packet[367:360] == 8'h33 ||
         jetson_hold_packet[367:360] == 8'h35);

    // ------------------------------------------------------------------
    // PC/Basys decrypt engine. Jetson uses a dedicated decrypt/key domain.
    // ------------------------------------------------------------------
    logic [383:0] dec_input_packet;
    logic [7:0]   dec_expected_type;
    logic         dec_input_valid;
    wire          dec_input_ready;
    logic [1:0]   dec_selected_source;
    logic [1:0]   dec_active_source;
    logic [7:0]   dec_selected_type;
    logic [7:0]   dec_active_type;
    wire [127:0]  dec_plaintext;
    wire          dec_plaintext_valid;
    wire          dec_auth_valid;

    wire          jetson_dec_input_ready;
    logic [7:0]   jetson_dec_active_type;
    wire [127:0]  jetson_dec_plaintext;
    wire          jetson_dec_plaintext_valid;
    wire          jetson_dec_auth_valid;

    wire dec_accept = dec_input_valid && dec_input_ready;
    wire jetson_dec_accept = jetson_hold_valid &&
                             !jetson_clear_management_valid &&
                             jetson_dec_input_ready;

    always_comb begin
        dec_input_packet        = 384'h0;
        dec_expected_type       = 8'h00;
        dec_input_valid         = 1'b0;
        dec_selected_source     = SRC_PC;
        dec_selected_type       = 8'h00;
        pc_uart_rx_packet_ready = 1'b0;

        if (pc_clear_management_valid) begin
            pc_uart_rx_packet_ready = 1'b1;
        end else if (pc_uart_rx_packet_valid) begin
            dec_input_packet        = pc_uart_rx_packet;
            dec_expected_type       = pc_uart_rx_packet[367:360];
            dec_input_valid         = 1'b1;
            dec_selected_source     = SRC_PC;
            dec_selected_type       = pc_uart_rx_packet[367:360];
            pc_uart_rx_packet_ready = dec_input_ready;
        end else if (basys_hold_valid && !basys_clear_management_valid) begin
            dec_input_packet    = basys_hold_packet;
            dec_expected_type   = basys_hold_packet[367:360];
            dec_input_valid     = 1'b1;
            dec_selected_source = SRC_BASYS;
            dec_selected_type   = basys_hold_packet[367:360];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            basys_hold_packet <= 384'h0;
            basys_hold_valid  <= 1'b0;
            jetson_hold_packet <= 384'h0;
            jetson_hold_valid  <= 1'b0;
            dec_active_source <= SRC_PC;
            dec_active_type   <= 8'h00;
            jetson_dec_active_type <= 8'h00;
        end else begin
            if (dec_accept) begin
                dec_active_source <= dec_selected_source;
                dec_active_type   <= dec_selected_type;
                if (dec_selected_source == SRC_BASYS)
                    basys_hold_valid <= 1'b0;
            end
            if (basys_clear_management_valid)
                basys_hold_valid <= 1'b0;
            if (jetson_dec_accept) begin
                jetson_dec_active_type <= jetson_hold_packet[367:360];
                jetson_hold_valid <= 1'b0;
            end
            if (jetson_clear_management_valid)
                jetson_hold_valid <= 1'b0;
            if (basys_spi_rx_valid) begin
                basys_hold_packet <= basys_spi_rx_packet;
                basys_hold_valid  <= 1'b1;
            end
            if (jetson_spi_rx_valid) begin
                jetson_hold_packet <= jetson_spi_rx_packet;
                jetson_hold_valid  <= 1'b1;
            end
        end
    end

    aes_gcm_decrypt_packet u_shared_decrypt (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_data       (active_key),
        .key_load       (dec_key_load),
        .key_ready      (dec_key_ready),
        .key_valid      (dec_key_valid),
        .expected_type  (dec_expected_type),
        .packet         (dec_input_packet),
        .packet_valid   (dec_input_valid),
        .packet_ready   (dec_input_ready),
        .plaintext      (dec_plaintext),
        .plaintext_valid(dec_plaintext_valid),
        .auth_valid     (dec_auth_valid),
        .plaintext_ready(1'b1),
        .busy           ()
    );

    aes_gcm_decrypt_packet u_jetson_decrypt (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_data       (jetson_active_key),
        .key_load       (jetson_dec_key_load),
        .key_ready      (jetson_dec_key_ready),
        .key_valid      (jetson_dec_key_valid),
        .expected_type  (jetson_hold_packet[367:360]),
        .packet         (jetson_hold_packet),
        .packet_valid   (jetson_hold_valid &&
                         !jetson_clear_management_valid),
        .packet_ready   (jetson_dec_input_ready),
        .plaintext      (jetson_dec_plaintext),
        .plaintext_valid(jetson_dec_plaintext_valid),
        .auth_valid     (jetson_dec_auth_valid),
        .plaintext_ready(1'b1),
        .busy           ()
    );

    // ------------------------------------------------------------------
    // Decrypted application routing
    // ------------------------------------------------------------------
    wire          sensor_fifo_full;
    wire          sensor_fifo_empty;
    wire [127:0]  sensor_fifo_data;
    logic         sensor_fifo_rd;
    wire          sensor_fifo_wr;
    wire [127:0]  sensor_pc_packet;

    wire accepted_plaintext = dec_plaintext_valid && dec_auth_valid;
    wire jetson_accepted_plaintext = jetson_dec_plaintext_valid &&
                                      jetson_dec_auth_valid;
    wire jetson_confirm_response_valid = jetson_accepted_plaintext &&
        (jetson_dec_active_type == TYPE_JETSON_CONFIRM_ACK);
    assign jetson_packet_wr = jetson_accepted_plaintext &&
                              (jetson_dec_active_type == TYPE_JETSON_RX) &&
                              jetson_session_normal_enable &&
                              !jetson_fifo_full;
    assign jetson_packet_data = jetson_dec_plaintext;

    assign sensor_fifo_wr = accepted_plaintext &&
                            (dec_active_source == SRC_BASYS) &&
                            (dec_active_type == TYPE_BASYS_RX) &&
                            session_normal_enable &&
                            !sensor_fifo_full;

    always_comb begin
        session_rx_valid   = 1'b0;
        session_rx_source  = SRC_PC;
        session_rx_type    = 8'h00;
        session_rx_payload = 128'h0;

        if (pc_clear_management_valid) begin
            session_rx_valid   = 1'b1;
            session_rx_source  = SRC_PC;
            session_rx_type    = pc_uart_rx_packet[367:360];
            session_rx_payload = pc_uart_rx_packet[255:128];
        end else if (basys_clear_management_valid) begin
            session_rx_valid   = 1'b1;
            session_rx_source  = SRC_BASYS;
            session_rx_type    = basys_hold_packet[367:360];
            session_rx_payload = basys_hold_packet[255:128];
        end else if (jetson_clear_management_valid) begin
            session_rx_valid   = 1'b1;
            session_rx_source  = SRC_JETSON;
            session_rx_type    = jetson_hold_packet[367:360];
            session_rx_payload = jetson_hold_packet[255:128];
        end else if (jetson_confirm_response_valid) begin
            // Only an authenticated/decrypted 0x37 reaches the session FSM.
            session_rx_valid   = 1'b1;
            session_rx_source  = SRC_JETSON;
            session_rx_type    = TYPE_JETSON_CONFIRM_ACK;
            session_rx_payload = jetson_dec_plaintext;
        end
    end

    // Preserve the legacy 16-byte PC sensor packet byte mapping.
    assign sensor_pc_packet = {
        8'hBB,
        {4'h0, dec_plaintext[67:64]},
        dec_plaintext[7:0],   dec_plaintext[15:8],
        dec_plaintext[23:16], dec_plaintext[31:24],
        dec_plaintext[39:32], dec_plaintext[47:40],
        dec_plaintext[55:48], dec_plaintext[63:56],
        dec_plaintext[75:68],
        {4'h0, dec_plaintext[79:76]},
        32'h0000_0000
    };

    pxc_sync_fifo #(.DATA_WIDTH(128), .DEPTH(4)) u_sensor_pc_fifo (
        .clk    (clk),
        .rst    (rst),
        .wr_en  (sensor_fifo_wr),
        .wr_data(sensor_pc_packet),
        .full   (sensor_fifo_full),
        .rd_en  (sensor_fifo_rd),
        .rd_data(sensor_fifo_data),
        .empty  (sensor_fifo_empty)
    );

    wire          basys_cmd_fifo_full;
    wire          basys_cmd_fifo_empty;
    wire [127:0]  basys_cmd_fifo_data;
    logic         basys_cmd_fifo_rd;
    logic         basys_cmd_fifo_wr;
    logic [127:0] basys_cmd_fifo_wr_data;
    logic [3:0]   last_rack_cmd;

    pxc_sync_fifo #(.DATA_WIDTH(128), .DEPTH(4)) u_basys_cmd_fifo (
        .clk    (clk),
        .rst    (rst),
        .wr_en  (basys_cmd_fifo_wr),
        .wr_data(basys_cmd_fifo_wr_data),
        .full   (basys_cmd_fifo_full),
        .rd_en  (basys_cmd_fifo_rd),
        .rd_data(basys_cmd_fifo_data),
        .empty  (basys_cmd_fifo_empty)
    );

    wire [7:0] pc_cmd_byte = dec_plaintext[127:120];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            door_cmd_to_jetson    <= 8'h00;
            last_rack_cmd         <= 4'h0;
            basys_cmd_fifo_wr     <= 1'b0;
            basys_cmd_fifo_wr_data <= 128'h0;
        end else begin
            basys_cmd_fifo_wr <= 1'b0;

            if (dec_plaintext_valid && dec_active_source == SRC_PC &&
                dec_active_type == TYPE_PC_RX && session_normal_enable &&
                dec_plaintext[119:0] == 120'h0) begin
                if (dec_auth_valid) begin
                    if (pc_cmd_byte[7:4] == 4'h1)
                        door_cmd_to_jetson <= 8'h01;
                    else if (pc_cmd_byte[7:4] == 4'h2)
                        door_cmd_to_jetson <= 8'h02;
                    else
                        door_cmd_to_jetson <= 8'h00;

                    if (!basys_cmd_fifo_full) begin
                        basys_cmd_fifo_wr <= 1'b1;
                        if (pc_cmd_byte[7:4] == 4'h3)
                            basys_cmd_fifo_wr_data <= {124'h0, last_rack_cmd};
                        else
                            basys_cmd_fifo_wr_data <= {124'h0, pc_cmd_byte[3:0]};
                    end

                    if (pc_cmd_byte[7:4] != 4'h3)
                        last_rack_cmd <= pc_cmd_byte[3:0];
                end else begin
                    // Authentication failure forces the safe state.
                    door_cmd_to_jetson <= 8'h02;
                    last_rack_cmd      <= 4'h0;
                    if (!basys_cmd_fifo_full) begin
                        basys_cmd_fifo_wr      <= 1'b1;
                        basys_cmd_fifo_wr_data <= 128'h0;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // PC/Basys encrypt engine and output routing
    // ------------------------------------------------------------------
    logic [127:0] enc_plaintext;
    logic [7:0]   enc_packet_type;
    logic [95:0]  enc_packet_iv;
    logic         enc_plaintext_valid;
    wire          enc_plaintext_ready;
    logic [1:0]   enc_selected_dest;
    logic [1:0]   enc_active_dest;
    wire [383:0]  enc_output_packet;
    wire          enc_output_valid;
    logic         enc_output_ready;
    logic [63:0]  pc_iv_counter;
    logic [63:0]  basys_iv_counter;

    // Dedicated Jetson encrypt engine and key domain.
    logic [127:0] jetson_enc_plaintext;
    logic [7:0]   jetson_enc_packet_type;
    logic [95:0]  jetson_enc_packet_iv;
    logic         jetson_enc_plaintext_valid;
    wire          jetson_enc_plaintext_ready;
    wire [383:0]  jetson_enc_output_packet;
    wire          jetson_enc_output_valid;
    logic [63:0]  jetson_iv_counter;
    logic [7:0]   last_jetson_cmd_submitted;
    logic         jetson_session_enable_d;

    wire enc_accept = enc_plaintext_valid && enc_plaintext_ready;
    wire jetson_enc_accept = jetson_enc_plaintext_valid &&
                             jetson_enc_plaintext_ready;

    always_comb begin
        enc_plaintext       = 128'h0;
        enc_packet_type     = 8'h00;
        enc_packet_iv       = 96'h0;
        enc_plaintext_valid = 1'b0;
        enc_selected_dest   = DST_PC;
        basys_cmd_fifo_rd   = 1'b0;
        jetson_fifo_rd      = 1'b0;
        sensor_fifo_rd      = 1'b0;

        if (session_normal_enable && !basys_cmd_fifo_empty) begin
            enc_plaintext       = basys_cmd_fifo_data;
            enc_packet_type     = TYPE_BASYS_TX;
            enc_packet_iv       = {32'h0400_0001, basys_iv_counter};
            enc_plaintext_valid = 1'b1;
            enc_selected_dest   = DST_BASYS;
            basys_cmd_fifo_rd   = enc_plaintext_ready;
        end else if (session_normal_enable && !jetson_fifo_empty) begin
            enc_plaintext       = jetson_fifo_data;
            enc_packet_type     = TYPE_PC_TX;
            enc_packet_iv       = {32'h0200_0001, pc_iv_counter};
            enc_plaintext_valid = 1'b1;
            enc_selected_dest   = DST_PC;
            jetson_fifo_rd      = enc_plaintext_ready;
        end else if (session_normal_enable && !sensor_fifo_empty) begin
            enc_plaintext       = sensor_fifo_data;
            enc_packet_type     = TYPE_PC_TX;
            enc_packet_iv       = {32'h0200_0001, pc_iv_counter};
            enc_plaintext_valid = 1'b1;
            enc_selected_dest   = DST_PC;
            sensor_fifo_rd      = enc_plaintext_ready;
        end
    end

    always_comb begin
        jetson_enc_plaintext       = 128'h0;
        jetson_enc_packet_type     = 8'h00;
        jetson_enc_packet_iv       = 96'h0;
        jetson_enc_plaintext_valid = 1'b0;

        if (session_jetson_confirm_valid) begin
            // The session manager supplies CHALLENGE plaintext.  This path is
            // intentionally enabled before J_RUN, after the new key reload.
            jetson_enc_plaintext       = session_tx_payload;
            jetson_enc_packet_type     = TYPE_JETSON_KEY_CONFIRM;
            jetson_enc_packet_iv       = {32'h3600_0001, jetson_iv_counter};
            jetson_enc_plaintext_valid = 1'b1;
        end else if (jetson_session_normal_enable &&
            door_cmd_to_jetson != last_jetson_cmd_submitted) begin
            jetson_enc_plaintext       = {door_cmd_to_jetson, 120'h0};
            jetson_enc_packet_type     = TYPE_JETSON_TX;
            jetson_enc_packet_iv       = {32'h0600_0001, jetson_iv_counter};
            jetson_enc_plaintext_valid = 1'b1;
        end
    end

    assign session_tx_ready = session_tx_valid &&
        ((session_tx_dest == DST_PC) ? pc_uart_tx_packet_ready :
         (session_tx_dest == DST_BASYS) ? !basys_spi_tx_pending :
         (session_tx_type == TYPE_JETSON_KEY_CONFIRM) ?
             (!jetson_management_pending && jetson_enc_plaintext_ready) :
             !jetson_management_pending);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enc_active_dest  <= DST_PC;
            pc_iv_counter    <= 64'd1;
            basys_iv_counter <= 64'd1;
        end else if (enc_accept) begin
            enc_active_dest <= enc_selected_dest;
            if (enc_selected_dest == DST_PC)
                pc_iv_counter <= pc_iv_counter + 1'b1;
            else
                basys_iv_counter <= basys_iv_counter + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            jetson_iv_counter <= 64'd1;
            last_jetson_cmd_submitted <= 8'hFF;
            jetson_session_enable_d <= 1'b0;
        end else begin
            jetson_session_enable_d <= jetson_session_normal_enable;
            if (!jetson_session_enable_d && jetson_session_normal_enable)
                last_jetson_cmd_submitted <= 8'hFF;
            if (jetson_enc_accept) begin
                jetson_iv_counter <= jetson_iv_counter + 1'b1;
                if (jetson_enc_packet_type == TYPE_JETSON_TX)
                    last_jetson_cmd_submitted <= door_cmd_to_jetson;
            end
        end
    end

    always_comb begin
        if (!session_normal_enable)
            enc_output_ready = 1'b1; // discard a stale old-key result
        else if (enc_active_dest == DST_PC)
            enc_output_ready = pc_uart_tx_packet_ready &&
                               !session_clear_pc_valid;
        else
            enc_output_ready = !basys_spi_tx_pending &&
                               !session_clear_basys_valid;
    end

    aes_gcm_encrypt_packet u_shared_encrypt (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_data       (active_key),
        .key_load       (enc_key_load),
        .key_ready      (enc_key_ready),
        .key_valid      (enc_key_valid),
        .packet_type    (enc_packet_type),
        .packet_iv      (enc_packet_iv),
        .plaintext      (enc_plaintext),
        .plaintext_valid(enc_plaintext_valid),
        .plaintext_ready(enc_plaintext_ready),
        .packet         (enc_output_packet),
        .packet_valid   (enc_output_valid),
        .packet_ready   (enc_output_ready),
        .busy           ()
    );

    aes_gcm_encrypt_packet u_jetson_encrypt (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_data       (jetson_active_key),
        .key_load       (jetson_enc_key_load),
        .key_ready      (jetson_enc_key_ready),
        .key_valid      (jetson_enc_key_valid),
        .packet_type    (jetson_enc_packet_type),
        .packet_iv      (jetson_enc_packet_iv),
        .plaintext      (jetson_enc_plaintext),
        .plaintext_valid(jetson_enc_plaintext_valid),
        .plaintext_ready(jetson_enc_plaintext_ready),
        .packet         (jetson_enc_output_packet),
        .packet_valid   (jetson_enc_output_valid),
        .packet_ready   (1'b1),
        .busy           ()
    );

    secure_uart_frame_tx #(
        .CLK_FREQ (SYS_CLK_FREQ),
        .BAUD_RATE(UART_BAUD_RATE)
    ) u_pc_frame_tx (
        .clk         (clk),
        .rst_n       (rst_n),
        .packet      (session_clear_pc_valid ? session_clear_frame :
                      enc_output_packet),
        .packet_valid(session_clear_pc_valid ||
                      (enc_output_valid && enc_active_dest == DST_PC &&
                       session_normal_enable)),
        .packet_ready(pc_uart_tx_packet_ready),
        .uart_tx_out (uart_tx_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            basys_spi_tx_packet  <= 384'h0;
            basys_spi_tx_pending <= 1'b0;
            basys_spi_start      <= 1'b0;
            jetson_spi_tx_packet <= 384'h0;
            jetson_management_pending <= 1'b0;
        end else begin
            basys_spi_start <= 1'b0;

            if (enc_output_valid && enc_output_ready &&
                enc_active_dest == DST_BASYS &&
                session_normal_enable && !session_clear_basys_valid) begin
                basys_spi_tx_packet  <= enc_output_packet;
                basys_spi_tx_pending <= 1'b1;
            end

            if (session_clear_basys_valid && session_tx_ready) begin
                basys_spi_tx_packet  <= session_clear_frame;
                basys_spi_tx_pending <= 1'b1;
            end

            // Jetson is the SPI master. A loaded management/confirmation
            // frame remains pending until one complete 384-bit transfer.
            if (jetson_spi_rx_valid)
                jetson_management_pending <= 1'b0;

            if (jetson_enc_output_valid &&
                jetson_enc_output_packet[367:360] ==
                    TYPE_JETSON_KEY_CONFIRM &&
                !jetson_management_pending &&
                !session_clear_jetson_valid) begin
                jetson_spi_tx_packet <= jetson_enc_output_packet;
                jetson_management_pending <= 1'b1;
            end else if (jetson_enc_output_valid &&
                         jetson_session_normal_enable &&
                         !jetson_management_pending &&
                         !session_clear_jetson_valid) begin
                jetson_spi_tx_packet <= jetson_enc_output_packet;
            end

            if (session_clear_jetson_valid && session_tx_ready) begin
                jetson_spi_tx_packet <= session_clear_frame;
                jetson_management_pending <= 1'b1;
            end

            if (basys_spi_tx_pending && !basys_spi_busy) begin
                basys_spi_start      <= 1'b1;
                basys_spi_tx_pending <= 1'b0;
            end
        end
    end
endmodule
