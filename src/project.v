/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output reg  [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    wire _unused = &{uio_in, ena, clk, rst_n, 1'b0};

    assign uio_out = 0;
    assign uio_oe  = 0;

    always_comb begin
        priority casez (ui_in)
            8'b00000000: uo_out = 8'b10111111;
            8'b00000001: uo_out = 8'b10000110;
            8'b0000001z: uo_out = 8'b11011011;
            8'b000001zz: uo_out = 8'b11001111;
            8'b00001zzz: uo_out = 8'b11100110;
            8'b0001zzzz: uo_out = 8'b11101101;
            8'b001zzzzz: uo_out = 8'b11111101;
            8'b01zzzzzz: uo_out = 8'b10000111;
            8'b1zzzzzzz: uo_out = 8'b11111111;
        endcase
    end

endmodule
