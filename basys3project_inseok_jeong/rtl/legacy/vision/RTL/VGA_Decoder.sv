
module VGA_Decoder (
    input  logic       clk,
    input  logic       reset,
    output logic       rclk,
    output logic       h_sync,
    output logic       v_sync,
    output logic [9:0] x_pixel,
    output logic [9:0] y_pixel,
    output logic       de
);

    logic pclk;
    logic [9:0] h_count;  // 0 ~ 799
    logic [9:0] v_count;  // 0 ~ 524

    assign rclk = pclk;

    pclk_gen u_pclk_gen (
        .clk  (clk),
        .reset(reset),
        .pclk (pclk)
    );

    pixel_counter u_pixel_counter (
        .clk    (clk),
        .reset  (reset),
        .pclk   (pclk),
        .h_count(h_count),  // 0 ~ 799
        .v_count(v_count)   // 0 ~ 524
    );

    vga_decoder u_vga_decoder (
        .h_count(h_count),
        .v_count(v_count),
        .h_sync (h_sync),
        .v_sync (v_sync),
        .x_pixel(x_pixel),
        .y_pixel(y_pixel),
        .de     (de)
    );

endmodule

module pclk_gen (
    input  logic clk,
    input  logic reset,
    output logic pclk
);
    logic [1:0] p_counter;

    always_ff @(posedge clk) begin
        if (reset) begin
            p_counter <= 0;
            pclk      <= 1'b0;
        end else begin
            if (p_counter == 2'd3) begin
                p_counter <= 0;
                pclk      <= 1'b1;
            end else begin
                p_counter <= p_counter + 1;
                pclk      <= 1'b0;
            end
        end
    end
endmodule

module pixel_counter (
    input  logic       clk,
    input  logic       reset,
    input  logic       pclk,
    output logic [9:0] h_count,  // 0 ~ 799
    output logic [9:0] v_count   // 0 ~ 524
);
    localparam H_MAX = 800, V_MAX = 525;

    always_ff @(posedge clk) begin
        if (reset) begin
            h_count <= 0;
        end else begin
            if (pclk) begin
                if (h_count == H_MAX - 1) begin
                    h_count <= 0;
                end else begin
                    h_count <= h_count + 1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            v_count <= 0;
        end else begin
            if (pclk) begin
                if (h_count == H_MAX - 1) begin
                    if (v_count == V_MAX - 1) begin
                        v_count <= 0;
                    end else begin
                        v_count <= v_count + 1;
                    end
                end
            end
        end
    end
endmodule

module vga_decoder (
    input  logic [9:0] h_count,
    input  logic [9:0] v_count,
    output logic       h_sync,
    output logic       v_sync,
    output logic [9:0] x_pixel,
    output logic [9:0] y_pixel,
    output logic       de
);

    localparam H_Visible_area = 640;
    localparam H_Front_porch = 16;
    localparam H_Sync_pulse = 96;
    localparam H_Back_porch = 48;
    localparam H_Whole_line = 800;

    localparam V_Visible_area = 480;
    localparam V_Front_porch = 10;
    localparam V_Sync_pulse = 2;
    localparam V_Back_porch = 33;
    localparam V_Whole_frame = 525;

    assign h_sync = !((h_count >= (H_Visible_area + H_Front_porch)) 
                 && (h_count < (H_Visible_area + H_Front_porch + H_Sync_pulse)));
    assign v_sync = !((v_count >= (V_Visible_area + V_Front_porch)) 
                 && (v_count < (V_Visible_area + V_Front_porch + V_Sync_pulse)));
    assign de = (h_count < H_Visible_area) && (v_count < V_Visible_area);
    assign x_pixel = h_count;
    assign y_pixel = v_count;
endmodule
