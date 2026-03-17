# Brendan Lynskey 2025
# CocoTB tests for Page Table Walker

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


def make_pte(ppn, d=0, a=0, g=0, u=0, x=0, w=0, r=0, v=0):
    return (ppn << 10) | (d << 7) | (a << 6) | (g << 5) | (u << 4) | (x << 3) | (w << 2) | (r << 1) | v


class MemoryModel:
    """Simple memory model responding to PTW memory requests."""

    def __init__(self):
        self.mem = {}

    def write(self, addr, data):
        self.mem[addr] = data

    def read(self, addr):
        return self.mem.get(addr, 0)


async def mem_responder(dut, mem_model):
    """Background task: respond to memory requests."""
    while True:
        await RisingEdge(dut.clk)
        dut.mem_req_ready.value = 1
        dut.mem_resp_valid.value = 0
        if dut.mem_req_valid.value == 1:
            addr = int(dut.mem_req_addr.value)
            data = mem_model.read(addr)
            dut.mem_resp_valid.value = 1
            dut.mem_resp_data.value = data


async def reset(dut):
    dut.srst.value = 1
    dut.start.value = 0
    dut.vaddr.value = 0
    dut.satp.value = 0
    dut.mem_req_ready.value = 1
    dut.mem_resp_valid.value = 0
    dut.mem_resp_data.value = 0
    await ClockCycles(dut.clk, 3)
    dut.srst.value = 0
    await ClockCycles(dut.clk, 2)


async def start_walk(dut, vaddr, satp):
    dut.vaddr.value = vaddr
    dut.satp.value = satp
    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0


async def wait_done(dut, timeout=50):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            return
    raise TimeoutError("PTW did not complete")


# Root PT at PPN=0x10 (base addr=0x10000)
SATP = (1 << 31) | 0x00010  # MODE=Sv32, PPN=0x10


def setup_2level_pt(mem):
    """Set up a basic 2-level page table for testing."""
    # L1 PTE[1] -> non-leaf, points to L0 at PPN=0x20
    mem.write(0x10004, make_pte(0x00020, v=1))
    # L0 PTE[2] -> leaf, PPN=0x30, RWX, U, A, D
    mem.write(0x20008, make_pte(0x00030, d=1, a=1, u=1, w=1, r=1, v=1))


@cocotb.test()
async def test_successful_2level_walk(dut):
    """Successful 2-level page table walk."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)
    setup_2level_pt(mem)

    vaddr = (1 << 22) | (2 << 12) | 0x345  # VPN1=1, VPN0=2, offset=0x345
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 0, "Expected no fault"
    assert int(dut.result_ppn.value) == 0x00030, f"Expected PPN=0x30, got {hex(int(dut.result_ppn.value))}"
    assert dut.result_is_megapage.value == 0, "Expected not megapage"


@cocotb.test()
async def test_megapage_leaf_at_l1(dut):
    """Megapage leaf at L1 level."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)

    # L1 PTE[2] -> leaf megapage, PPN=0x3FC00 (aligned)
    mem.write(0x10008, make_pte(0x3FC00, d=1, a=1, u=1, r=1, v=1))

    vaddr = (2 << 22) | (0x123 << 12) | 0x456
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 0, "Expected no fault"
    assert dut.result_is_megapage.value == 1, "Expected megapage"
    assert int(dut.result_ppn.value) == 0x3FC00


@cocotb.test()
async def test_invalid_pte_l1(dut):
    """Invalid PTE (V=0) at L1 should fault."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)

    # L1 PTE[3] -> V=0
    mem.write(0x1000C, make_pte(0x00040, v=0))

    vaddr = (3 << 22) | (0 << 12) | 0
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 1, "Expected fault for V=0"


@cocotb.test()
async def test_invalid_pte_l0(dut):
    """Invalid PTE (V=0) at L0 should fault."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)

    # L1 PTE[4] -> non-leaf, PPN=0x21
    mem.write(0x10010, make_pte(0x00021, v=1))
    # L0 PTE[5] at PPN=0x21 -> V=0
    mem.write(0x21014, make_pte(0x00050, v=0))

    vaddr = (4 << 22) | (5 << 12) | 0
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 1, "Expected fault for V=0 at L0"


@cocotb.test()
async def test_reserved_encoding_l1(dut):
    """Reserved W=1, R=0 encoding at L1 should fault."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)

    # L1 PTE[5] -> W=1, R=0
    mem.write(0x10014, make_pte(0x00060, d=1, a=1, w=1, r=0, v=1))

    vaddr = (5 << 22) | 0
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 1, "Expected fault for reserved W=1 R=0"


@cocotb.test()
async def test_misaligned_megapage(dut):
    """Misaligned megapage (PPN[9:0] != 0) should fault."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)

    # L1 PTE[6] -> leaf with PPN[0] != 0
    mem.write(0x10018, make_pte(0x3FC01, d=1, a=1, u=1, r=1, v=1))

    vaddr = (6 << 22) | 0
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 1, "Expected fault for misaligned megapage"


@cocotb.test()
async def test_l0_non_leaf(dut):
    """Non-leaf PTE at L0 should fault (no more levels in Sv32)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)

    # L1 PTE[7] -> non-leaf -> PPN=0x22
    mem.write(0x1001C, make_pte(0x00022, v=1))
    # L0 PTE[0] at PPN=0x22 -> non-leaf (no R/W/X)
    mem.write(0x22000, make_pte(0x00070, v=1))

    vaddr = (7 << 22) | 0
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 1, "Expected fault for L0 non-leaf"


@cocotb.test()
async def test_permission_bits_forwarded(dut):
    """PTW should forward PTE permission bits correctly."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset(dut)

    # L1 PTE[8] -> non-leaf -> PPN=0x23
    mem.write(0x10020, make_pte(0x00023, v=1))
    # L0 PTE[0] at PPN=0x23 -> leaf with specific permissions
    mem.write(0x23000, make_pte(0x00FFF, a=1, g=1, x=1, r=1, v=1))

    vaddr = (8 << 22) | 0
    await start_walk(dut, vaddr, SATP)
    await wait_done(dut)
    assert dut.fault.value == 0
    assert dut.result_r.value == 1
    assert dut.result_w.value == 0
    assert dut.result_x.value == 1
    assert dut.result_g.value == 1
    assert dut.result_a.value == 1
    assert dut.result_d.value == 0
