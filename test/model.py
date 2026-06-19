import math
 
# opcodes (ui[2:0])
OP_RST, OP_X, OP_Y, OP_Z, OP_H, OP_S, OP_T, OP_MSR = range(8)
 
QMAX = 127            # SNORM: x in [-1,1] stored as clamp(round(127*x), -127, 127)
RAND_BITS = 8         # width of the random value consumed per measurement
 
ISQRT2_SH = 8
ISQRT2_K = round((1 << ISQRT2_SH) / math.sqrt(2))   # 181 ~= 2^8 / sqrt(2)
 
 
def clamp(v):
    return max(-QMAX, min(QMAX, v))
 
 
def mul_isqrt2(v):    # round(v / sqrt(2)); Verilog: signed (v*K + 2^7) >>> 8
    return (v * ISQRT2_K + (1 << (ISQRT2_SH - 1))) >> ISQRT2_SH
 
 
class LFSR:           # 8-bit Galois LFSR, poly 0xB8, maximal length (period 255)
    def __init__(self, seed=1):
        self.v = seed & 0xFF
 
    def step(self):
        lsb = self.v & 1
        self.v >>= 1
        if lsb:
            self.v ^= 0x8E
        return self.v
 
 
class Qubit:          # state = [a_re, a_im, b_re, b_im], each an SNORM int
    def __init__(self):
        self.s = [QMAX, 0, 0, 0]
 
    def apply(self, op, r=0):
        ar, ai, br, bi = self.s
        if op == OP_RST:
            self.s = [QMAX, 0, 0, 0]
        elif op == OP_X:                       # swap a,b
            self.s = [br, bi, ar, ai]
        elif op == OP_Y:                       # a,b -> -i*b, i*a
            self.s = [bi, -br, -ai, ar]
        elif op == OP_Z:                       # b -> -b
            self.s = [ar, ai, -br, -bi]
        elif op == OP_S:                       # b -> i*b
            self.s = [ar, ai, -bi, br]
        elif op == OP_H:                       # (a+b)/sqrt2, (a-b)/sqrt2
            self.s = [clamp(mul_isqrt2(ar + br)), clamp(mul_isqrt2(ai + bi)),
                      clamp(mul_isqrt2(ar - br)), clamp(mul_isqrt2(ai - bi))]
        elif op == OP_T:                       # b -> (1+i)/sqrt2 * b
            self.s = [ar, ai,
                      clamp(mul_isqrt2(br - bi)), clamp(mul_isqrt2(br + bi))]
        elif op == OP_MSR:
            a_norm = ar * ar + ai * ai
            b_norm = br * br + bi * bi
            tot = a_norm + b_norm
            # r is only 8 bits, so the top byte of the norms is enough resolution
            one = (r * (tot >> 8)) < ((b_norm >> 8) << RAND_BITS)
            self.s = [0, 0, QMAX, 0] if one else [QMAX, 0, 0, 0]
            return int(one)
