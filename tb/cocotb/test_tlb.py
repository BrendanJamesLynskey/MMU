# Brendan Lynskey 2025
# CocoTB tests for TLB

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


async def reset(dut):
    dut.srst.value = 1
    dut.lookup_vpn.value = 0
    dut.lookup_asid.value = 0
    dut.write_valid.value = 0
    dut.write_asid.value = 0
    dut.write_vpn.value = 0
    dut.write_ppn.value = 0
    dut.write_d.value = 0
    dut.write_a.value = 0
    dut.write_u.value = 0
    dut.write_x.value = 0
    dut.write_w.value = 0
    dut.write_r.value = 0
    dut.write_g.value = 0
    dut.write_is_megapage.value = 0
    dut.sfence_valid.value = 0
    dut.sfence_vaddr.value = 0
    dut.sfence_asid.value = 0
    await ClockCycles(dut.clk, 3)
    dut.srst.value = 0
    await ClockCycles(dut.clk, 1)


async def insert_entry(dut, asid, vpn, ppn, is_mega=0, g=0):
    await RisingEdge(dut.clk)
    dut.write_valid.value = 1
    dut.write_asid.value = asid
    dut.write_vpn.value = vpn
    dut.write_ppn.value = ppn
    dut.write_r.value = 1
    dut.write_w.value = 1
    dut.write_a.value = 1
    dut.write_d.value = 1
    dut.write_u.value = 1
    dut.write_x.value = 0
    dut.write_g.value = g
    dut.write_is_megapage.value = is_mega
    await RisingEdge(dut.clk)
    dut.write_valid.value = 0


async def do_lookup(dut, asid, vpn):
    dut.lookup_asid.value = asid
    dut.lookup_vpn.value = vpn
    await Timer(1, units="ns")


async def do_sfence(dut, vaddr=0, asid=0):
    dut.sfence_valid.value = 1
    dut.sfence_vaddr.value = vaddr
    dut.sfence_asid.value = asid
    await RisingEdge(dut.clk)
    dut.sfence_valid.value = 0
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_empty_miss(dut):
    """Lookup on empty TLB should miss."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await do_lookup(dut, 1, 0xABCDE)
    assert dut.lookup_hit.value == 0, "Expected miss on empty TLB"


@cocotb.test()
async def test_insert_and_hit(dut):
    """Insert entry then lookup should hit with correct PPN."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await insert_entry(dut, 1, 0x12345, 0x3ABCD)
    await ClockCycles(dut.clk, 1)
    await do_lookup(dut, 1, 0x12345)
    assert dut.lookup_hit.value == 1, "Expected hit"
    assert dut.lookup_ppn.value == 0x3ABCD, f"Expected PPN=0x3ABCD, got {hex(dut.lookup_ppn.value)}"


@cocotb.test()
async def test_miss_wrong_vpn(dut):
    """Lookup with wrong VPN should miss."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await insert_entry(dut, 1, 0x12345, 0x3ABCD)
    await ClockCycles(dut.clk, 1)
    await do_lookup(dut, 1, 0x12346)
    assert dut.lookup_hit.value == 0, "Expected miss on wrong VPN"


@cocotb.test()
async def test_miss_wrong_asid(dut):
    """Lookup with wrong ASID should miss."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await insert_entry(dut, 1, 0x12345, 0x3ABCD)
    await ClockCycles(dut.clk, 1)
    await do_lookup(dut, 2, 0x12345)
    assert dut.lookup_hit.value == 0, "Expected miss on wrong ASID"


@cocotb.test()
async def test_asid_isolation(dut):
    """Same VPN with different ASIDs should map to different PPNs."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await insert_entry(dut, 1, 0x12345, 0x11111)
    await insert_entry(dut, 2, 0x12345, 0x22222)
    await ClockCycles(dut.clk, 1)
    await do_lookup(dut, 1, 0x12345)
    assert dut.lookup_hit.value == 1
    assert dut.lookup_ppn.value == 0x11111
    await do_lookup(dut, 2, 0x12345)
    assert dut.lookup_hit.value == 1
    assert dut.lookup_ppn.value == 0x22222


@cocotb.test()
async def test_megapage_hit(dut):
    """Megapage should match on VPN[1] only, ignoring VPN[0]."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    # Megapage with VPN[1]=0x2A8 (VPN = {0x2A8, 0x000})
    await insert_entry(dut, 1, (0x2A8 << 10) | 0x000, 0x2AA00, is_mega=1)
    await ClockCycles(dut.clk, 1)
    # Lookup with same VPN[1] but different VPN[0]
    await do_lookup(dut, 1, (0x2A8 << 10) | 0x123)
    assert dut.lookup_hit.value == 1, "Expected megapage hit"
    await do_lookup(dut, 1, (0x2A8 << 10) | 0x3FF)
    assert dut.lookup_hit.value == 1, "Expected megapage hit with different VPN[0]"


@cocotb.test()
async def test_sfence_flush_all(dut):
    """SFENCE with vaddr=0, asid=0 should flush all entries."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await insert_entry(dut, 1, 0xAAAAA, 0x11111)
    await insert_entry(dut, 2, 0xBBBBB, 0x22222)
    await ClockCycles(dut.clk, 1)
    await do_sfence(dut)
    await do_lookup(dut, 1, 0xAAAAA)
    assert dut.lookup_hit.value == 0, "Expected miss after flush all"
    await do_lookup(dut, 2, 0xBBBBB)
    assert dut.lookup_hit.value == 0, "Expected miss after flush all"


@cocotb.test()
async def test_sfence_flush_by_asid(dut):
    """SFENCE by ASID should flush matching entries only."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await insert_entry(dut, 1, 0xAAAAA, 0x11111)
    await insert_entry(dut, 2, 0xBBBBB, 0x22222)
    await ClockCycles(dut.clk, 1)
    await do_sfence(dut, vaddr=0, asid=1)
    await do_lookup(dut, 1, 0xAAAAA)
    assert dut.lookup_hit.value == 0, "Expected miss for flushed ASID"
    await do_lookup(dut, 2, 0xBBBBB)
    assert dut.lookup_hit.value == 1, "Expected hit for preserved ASID"


@cocotb.test()
async def test_global_page(dut):
    """Global page should match any ASID."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    await insert_entry(dut, 5, 0xEEEEE, 0x0EEEE, g=1)
    await ClockCycles(dut.clk, 1)
    await do_lookup(dut, 5, 0xEEEEE)
    assert dut.lookup_hit.value == 1, "Expected hit with matching ASID"
    await do_lookup(dut, 99, 0xEEEEE)
    assert dut.lookup_hit.value == 1, "Expected hit with different ASID (global)"
