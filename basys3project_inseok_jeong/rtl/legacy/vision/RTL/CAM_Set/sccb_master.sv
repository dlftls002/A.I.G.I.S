`timescale 1ns / 1ps

module sccb_master (
    input  logic       clk,
    input  logic       reset,

    // Data Transfer
    input  logic       valid,
    input  logic       rw,
    input  logic [7:0] in_addr,
    input  logic [7:0] w_data,
    output logic       ready,

    output logic [7:0] r_data,
    output logic       r_valid,

    // SCCB 
    output logic       scl,
    inout  logic       sda
);

    localparam [2:0] REG_WAIT  = 3'b000;
    localparam [2:0] START     = 3'b001;
    localparam [2:0] ID_ADDR   = 3'b010;
    localparam [2:0] INTE_ADDR = 3'b011;
    localparam [2:0] READ      = 3'b100;
    localparam [2:0] WRITE     = 3'b101;
    localparam [2:0] STOP      = 3'b110;

    // Internal Wire
    logic       done;
    logic       cmd_start;
    logic       cmd_write;
    logic       cmd_read;
    logic       cmd_stop;
    logic [7:0] tx_data;
    logic [7:0] rx_data;

    // Registers
    logic [2:0] state;
    logic       rw_reg;
    logic [7:0] in_addr_reg;
    logic [7:0] w_data_reg;
    logic [7:0] r_data_reg;

    // I2C_MASTER
    I2C_MASTER U_I2C_MASTER (
        .clk        (clk),
        .reset      (reset),
        .cmd_start  (cmd_start),
        .cmd_write  (cmd_write),
        .cmd_read   (cmd_read),
        .cmd_stop   (cmd_stop),
        .tx_data    (tx_data),
        .ack_in     (1'b0),
        .rx_data    (rx_data),
        .done       (done),
        .scl        (scl),
        .sda        (sda)
    );

    always_ff @( posedge clk ) begin
        if (reset) begin
            state       <= REG_WAIT;
            rw_reg      <= 1'b0;
            in_addr_reg <= 0;
            w_data_reg  <= 0;
            r_data_reg  <= 0;
            r_valid     <= 0;
        end else begin
            tx_data <= 0;
            r_valid <= 0;
            case(state)
                REG_WAIT: begin
                    ready <= 1'b1;
                    rw_reg      <= 1'b0;
                    in_addr_reg <= 0;
                    w_data_reg  <= 0;
                    r_data_reg  <= 0;

                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;
                    
                    if (valid) begin
                        state <= START;
                        rw_reg      <= rw;
                        in_addr_reg <= in_addr;
                        w_data_reg  <= w_data;
                        
                        cmd_start   <= 1;
                    end else begin
                        state <= REG_WAIT;
                    end   
                end
                START: begin
                    ready <= 1'b0;
                    
                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;

                    if (done) begin
                        state <= ID_ADDR;
                        
                        cmd_write <= 1;
                        tx_data <= 8'h42;
                    end else begin
                        state <= START;
                    end
                end
                ID_ADDR:begin
                    ready <= 0;
                    
                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;
                    
                    if (done) begin
                        state <= INTE_ADDR;

                        cmd_write <= 1;
                        tx_data <= in_addr_reg;
                    end else begin
                        state <= ID_ADDR;
                    end
                end
                INTE_ADDR:begin
                    ready <= 0;
                    
                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;
                    
                    if (done) begin
                        if (rw_reg == 0) begin // READ
                            state <= READ;
                            
                            cmd_read  <= 1;
                        end else begin // WRITE
                            state <= WRITE;
                            
                            cmd_write <= 1;
                            tx_data  <= w_data_reg;
                        end
                    end else begin
                        state <= INTE_ADDR;
                    end
                end
                READ: begin
                    ready <= 0;
                    
                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;
                    
                    if (done) begin
                        state <= STOP;
                        
                        cmd_stop <= 1;
                        r_data_reg <= rx_data;
                        r_valid <= 1;
                    end else begin
                        state <= READ;
                    end
                end
                WRITE: begin
                    ready <= 0;
                    
                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;
                    
                    if (done) begin
                        state <= STOP;

                        cmd_stop <= 1;
                    end else begin
                        state <= WRITE;
                    end
                end
                STOP: begin
                    ready <= 0;
                    
                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;
                    
                    if (done) begin
                        state <= REG_WAIT;
                    end else begin
                        state <= STOP;
                    end
                end
                default: begin
                    state <= REG_WAIT;
                    
                    ready <= 0;
                    
                    // CMD
                    cmd_start <= 0;
                    cmd_write <= 0;
                    cmd_read  <= 0;
                    cmd_stop  <= 0;
                end
            endcase
        end
    end

    assign r_data = r_data_reg;

endmodule

module I2C_MASTER (
    input  logic       clk,
    input  logic       reset,
    // command port
    input  logic       cmd_start,
    input  logic       cmd_write,
    input  logic       cmd_read,
    input  logic       cmd_stop,
    input  logic [7:0] tx_data,
    input  logic       ack_in,
    // internal output
    output logic [7:0] rx_data,
    output logic       done,
    output logic       ack_out,
    output logic       busy,
    // external i2c port
    output logic       scl,
    inout  wire        sda
);

    logic sda_o, sda_i;

    assign sda_i = sda;
    assign sda   = sda_o ? 1'bz : 1'b0;

    i2c_master u_i2c_master (
        .clk(clk),
        .reset(reset),
        .cmd_start(cmd_start),
        .cmd_write(cmd_write),
        .cmd_read(cmd_read),
        .cmd_stop(cmd_stop),
        .tx_data(tx_data),
        .ack_in(ack_in),
        .rx_data(rx_data),
        .done(done),
        .ack_out(ack_out),
        .busy(busy),
        .scl(scl),
        .sda_o(sda_o),
        .sda_i(sda_i)
    );

endmodule

module i2c_master (
    input  logic       clk,
    input  logic       reset,
    // command port
    input  logic       cmd_start,
    input  logic       cmd_write,
    input  logic       cmd_read,
    input  logic       cmd_stop,
    input  logic [7:0] tx_data,
    input  logic       ack_in,
    // internal output
    output logic [7:0] rx_data,
    output logic       done,
    output logic       ack_out,
    output logic       busy,
    // external i2c port
    output logic       scl,
    output logic       sda_o,
    input  logic       sda_i
);

    localparam logic [2:0] IDLE     = 3'b000;
    localparam logic [2:0] START    = 3'b001;
    localparam logic [2:0] WAIT_CMD = 3'b010;
    localparam logic [2:0] DATA     = 3'b011;
    localparam logic [2:0] DATA_ACK = 3'b100;
    localparam logic [2:0] STOP     = 3'b101;

    logic [2:0] state;
    logic [7:0] div_cnt;
    logic       qtr_tick;
    logic       scl_r, sda_r;
    logic [1:0] step;
    logic [7:0] tx_shift_reg, rx_shift_reg;
    logic [2:0] bit_cnt;
    logic       is_read, ack_in_r;

    assign scl   = scl_r;
    assign sda_o = sda_r;
    assign busy  = (state != IDLE) && (state != WAIT_CMD);

    // 400KHz SCL 클럭의 한 주기를 안전하게 제어하기위해
    // step 0~3으로 쪼개어 동작. 400KHz / 4단계 = 100KHz
    always_ff @(posedge clk) begin
        if (reset) begin
            div_cnt  <= 0;
            qtr_tick <= 1'b0;
        end else begin
            if (div_cnt == 250 - 1) begin  // scl : 100khz
                div_cnt  <= 0;
                qtr_tick <= 1'b1;
            end else begin
                div_cnt  <= div_cnt + 1;
                qtr_tick <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state        <= IDLE;
            scl_r        <= 1'b1;
            sda_r        <= 1'b1;
            //busy       <= 1'b0;
            step         <= 0;
            done         <= 1'b0;
            tx_shift_reg <= 0;
            rx_shift_reg <= 0;
            is_read      <= 1'b0;
            bit_cnt      <= 0;
            ack_in_r     <= 1'b1;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    scl_r <= 1'b1;
                    sda_r <= 1'b1;
                    //busy  <= 1'b0;
                    if (cmd_start) begin
                        state <= START;
                        step  <= 0;
                        //busy  <= 1'b1;
                    end
                end
                START: begin
                    if (qtr_tick) begin
                        case (step)
                            2'd0: begin
                                scl_r <= 1'b1;
                                sda_r <= 1'b1;
                                step  <= 2'd1;
                            end
                            2'd1: begin
                                sda_r <= 1'b0;
                                step  <= 2'd2;
                            end
                            2'd2: begin
                                step <= 2'd3;
                            end
                            2'd3: begin
                                scl_r <= 1'b0;
                                step  <= 2'd0;
                                done  <= 1'b1;
                                state <= WAIT_CMD;
                            end
                        endcase
                    end
                end
                WAIT_CMD: begin
                    step <= 0;
                    if (cmd_write) begin
                        tx_shift_reg <= tx_data;
                        bit_cnt      <= 0;
                        is_read      <= 1'b0;
                        state        <= DATA;
                    end else if (cmd_read) begin
                        rx_shift_reg <= 0;
                        bit_cnt      <= 0;
                        is_read      <= 1'b1;
                        ack_in_r     <= ack_in;
                        state        <= DATA;
                    end else if (cmd_stop) begin
                        state <= STOP;
                    end else if (cmd_start) begin
                        state <= START;
                    end
                end
                DATA: begin
                    if (qtr_tick) begin
                        case (step)
                            2'd0: begin
                                scl_r <= 1'b0;
                                sda_r <= is_read ? 1'b1 : tx_shift_reg[7];
                                step  <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                step  <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b1;
                                if (is_read) begin
                                    rx_shift_reg <= {rx_shift_reg[6:0], sda_i};
                                end
                                step <= 2'd3;
                            end
                            2'd3: begin
                                scl_r <= 1'b0;
                                if (!is_read) begin
                                    tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
                                end
                                step <= 2'd0;
                                if (bit_cnt == 7) begin
                                    state <= DATA_ACK;
                                end else begin
                                    bit_cnt <= bit_cnt + 1;
                                end
                            end
                        endcase
                    end
                end
                DATA_ACK: begin
                    if (qtr_tick) begin
                        case (step)
                            2'd0: begin
                                scl_r <= 1'b0;
                                if (is_read) begin
                                    sda_r <= ack_in_r;
                                end else begin
                                    sda_r <= 1'b1;  // sda input setting
                                end
                                step <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                step  <= 2'd2;
                            end
                            2'd2: begin
                                scl_r <= 1'b1;
                                if (!is_read) begin  // ack susin
                                    ack_out <= sda_i;
                                end
                                if (is_read) begin
                                    rx_data <= rx_shift_reg;
                                end
                                step <= 2'd3;
                            end
                            2'd3: begin
                                scl_r <= 1'b0;
                                done  <= 1'b1;
                                step  <= 2'd0;
                                state <= WAIT_CMD;
                            end
                        endcase
                    end
                end
                STOP: begin
                    if (qtr_tick) begin
                        case (step)
                            2'd0: begin
                                scl_r <= 1'b0;
                                sda_r <= 1'b0;
                                step  <= 2'd1;
                            end
                            2'd1: begin
                                scl_r <= 1'b1;
                                step  <= 2'd2;
                            end
                            2'd2: begin
                                sda_r <= 1'b1;
                                step  <= 2'd3;
                            end
                            2'd3: begin
                                step  <= 2'd0;
                                done  <= 1'b1;
                                state <= IDLE;
                            end
                        endcase
                    end
                end
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
