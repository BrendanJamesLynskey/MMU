# Brendan Lynskey 2025
# CocoTB tests for LRU Tracker

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


async def reset(dut):
    dut.srst.value = 1
    dut.access_valid.value = 0
    dut.access_idx.value = 0
    await ClockCycles(dut.clk, 3)
    dut.srst.value = 0
    await ClockCycles(dut.clk, 1)


async def access_entry(dut, idx):
    dut.access_valid.value = 1
    dut.access_idx.value = idx
    await RisingEdge(dut.clk)
    dut.access_valid.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_lru_after_reset(dut):
    """After reset, LRU should be entry 0."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    assert int(dut.lru_idx.value) == 0, f"Expected LRU=0 after reset, got {int(dut.lru_idx.value)}"


@cocotb.test()
async def test_sequential_access(dut):
    """Accessing entries 0,1,2,3 in order should make 0 the LRU."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    for i in range(4):
        await access_entry(dut, i)
    assert int(dut.lru_idx.value) == 0, f"Expected LRU=0, got {int(dut.lru_idx.value)}"


@cocotb.test()
async def test_reaccess_promotes(dut):
    """Re-accessing an entry should promote it from LRU."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    for i in range(4):
        await access_entry(dut, i)
    await access_entry(dut, 0)
    assert int(dut.lru_idx.value) == 1, f"Expected LRU=1 after promoting 0, got {int(dut.lru_idx.value)}"


@cocotb.test()
async def test_reverse_access(dut):
    """Accessing in reverse order 3,2,1,0 should make 3 the LRU."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    for i in [3, 2, 1, 0]:
        await access_entry(dut, i)
    assert int(dut.lru_idx.value) == 3, f"Expected LRU=3, got {int(dut.lru_idx.value)}"


@cocotb.test()
async def test_single_access(dut):
    """After accessing only entry 0, LRU should be entry 1."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await access_entry(dut, 0)
    assert int(dut.lru_idx.value) == 1, f"Expected LRU=1, got {int(dut.lru_idx.value)}"


@cocotb.test()
async def test_complex_pattern(dut):
    """Complex access pattern: 0,1,2,3,2 should make 0 the LRU."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    for i in [0, 1, 2, 3, 2]:
        await access_entry(dut, i)
    assert int(dut.lru_idx.value) == 0, f"Expected LRU=0, got {int(dut.lru_idx.value)}"


@cocotb.test()
async def test_reset_clears_state(dut):
    """Reset should clear LRU state back to entry 0."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    for i in range(4):
        await access_entry(dut, i)
    await reset(dut)
    assert int(dut.lru_idx.value) == 0, f"Expected LRU=0 after re-reset, got {int(dut.lru_idx.value)}"
