import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from model import Qubit, LFSR, OP_RST, OP_X, OP_Y, OP_Z, OP_H, OP_S, OP_T, OP_MSR

GL = os.environ.get("GATES") == "yes"   # internals are unreadable in gate-level sim
CORE = "user_project"                   # tt_um_* instance name inside tb.v


def core(dut):
    return getattr(dut, CORE)


def s8(u):
    return u - 256 if u >= 128 else u


def lfsr_before_step(v):
    # Undo one DUT/model Galois-LFSR step:
    # new = (old >> 1) ^ 0x8E when old[0] was 1.
    old_lsb = (v >> 7) & 1
    return (((v ^ (0x8E if old_lsb else 0)) << 1) & 0xFF) | old_lsb


def lfsr_before_steps(v, steps):
    for _ in range(steps):
        v = lfsr_before_step(v)
    return v


def read_state(dut):
    c = core(dut)
    return [s8(int(c.zero_r.value)), s8(int(c.zero_i.value)),
            s8(int(c.one_r.value)), s8(int(c.one_i.value))]


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


async def do_op(dut, opc):                            # 2-phase (transition) handshake
    prev = (int(dut.uo_out.value) >> 1) & 1           # idle: done == current start level
    req = prev ^ 1                                    # toggle start to request
    dut.ui_in.value = (req << 3) | opc
    await RisingEdge(dut.clk)
    while ((int(dut.uo_out.value) >> 1) & 1) != req:  # wait until done matches
        await RisingEdge(dut.clk)
    return int(dut.uo_out.value) & 1                  # msr_res on uo[0]


@cocotb.test(skip=GL)
async def test_lfsr(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="us").start())
    await reset(dut)
    ref = LFSR()
    ref.v = int(core(dut).lfsr.value)   # align to DUT state after reset
    for _ in range(200):
        await RisingEdge(dut.clk)
        ref.step()
        assert int(core(dut).lfsr.value) == ref.v


@cocotb.test(skip=GL)
async def test_gates(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="us").start())
    await reset(dut)
    seqs = [
        [OP_X], [OP_Y], [OP_Z], [OP_H], [OP_S], [OP_T],
        [OP_H, OP_H], [OP_H, OP_Z, OP_H], [OP_H, OP_S, OP_H], [OP_H, OP_T], [OP_H, OP_T, OP_T],
        [OP_X, OP_H], [OP_X, OP_S], [OP_X, OP_T], [OP_X, OP_Y, OP_Z, OP_H, OP_S, OP_T],
    ]
    for seq in seqs:
        await do_op(dut, OP_RST)
        q = Qubit()
        for op in seq:
            await do_op(dut, op)
            q.apply(op)
            assert read_state(dut) == q.s, f"{seq}/{op}: {read_state(dut)} != {q.s}"


@cocotb.test(skip=GL)
async def test_measure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="us").start())
    await reset(dut)
    for prep in [[], [OP_X], [OP_H], [OP_X, OP_H], [OP_H, OP_T], [OP_H, OP_S]]:
        await do_op(dut, OP_RST)
        q = Qubit()
        for op in prep:
            await do_op(dut, op)
            q.apply(op)

        res = await do_op(dut, OP_MSR)

        # The DUT samples lfsr in PH_M_F to compute prod, then completes in
        # PH_M_G on the following clock. Since lfsr advances every clock,
        # its value after completion is two steps after the consumed random value.
        r = lfsr_before_steps(int(core(dut).lfsr.value), 2)

        exp = q.apply(OP_MSR, r)
        assert res == exp, f"{prep}: r={r} res={res} exp={exp}"
        assert read_state(dut) == q.s, f"{prep}: collapse {read_state(dut)} != {q.s}"


@cocotb.test()
async def test_pins(dut):                       # GL-safe: deterministic basis states
    cocotb.start_soon(Clock(dut.clk, 10, units="us").start())
    await reset(dut)
    for prep, exp in [([], 0), ([OP_X], 1), ([OP_X, OP_X], 0), ([OP_Y], 1), ([OP_Z], 0), ([OP_X, OP_Z], 1)]:
        await do_op(dut, OP_RST)
        for op in prep:
            await do_op(dut, op)
        assert await do_op(dut, OP_MSR) == exp, f"{prep}: expected {exp}"
