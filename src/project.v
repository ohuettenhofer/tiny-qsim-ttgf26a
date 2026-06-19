`default_nettype none

/* verilator lint_off DECLFILENAME */
module tt_um_ohuettenhofer_tiny_qsim (
    input  wire  [7:0] ui_in,
    output logic [7:0] uo_out,
    input  wire  [7:0] uio_in,
    output wire  [7:0] uio_out,
    output wire  [7:0] uio_oe,
    input  wire        ena,
    input  wire        clk,
    input  wire        rst_n
);
    /* verilator lint_on DECLFILENAME */

    localparam logic signed [7:0] QMAX = 8'sd127;

    localparam logic [3:0] PH_IDLE = 4'd0, PH_H_A = 4'd1,  // ht_in = zr-or
    PH_H_B = 4'd2,  // ht_in = zr+or ; scale(zr-or)
    PH_H_C = 4'd3,  // ht_in = zi-oi ; scale(zr+or) -> zero_r, one_r
    PH_H_D = 4'd4,  // ht_in = zi+oi ; scale(zi-oi)
    PH_H_E = 4'd5,  //                 scale(zi+oi) -> zero_i, one_i
    PH_T_A = 4'd6,  // ht_in = or-oi
    PH_T_B = 4'd7,  // ht_in = or+oi ; scale(or-oi)
    PH_T_C = 4'd8,  //                 scale(or+oi) -> one_r, one_i
    PH_M_A = 4'd9,  // sq = zr^2
    PH_M_B = 4'd10,  // sq = zi^2 ; acc_tot = zr^2
    PH_M_C = 4'd11,  // sq = br^2 ; acc_tot += zi^2
    PH_M_D = 4'd12,  // sq = bi^2 ; acc_tot += br^2 ; acc_b = br^2
    PH_M_E = 4'd13,  // total_top, b_top  (adds only)
    PH_M_F = 4'd14,  // prod = lfsr * total_top
    PH_M_G = 4'd15;  // compare + collapse

    localparam logic [2:0]
        OP_RST = 3'd0,
        OP_X   = 3'd1,
        OP_Y   = 3'd2,
        OP_Z   = 3'd3,
        OP_H   = 3'd4,
        OP_S   = 3'd5,
        OP_T   = 3'd6,
        OP_MSR = 3'd7;

    wire       start = ui_in[3];
    wire [2:0] opc = ui_in[2:0];

    logic signed [7:0] zero_r, zero_i, one_r, one_i;
    logic done, msr_res;
    logic [3:0] phase;

    logic [7:0] lfsr;
    always_ff @(posedge clk) begin
        if (!rst_n) lfsr <= 8'd1;
        else lfsr <= lfsr[0] ? ((lfsr >> 1) ^ 8'h8E) : (lfsr >> 1);
    end

    function automatic logic [6:0] abs_q(input logic signed [7:0] v);
        begin
            abs_q = v[7] ? (~v[6:0] + 7'd1) : v[6:0];
        end
    endfunction

    // ---------------- H/T stage A: operand select + single add/sub --------
    logic signed [8:0] ht_a, ht_b;
    logic ht_sub;
    always_comb begin
        ht_a   = 9'sd0;
        ht_b   = 9'sd0;
        ht_sub = 1'b0;
        case (phase)
            PH_H_A: begin
                ht_a   = {zero_r[7], zero_r};
                ht_b   = {one_r[7], one_r};
                ht_sub = 1'b1;
            end
            PH_H_B: begin
                ht_a   = {zero_r[7], zero_r};
                ht_b   = {one_r[7], one_r};
                ht_sub = 1'b0;
            end
            PH_H_C: begin
                ht_a   = {zero_i[7], zero_i};
                ht_b   = {one_i[7], one_i};
                ht_sub = 1'b1;
            end
            PH_H_D: begin
                ht_a   = {zero_i[7], zero_i};
                ht_b   = {one_i[7], one_i};
                ht_sub = 1'b0;
            end
            PH_T_A: begin
                ht_a   = {one_r[7], one_r};
                ht_b   = {one_i[7], one_i};
                ht_sub = 1'b1;
            end
            PH_T_B: begin
                ht_a   = {one_r[7], one_r};
                ht_b   = {one_i[7], one_i};
                ht_sub = 1'b0;
            end
            default: ;
        endcase
    end
    wire signed [8:0] ht_next = ht_sub ? (ht_a - ht_b) : (ht_a + ht_b);
    logic signed [8:0] htin_r;  // registered add/sub result (stage A -> B)
    logic signed [7:0] vtmp;  // one held scaled value

    // ---------------- H/T stage B: scale by 181/256 ~= 1/sqrt(2) ----------
    wire signed [16:0] sc_scaled = htin_r * 17'sd181 + 17'sd128;  // round-to-nearest
    wire signed [8:0] sc_round = sc_scaled[16:8];
    wire signed [ 7:0] sc_value =
        (sc_round >  9'sd127) ?  QMAX :
        (sc_round < -9'sd127) ? -QMAX : sc_round[7:0];

    // Pipeline registers for the measurement accumulator.  Each cycle does at
    // most ONE heavy op: a multiply OR an add (never multiply -> add -> add).
    logic [13:0] sq;  // last computed square (registered multiplier out)
    logic [15:0] acc_tot;  // running zr^2+zi^2+br^2 (+bi^2 added at M_E)
    logic [13:0] acc_b;  // br^2 (bi^2 added at M_E)
    logic [14:0] prod;  // lfsr * total_top
    logic [6:0] total_top;
    logic [6:0] b_top;

    // ---------------- shared 8x7 multiplier (squares + measurement) -------
    logic [7:0] mul_a;
    logic [6:0] mul_b;
    always_comb begin
        mul_a = 8'd0;
        mul_b = 7'd0;
        case (phase)
            PH_M_A: begin
                mul_a = {1'b0, abs_q(zero_r)};
                mul_b = abs_q(zero_r);
            end
            PH_M_B: begin
                mul_a = {1'b0, abs_q(zero_i)};
                mul_b = abs_q(zero_i);
            end
            PH_M_C: begin
                mul_a = {1'b0, abs_q(one_r)};
                mul_b = abs_q(one_r);
            end
            PH_M_D: begin
                mul_a = {1'b0, abs_q(one_i)};
                mul_b = abs_q(one_i);
            end
            PH_M_F: begin
                mul_a = lfsr;
                mul_b = total_top;
            end
            default: ;
        endcase
    end
    wire [14:0] mul_p = mul_a * mul_b;

    // Final accumulator sums (used at PH_M_E only); high/low bits discarded.
    wire [15:0] tot_sum = acc_tot + {2'b0, sq};
    wire [14:0] b_sum = {1'b0, acc_b} + {1'b0, sq};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            done    <= 1'b0;
            msr_res <= 1'b0;
            phase   <= PH_IDLE;
            zero_r  <= QMAX;
            zero_i  <= 8'sd0;
            one_r   <= 8'sd0;
            one_i   <= 8'sd0;
        end else begin
            case (phase)
                PH_IDLE: begin
                    if (start != done) begin
                        case (opc)
                            OP_RST: begin
                                zero_r <= QMAX;
                                zero_i <= 8'sd0;
                                one_r <= 8'sd0;
                                one_i <= 8'sd0;
                                msr_res <= 1'b0;
                                done <= start;
                            end
                            OP_X: begin
                                zero_r <= one_r;
                                zero_i <= one_i;
                                one_r  <= zero_r;
                                one_i  <= zero_i;
                                done   <= start;
                            end
                            OP_Y: begin
                                zero_r <= one_i;
                                zero_i <= -one_r;
                                one_r  <= -zero_i;
                                one_i  <= zero_r;
                                done   <= start;
                            end
                            OP_Z: begin
                                one_r <= -one_r;
                                one_i <= -one_i;
                                done  <= start;
                            end
                            OP_S: begin
                                one_r <= -one_i;
                                one_i <= one_r;
                                done  <= start;
                            end
                            OP_H: phase <= PH_H_A;
                            OP_T: phase <= PH_T_A;
                            OP_MSR: phase <= PH_M_A;
                            default: ;
                        endcase
                    end
                end

                // ---- Hadamard (software-pipelined add/sub then scale) ----
                PH_H_A: begin
                    htin_r <= ht_next;
                    phase  <= PH_H_B;
                end  // load zr-or
                PH_H_B: begin
                    htin_r <= ht_next;  // load zr+or
                    vtmp   <= sc_value;  // scale(zr-or)
                    phase  <= PH_H_C;
                end
                PH_H_C: begin
                    htin_r <= ht_next;  // load zi-oi
                    zero_r <= sc_value;  // scale(zr+or)
                    one_r  <= vtmp;  // scale(zr-or)
                    phase  <= PH_H_D;
                end
                PH_H_D: begin
                    htin_r <= ht_next;  // load zi+oi
                    vtmp   <= sc_value;  // scale(zi-oi)
                    phase  <= PH_H_E;
                end
                PH_H_E: begin
                    zero_i <= sc_value;  // scale(zi+oi)
                    one_i  <= vtmp;  // scale(zi-oi)
                    done   <= start;
                    phase  <= PH_IDLE;
                end

                // ---- T gate ----
                PH_T_A: begin
                    htin_r <= ht_next;
                    phase  <= PH_T_B;
                end  // load or-oi
                PH_T_B: begin
                    htin_r <= ht_next;  // load or+oi
                    vtmp   <= sc_value;  // scale(or-oi)
                    phase  <= PH_T_C;
                end
                PH_T_C: begin
                    one_r <= vtmp;  // scale(or-oi)
                    one_i <= sc_value;  // scale(or+oi)
                    done  <= start;
                    phase <= PH_IDLE;
                end

                // ---- Measurement (one multiply or one add per cycle) ----
                PH_M_A: begin
                    sq <= mul_p[13:0];
                    phase <= PH_M_B;
                end  // zr^2
                PH_M_B: begin
                    sq      <= mul_p[13:0];  // zi^2
                    acc_tot <= {2'b0, sq};  // zr^2
                    phase   <= PH_M_C;
                end
                PH_M_C: begin
                    sq      <= mul_p[13:0];  // br^2
                    acc_tot <= acc_tot + {2'b0, sq};  // zr^2+zi^2
                    phase   <= PH_M_D;
                end
                PH_M_D: begin
                    sq      <= mul_p[13:0];  // bi^2
                    acc_tot <= acc_tot + {2'b0, sq};  // zr^2+zi^2+br^2
                    acc_b   <= sq;  // br^2
                    phase   <= PH_M_E;
                end
                PH_M_E: begin
                    total_top <= tot_sum[14:8];  // (zr^2+zi^2+br^2+bi^2)>>8
                    b_top     <= b_sum[14:8];  // (br^2+bi^2)>>8
                    phase     <= PH_M_F;
                end
                PH_M_F: begin
                    prod  <= mul_p;  // lfsr * total_top
                    phase <= PH_M_G;
                end
                PH_M_G: begin
                    msr_res <= (prod < {b_top, 8'd0});
                    if (prod < {b_top, 8'd0}) begin
                        zero_r <= 8'sd0;
                        zero_i <= 8'sd0;
                        one_r  <= QMAX;
                        one_i  <= 8'sd0;
                    end else begin
                        zero_r <= QMAX;
                        zero_i <= 8'sd0;
                        one_r  <= 8'sd0;
                        one_i  <= 8'sd0;
                    end
                    done  <= start;
                    phase <= PH_IDLE;
                end

                default: phase <= PH_IDLE;
            endcase
        end
    end

    assign uo_out  = {6'b0, done, msr_res};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // sc_scaled[7:0] are discarded rounding bits; tot_sum/b_sum keep only
    // their [14:8] slice (the rest is sub-quantum / impossible-carry).
    wire _unused = &{ena, uio_in, ui_in[7:4], sc_scaled[7:0],
                     tot_sum[15], tot_sum[7:0], b_sum[7:0], 1'b0};

endmodule

`default_nettype wire
