`timescale 1ns / 1ps

// ============================================================================
// Module Name: basys3_secure_rack_control
// Description: 각 Rack의 서보모터(잠금장치) 및 화재 진압용 서보모터 제어용 
//              Basys3 보드 메인 통합 모듈 (Top Module)
//              - ZYBO(관제실 PC)로부터 128-bit SPI 통신으로 제어 명령 수신
//              - [7:0]에 들어있는 랙 번호/명령에 맞는 특정 Rack 서보모터 동작
//              - DHT11 센서로 온도 측정 및 자동 화재 진압 서보 동작
//              - 128-bit MISO 통신으로 센서 데이터 및 화재 상태 보고
// ============================================================================

module basys3_secure_rack_control #(
    parameter integer SYS_CLK_FREQ = 100_000_000, // Basys3 기본 클럭 100MHz
    parameter integer TEMP_THRESHOLD = 30,
    parameter logic [127:0] MASTER_KEY =
        128'h6C8E_9CF5_7093_2BD5_A3F1_04D7_B89E_62C1
)(
    input wire clk,
    input wire rst,

    // SPI Slave Interface (from ZYBO)
    input wire sclk_in,
    input wire mosi_in,
    input wire cs_n_in,
    output wire miso_out,

    // 4-Channel DHT11 Sensor Pins (Pmod JB Top Row)
    inout  wire [3:0] dhtio,
    
    // 4-Channel Fire Extinguisher Servo PWM Output Pins (Pmod JB Bottom Row)
    output wire [3:0] fire_servo_pwm,

    // 4-Channel Rack Door Lock Servo PWM Output Pins (Pmod JA)
    output wire servo_pwm_r1,
    output wire servo_pwm_r2,
    output wire servo_pwm_r3,
    output wire servo_pwm_r4,

    // OV7670 side (Pmod JC & JXADC)
    input  wire       pclk,
    output wire       xclk,
    input  wire       href,
    input  wire       vsync,
    input  wire [7:0] pdata,

    // VGA side
    output wire       h_sync,
    output wire       v_sync,
    output wire [3:0] port_red,
    output wire [3:0] port_green,
    output wire [3:0] port_blue,

    // SCCB (Pmod JXADC)
    output wire scl,
    inout  wire sda,
    
    // Board switches
    input  wire [1:0] sw
);

    wire rst_n = ~rst;

    // --- DHT11 Control and Periodic Trigger ---
    localparam int TRIGGER_LIMIT = 2 * SYS_CLK_FREQ;
    logic [$clog2(TRIGGER_LIMIT)-1:0] trigger_cnt;
    logic dht11_start;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trigger_cnt <= 0;
            dht11_start <= 1'b0;
        end else begin
            if (trigger_cnt >= TRIGGER_LIMIT - 1) begin
                trigger_cnt <= 0;
                dht11_start <= 1'b1;
            end else begin
                trigger_cnt <= trigger_cnt + 1;
                dht11_start <= 1'b0;
            end
        end
    end

    wire [15:0] humidity[4];
    wire [15:0] temperature[4];
    wire        dht11_done[4];
    wire        dht11_valid[4];
    logic [3:0] fire_servo_en_reg;
    logic [3:0] fire_servo_state;

    // 기존 application payload는 계속 128-bit를 유지한다.
    wire [127:0] rx_cmd_data;
    wire         rx_valid;
    logic [127:0] tx_data_out;

    // Wire-format is one fixed 48-byte/384-bit frame. Management frames keep
    // TYPE and R clear; application frames use AES-GCM in the data/tag slots.
    wire [383:0] secure_spi_rx;
    wire         secure_spi_rx_valid;
    wire         secure_spi_tx_started;
    logic [383:0] secure_spi_tx;
    logic [7:0]   secure_spi_tx_type;
    logic [7:0]   spi_response_inflight_type;

    wire [127:0] decrypted_command;
    wire         decrypted_command_valid;
    wire         command_auth_valid;
    wire         secure_auth_failure;
    wire         command_decrypt_ready;
    logic [7:0]  decrypted_packet_type;

    logic enc_key_load;
    logic dec_key_load;
    wire  enc_key_ready;
    wire  enc_key_valid;
    wire  dec_key_ready;
    wire  dec_key_valid;
    logic [127:0] pending_random;
    logic         session_established;
    logic         rekey_in_progress;
    logic         switch_in_progress;
    wire          commit_ack_shifted;

    wire [7:0] secure_spi_rx_type = secure_spi_rx[367:360];
    wire secure_spi_header_valid = secure_spi_rx[383:368] == 16'hA55A &&
                                   secure_spi_rx[359:352] == 8'h10;
    wire clear_management_rx = secure_spi_rx_valid && secure_spi_header_valid &&
        (secure_spi_rx_type == 8'h22 || secure_spi_rx_type == 8'h24 ||
         secure_spi_rx_type == 8'h25 || secure_spi_rx_type == 8'h27 ||
         secure_spi_rx_type == 8'h29);
    wire [127:0] clear_management_payload = secure_spi_rx[255:128];

    typedef enum logic [1:0] {
        KEY_WAIT_READY,
        KEY_PULSE,
        KEY_WAIT_VALID,
        KEY_ACTIVE
    } key_state_t;
    key_state_t key_state;

    assign rx_cmd_data       = decrypted_command;
    assign rx_valid          = decrypted_command_valid && command_auth_valid &&
                               decrypted_packet_type == 8'h04 &&
                               session_established && !rekey_in_progress &&
                               decrypted_command[127:96] == 32'h0;
    assign secure_auth_failure = decrypted_command_valid && !command_auth_valid &&
                                 decrypted_packet_type == 8'h04;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_state    <= KEY_WAIT_READY;
            enc_key_load <= 1'b0;
            dec_key_load <= 1'b0;
            session_established <= 1'b0;
            switch_in_progress <= 1'b0;
        end else begin
            enc_key_load <= 1'b0;
            dec_key_load <= 1'b0;
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
                        if (switch_in_progress) begin
                            session_established <= 1'b1;
                            switch_in_progress <= 1'b0;
                        end
                    end
                end
                KEY_ACTIVE: begin
                    if (commit_ack_shifted) begin
                        switch_in_progress <= 1'b1;
                        key_state <= KEY_WAIT_READY;
                    end
                end
                default:
                    key_state <= KEY_WAIT_READY;
            endcase
        end
    end
    
    // Camera Integration signals
    logic        vga_h_sync;
    logic        vga_v_sync;
    logic [ 9:0] x_pixel;
    logic [ 9:0] y_pixel;
    logic        de;
    logic [11:0] cam_rgb;
    logic        cam_pclk;
    logic        cam_we;
    localparam int ADDR_W = $clog2(320 * 240);
    logic [ADDR_W-1:0] cam_wAddr;
    logic [      15:0] cam_wData;
    logic [11:0] led_flat;  // LED_FLAT_W (12 bits)
    logic [ 5:0] unit_flat; // UNIT_FLAT_W (6 bits)
    logic clk_25M;
    wire rclk;

    // 각 Rack의 잠금 상태 레지스터 (1: 열림, 0: 닫힘)
    reg rack1_open, rack2_open, rack3_open, rack4_open;

    // Last registered valid sensor values for packaging
    logic [15:0] last_humidity[4];
    logic [15:0] last_temperature[4];
    logic [3:0]  last_fire_servo_state;
    logic [3:0]  sensor_done_latched;

    // ========================================================================
    // 1. 수신 데이터 파싱 및 Rack 상태 갱신 / 패키징
    // ========================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rack1_open <= 1'b0;
            rack2_open <= 1'b0;
            rack3_open <= 1'b0;
            rack4_open <= 1'b0;
            sensor_done_latched <= 4'b0;
            tx_data_out         <= 128'h0;
            for (int k = 0; k < 4; k = k + 1) begin
                last_humidity[k]    <= 16'h0;
                last_temperature[k] <= 16'h0;
            end
            last_fire_servo_state <= 4'b0;
        end else begin
            // 인증 실패는 랙을 즉시 안전 상태(Default Close)로 만든다.
            if (secure_auth_failure) begin
                {rack4_open, rack3_open, rack2_open, rack1_open} <= 4'b0000;
            end else if (rx_valid) begin
                // rx_cmd_data[3:0]에 따라 어떤 랙이 1(열림)인지 매핑 (회원님 기존 코드 방식)
                {rack4_open, rack3_open, rack2_open, rack1_open} <= rx_cmd_data[3:0];
            end

            // Track each sensor's valid completion pulse
            for (int k = 0; k < 4; k = k + 1) begin
                if (dht11_done[k] && dht11_valid[k]) begin
                    last_humidity[k]       <= humidity[k];
                    last_temperature[k]    <= temperature[k];
                    sensor_done_latched[k] <= 1'b1;
                end
            end
            last_fire_servo_state <= fire_servo_state;

            // 항상 최신 상태를 SPI 버퍼(tx_data_out)에 업데이트 (센서 하나가 고장나거나 연결 해제되어도 멈추지 않음)
            tx_data_out <= {
                48'b0,
                6'b0, unit_flat[5:0], // [79:68] (camera_state 12 bits space, we use lower 6 bits)
                fire_servo_state[3:0], // 화재가 감지된 랙 정보 4채널 [67:64]
                last_humidity[3][15:8],
                last_temperature[3][15:8],
                last_humidity[2][15:8],
                last_temperature[2][15:8],
                last_humidity[1][15:8],
                last_temperature[1][15:8],
                last_humidity[0][15:8],
                last_temperature[0][15:8]
            };
        end
    end

    // ========================================================================
    // 2. 384-bit secure SPI Slave + AES-GCM adapters
    // ========================================================================
    spi_slave #(
        .DATA_WIDTH (384),
        .CPOL       (1'b0),
        .CPHA       (1'b0)
    ) u_spi_slave (
        .clk        (clk),
        .rst_n      (rst_n),
        .sclk       (sclk_in),
        .cs_n       (cs_n_in),
        .mosi       (mosi_in),
        .miso       (miso_out),
        .rx_data    (secure_spi_rx),
        .rx_valid   (secure_spi_rx_valid),
        .tx_started (secure_spi_tx_started),
        .tx_data    (secure_spi_tx)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            spi_response_inflight_type <= 8'h00;
        else if (secure_spi_tx_started)
            spi_response_inflight_type <= secure_spi_tx_type;
    end

    assign commit_ack_shifted = secure_spi_rx_valid &&
                                (spi_response_inflight_type == 8'h26);

    aes_gcm_decrypt_packet u_command_decrypt (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_data       (MASTER_KEY ^ pending_random),
        .key_load       (dec_key_load),
        .key_ready      (dec_key_ready),
        .key_valid      (dec_key_valid),
        .expected_type  (secure_spi_rx[367:360]),
        .packet         (secure_spi_rx),
        .packet_valid   (secure_spi_rx_valid && !clear_management_rx),
        .packet_ready   (command_decrypt_ready),
        .plaintext      (decrypted_command),
        .plaintext_valid(decrypted_command_valid),
        .auth_valid     (command_auth_valid),
        .plaintext_ready(1'b1),
        .busy           ()
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            decrypted_packet_type <= 8'h00;
        else if (secure_spi_rx_valid && !clear_management_rx &&
                 command_decrypt_ready)
            decrypted_packet_type <= secure_spi_rx[367:360];
    end

    // Management responses are clear frames. Only sensor/camera application
    // status uses the AES-GCM encrypt core.
    logic [127:0] status_snapshot;
    logic [127:0] last_submitted_status;
    logic         status_pending;
    logic         management_response_pending;
    logic [63:0]  status_iv_counter;

    logic [127:0] encrypt_plaintext;
    logic [7:0]   encrypt_packet_type;
    logic         encrypt_plaintext_valid;
    wire          encrypt_plaintext_ready;
    wire [383:0]  encrypted_output_packet;
    wire          encrypted_output_valid;

    always_comb begin
        encrypt_plaintext       = status_snapshot;
        encrypt_packet_type     = 8'h05;
        encrypt_plaintext_valid = 1'b0;

        if (status_pending && session_established && !rekey_in_progress &&
            !management_response_pending && key_state == KEY_ACTIVE) begin
            encrypt_plaintext       = status_snapshot;
            encrypt_packet_type     = 8'h05;
            encrypt_plaintext_valid = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_random             <= 128'h0;
            rekey_in_progress           <= 1'b1;
            status_snapshot            <= 128'h0;
            last_submitted_status      <= {128{1'b1}};
            status_pending             <= 1'b0;
            management_response_pending <= 1'b0;
            status_iv_counter          <= 64'd1;
            secure_spi_tx              <= 384'h0;
            secure_spi_tx_type         <= 8'h00;
        end else begin
            if (session_established && !status_pending &&
                tx_data_out != last_submitted_status) begin
                status_snapshot <= tx_data_out;
                status_pending  <= 1'b1;
            end

            if (encrypt_plaintext_valid && encrypt_plaintext_ready) begin
                status_iv_counter <= status_iv_counter + 1'b1;
                last_submitted_status <= status_snapshot;
                status_pending <= 1'b0;
            end

            // The SPI slave snapshots tx_data at transfer start. Once a clear
            // management response starts shifting, the holding lock may clear.
            if (secure_spi_tx_started &&
                (secure_spi_tx_type == 8'h23 ||
                 secure_spi_tx_type == 8'h26 ||
                 secure_spi_tx_type == 8'h28))
                management_response_pending <= 1'b0;

            // A newly committed key must produce a fresh status ciphertext.
            if (commit_ack_shifted) begin
                status_pending <= 1'b0;
                last_submitted_status <= {128{1'b1}};
                // The encrypted packet may remain in tx_data, but it must not
                // request another key switch on the following SPI transfer.
                secure_spi_tx_type <= 8'h00;
            end

            // Management TYPE and R are carried in clear. The 128-bit R is in
            // the normal data slot [255:128], and the tag slot is zero.
            if (clear_management_rx) begin
                case (secure_spi_rx_type)
                    8'h22: begin // KEY_UPDATE
                        rekey_in_progress <= 1'b1;
                        pending_random <= clear_management_payload;
                        secure_spi_tx <= {16'hA55A, 8'h23, 8'h10, 96'h0,
                                          clear_management_payload, 128'h0};
                        secure_spi_tx_type <= 8'h23; // READY
                        management_response_pending <= 1'b1;
                    end
                    8'h25: begin // KEY_COMMIT
                        secure_spi_tx <= {16'hA55A, 8'h26, 8'h10, 96'h0,
                                          pending_random, 128'h0};
                        secure_spi_tx_type <= 8'h26; // COMMIT_ACK
                        management_response_pending <= 1'b1;
                    end
                    8'h27: begin // KEY_CONFIRM
                        if (session_established) begin
                            secure_spi_tx <= {16'hA55A, 8'h28, 8'h10, 96'h0,
                                              pending_random, 128'h0};
                            secure_spi_tx_type <= 8'h28; // CONFIRM_ACK
                            management_response_pending <= 1'b1;
                            rekey_in_progress <= 1'b0;
                        end
                    end
                    default: begin end // POLL packets only clock out MISO
                endcase
            end

            if (encrypted_output_valid && !clear_management_rx &&
                !management_response_pending && !rekey_in_progress) begin
                secure_spi_tx      <= encrypted_output_packet;
                secure_spi_tx_type <= encrypted_output_packet[367:360];
            end
        end
    end

    aes_gcm_encrypt_packet u_status_encrypt (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_data       (MASTER_KEY ^ pending_random),
        .key_load       (enc_key_load),
        .key_ready      (enc_key_ready),
        .key_valid      (enc_key_valid),
        .packet_type    (encrypt_packet_type),
        .packet_iv      ({32'h0500_0001, status_iv_counter}),
        .plaintext      (encrypt_plaintext),
        .plaintext_valid(encrypt_plaintext_valid),
        .plaintext_ready(encrypt_plaintext_ready),
        .packet         (encrypted_output_packet),
        .packet_valid   (encrypted_output_valid),
        .packet_ready   (1'b1),
        .busy           ()
    );

    // ========================================================================
    // 3. DHT11 및 화재 서보모터 인스턴스화 (4채널)
    // ========================================================================
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_dht11_fire
            // DHT11 센서
            dht11_controller U_DHT11 (
                .clk(clk),
                .rst(rst),
                .start(dht11_start),
                .humidity(humidity[i]),
                .temperature(temperature[i]),
                .dht11_done(dht11_done[i]),
                .dht11_valid(dht11_valid[i]),
                .debug(),
                .dhtio(dhtio[i])
            );

            // 화재 감지 로직 (온도 30도 이상 시)
            always_ff @(posedge clk or posedge rst) begin
                if (rst) begin
                    fire_servo_en_reg[i] <= 1'b0;
                end else if (dht11_done[i] && dht11_valid[i]) begin
                    if (temperature[i][15:8] >= TEMP_THRESHOLD) begin
                        fire_servo_en_reg[i] <= 1'b1;
                    end else if (temperature[i][15:8] < TEMP_THRESHOLD - 1) begin
                        fire_servo_en_reg[i] <= 1'b0;
                    end
                end
            end

            // 화재 진압용 서보모터 컨트롤러 (90도 회전, 1500us)
            fire_servo_controller #(
                .CLK_FREQ(SYS_CLK_FREQ),
                .PERIOD_MS(20),
                .PULSE_MIN_US(650),
                .PULSE_MAX_US(1500)
            ) U_FIRE_SERVO (
                .clk(clk),
                .rst_n(rst_n),
                .servo_en(fire_servo_en_reg[i]),
                .pwm(fire_servo_pwm[i]),
                .servo_state(fire_servo_state[i])
            );
        end
    endgenerate

    // ========================================================================
    // 4. 랙 잠금장치용 서보모터 제어기 인스턴스화 (Rack 1 ~ 4)
    // ========================================================================
    rack_servo_controller #(
        .CLOCK_FREQ_HZ(SYS_CLK_FREQ),
        .PWM_FREQ_HZ(50),
        .CLOSE_PULSE_US(1000), 
        .OPEN_PULSE_US(2000)
    ) u_servo_r1 (
        .clk(clk),
        .rst_n(rst_n),
        .open_cmd(rack1_open),
        .servo_pwm(servo_pwm_r1)
    );

    rack_servo_controller #(
        .CLOCK_FREQ_HZ(SYS_CLK_FREQ),
        .PWM_FREQ_HZ(50),
        .CLOSE_PULSE_US(1000),
        .OPEN_PULSE_US(2000)
    ) u_servo_r2 (
        .clk(clk),
        .rst_n(rst_n),
        .open_cmd(rack2_open),
        .servo_pwm(servo_pwm_r2)
    );

    rack_servo_controller #(
        .CLOCK_FREQ_HZ(SYS_CLK_FREQ),
        .PWM_FREQ_HZ(50),
        .CLOSE_PULSE_US(1000),
        .OPEN_PULSE_US(2000)
    ) u_servo_r3 (
        .clk(clk),
        .rst_n(rst_n),
        .open_cmd(rack3_open),
        .servo_pwm(servo_pwm_r3)
    );

    rack_servo_controller #(
        .CLOCK_FREQ_HZ(SYS_CLK_FREQ),
        .PWM_FREQ_HZ(50),
        .CLOSE_PULSE_US(1000),
        .OPEN_PULSE_US(2000)
    ) u_servo_r4 (
        .clk(clk),
        .rst_n(rst_n),
        .open_cmd(rack4_open),
        .servo_pwm(servo_pwm_r4)
    );

    // ========================================================================
    // 5. Camera & VGA & LED Logic (from MATS_prj)
    // ========================================================================
    CAM_Set #(
        .IMG_W (320),
        .IMG_H (240),
        .ADDR_W(ADDR_W)
    ) U_CAM_SET (
        .clk  (clk),     // 100MHz system clock
        .reset(rst),

        .pclk (pclk),
        .href (href),
        .vsync(vsync),
        .pdata(pdata),
        .xclk (xclk),

        .scl(scl),
        .sda(sda),

        .clk_100M(),     // CAM_Set will generate its own 100MHz and 25MHz if clk is passed (actually CAM_Set uses clk internally to generate clk_100M and clk_25M)
        .clk_25M (clk_25M),

        .cam_fb_rclk(rclk),
        .x_pixel    (x_pixel),
        .y_pixel    (y_pixel),
        .de         (de),
        .cam_rgb    (cam_rgb),

        .cam_pclk (cam_pclk),
        .cam_we   (cam_we),
        .cam_wAddr(cam_wAddr),
        .cam_wData(cam_wData)
    );

    VGA_Decoder U_VGA_DECODER (
        .clk  (clk), // Use system clock (100MHz)
        .reset(rst),

        .rclk   (rclk),
        .h_sync (vga_h_sync),
        .v_sync (vga_v_sync),
        .x_pixel(x_pixel),
        .y_pixel(y_pixel),
        .de     (de)
    );

    LED_Set #(
        .IMG_W (320),
        .IMG_H (240),
        .ADDR_W(ADDR_W)
    ) U_LED_SET (
        .reset(rst),

        .cam_pclk (cam_pclk),
        .cam_we   (cam_we),
        .cam_wAddr(cam_wAddr),
        .cam_wData(cam_wData),

        .led_flat (led_flat),
        .unit_flat(unit_flat),
        .payload  () // Ignore payload since we pack unit_flat ourselves
    );

    Frame_Set #(
        .IMG_W (320),
        .IMG_H (240),
        .ADDR_W(ADDR_W)
    ) U_FRAME_SET (
        .clk_100M(clk), // Use system clock
        .reset   (rst),

        .h_sync_i(vga_h_sync),
        .v_sync_i(vga_v_sync),
        .x_pixel (x_pixel),
        .y_pixel (y_pixel),
        .de      (de),

        .screen_rgb(cam_rgb),
        .led_flat  (led_flat),
        .overlay_en(sw[0]),

        .h_sync    (h_sync),
        .v_sync    (v_sync),
        .port_red  (port_red),
        .port_green(port_green),
        .port_blue (port_blue)
    );

endmodule
