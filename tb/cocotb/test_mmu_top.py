# Brendan Lynskey 2025
# CocoTB tests for MMU Top-Level Integration

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


def make_pte(ppn, d=0, a=0, g=0, u=0, x=0, w=0, r=0, v=0):
    return (ppn << 10) | (d << 7) | (a << 6) | (g << 5) | (u << 4) | (x << 3) | (w << 2) | (r << 1) | v


class MemoryModel:
    def __init__(self):
        self.mem = {}

    def write(self, addr, data):
        self.mem[addr] = data

    def read(self, addr):
        return self.mem.get(addr, 0)


async def mem_responder(dut, mem_model):
    while True:
        await RisingEdge(dut.clk)
        dut.mem_req_ready.value = 1
        dut.mem_resp_valid.value = 0
        if dut.mem_req_valid.value == 1:
            addr = int(dut.mem_req_addr.value)
            data = mem_model.read(addr)
            dut.mem_resp_valid.value = 1
            dut.mem_resp_data.value = data


SATP_SV32 = (1 << 31) | (1 << 22) | 0x00010  # MODE=1, ASID=1, PPN=0x10
SATP_BARE = 0


def setup_page_tables(mem):
    """Standard page table setup for integration tests."""
    # L1[1] -> non-leaf -> L0 at PPN=0x20
    mem.write(0x10004, make_pte(0x00020, v=1))
    # L0[2] -> leaf, PPN=0x30, RWX, U=1, A+D
    mem.write(0x20008, make_pte(0x00030, d=1, a=1, u=1, x=1, w=1, r=1, v=1))
    # L0[3] -> leaf, PPN=0x31, R only, U=1, A
    mem.write(0x2000C, make_pte(0x00031, a=1, u=1, r=1, v=1))

    # L1[2] -> megapage leaf, PPN=0x3FC00 (aligned), RX, U=1, A+D
    mem.write(0x10008, make_pte(0x3FC00, d=1, a=1, u=1, x=1, r=1, v=1))

    # L1[3] -> non-leaf -> L0 at PPN=0x21
    mem.write(0x1000C, make_pte(0x00021, v=1))
    # L0[0] at PPN=0x21 -> leaf, PPN=0x40, U=0 (supervisor), RW, A+D
    mem.write(0x21000, make_pte(0x00040, d=1, a=1, w=1, r=1, v=1))

    # L1[4] -> invalid (V=0)
    mem.write(0x10010, make_pte(0x00050, v=0))


async def reset_dut(dut, satp=SATP_SV32):
    dut.srst.value = 1
    dut.req_valid.value = 0
    dut.vaddr.value = 0
    dut.access_type.value = 0
    dut.priv_mode.value = 0
    dut.satp.value = satp
    dut.sfence_valid.value = 0
    dut.sfence_vaddr.value = 0
    dut.sfence_asid.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    dut.mem_req_ready.value = 1
    dut.mem_resp_valid.value = 0
    dut.mem_resp_data.value = 0
    await ClockCycles(dut.clk, 3)
    dut.srst.value = 0
    await ClockCycles(dut.clk, 2)


async def do_translate(dut, vaddr, access_type=0, priv=0, timeout=100):
    """Send request and wait for response. Keeps req_valid high until response."""
    await RisingEdge(dut.clk)
    dut.req_valid.value = 1
    dut.vaddr.value = vaddr
    dut.access_type.value = access_type
    dut.priv_mode.value = priv

    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.resp_valid.value == 1:
            pa = int(dut.paddr.value)
            pf = int(dut.page_fault.value)
            ft = int(dut.fault_type.value)
            dut.req_valid.value = 0
            return pa, pf, ft

    dut.req_valid.value = 0
    raise TimeoutError("No response from MMU")


async def sfence_all(dut):
    await RisingEdge(dut.clk)
    dut.sfence_valid.value = 1
    dut.sfence_vaddr.value = 0
    dut.sfence_asid.value = 0
    await RisingEdge(dut.clk)
    dut.sfence_valid.value = 0
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_bare_mode_passthrough(dut):
    """Bare mode should pass virtual address through unchanged."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut, satp=SATP_BARE)

    pa, pf, _ = await do_translate(dut, 0xDEADBEEF)
    assert pf == 0, "Expected no fault"
    assert pa == 0xDEADBEEF, f"Expected PA=0xDEADBEEF, got {hex(pa)}"


@cocotb.test()
async def test_tlb_miss_ptw_translate(dut):
    """TLB miss should trigger PTW and produce correct translation."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (1 << 22) | (2 << 12) | 0x345
    pa, pf, _ = await do_translate(dut, vaddr, access_type=0, priv=0)
    assert pf == 0, "Expected no fault"
    expected_pa = (0x30 << 12) | 0x345
    assert pa == expected_pa, f"Expected PA={hex(expected_pa)}, got {hex(pa)}"


@cocotb.test()
async def test_tlb_hit_after_fill(dut):
    """Second access to same page should hit TLB (faster)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr1 = (1 << 22) | (2 << 12) | 0x345
    await do_translate(dut, vaddr1, access_type=0, priv=0)
    await ClockCycles(dut.clk, 2)

    vaddr2 = (1 << 22) | (2 << 12) | 0x678
    pa, pf, _ = await do_translate(dut, vaddr2, access_type=0, priv=0)
    assert pf == 0
    expected_pa = (0x30 << 12) | 0x678
    assert pa == expected_pa


@cocotb.test()
async def test_user_store(dut):
    """User store on RWX page with D=1 should succeed."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (1 << 22) | (2 << 12) | 0
    _, pf, _ = await do_translate(dut, vaddr, access_type=1, priv=0)
    assert pf == 0, "Expected no fault for user store on RWX page"


@cocotb.test()
async def test_page_fault_invalid_pte(dut):
    """Access to page with invalid L1 PTE should fault."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (4 << 22) | 0
    _, pf, _ = await do_translate(dut, vaddr, access_type=0, priv=0)
    assert pf == 1, "Expected fault for invalid PTE"


@cocotb.test()
async def test_load_fault_type(dut):
    """Load on invalid page should produce FAULT_LOAD."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (4 << 22) | 0
    _, pf, ft = await do_translate(dut, vaddr, access_type=0, priv=0)
    assert pf == 1
    assert ft == 0b01, f"Expected FAULT_LOAD=01, got {bin(ft)}"


@cocotb.test()
async def test_store_fault_type(dut):
    """Store on invalid page should produce FAULT_STORE."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (4 << 22) | 0
    _, pf, ft = await do_translate(dut, vaddr, access_type=1, priv=0)
    assert pf == 1
    assert ft == 0b10, f"Expected FAULT_STORE=10, got {bin(ft)}"


@cocotb.test()
async def test_permission_fault_store_readonly(dut):
    """Store to read-only page should fault."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (1 << 22) | (3 << 12) | 0  # R-only page
    _, pf, _ = await do_translate(dut, vaddr, access_type=1, priv=0)
    assert pf == 1, "Expected fault for store to R-only page"


@cocotb.test()
async def test_sfence_invalidation_rewalk(dut):
    """After SFENCE, accessing same page should re-walk."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (1 << 22) | (2 << 12) | 0xAAA
    await do_translate(dut, vaddr, access_type=0, priv=0)
    await ClockCycles(dut.clk, 2)
    await sfence_all(dut)

    vaddr2 = (1 << 22) | (2 << 12) | 0xBBB
    pa, pf, _ = await do_translate(dut, vaddr2, access_type=0, priv=0)
    assert pf == 0
    expected = (0x30 << 12) | 0xBBB
    assert pa == expected


@cocotb.test()
async def test_user_supervisor_page_fault(dut):
    """User accessing supervisor (U=0) page should fault."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (3 << 22) | 0
    _, pf, _ = await do_translate(dut, vaddr, access_type=0, priv=0)
    assert pf == 1, "Expected fault for user on supervisor page"


@cocotb.test()
async def test_supervisor_access_supervisor_page(dut):
    """Supervisor accessing supervisor (U=0) page should succeed."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    mem = MemoryModel()
    setup_page_tables(mem)
    cocotb.start_soon(mem_responder(dut, mem))
    await reset_dut(dut)

    vaddr = (3 << 22) | 0x100
    pa, pf, _ = await do_translate(dut, vaddr, access_type=0, priv=1)
    assert pf == 0
    expected = (0x40 << 12) | 0x100
    assert pa == expected, f"Expected PA={hex(expected)}, got {hex(pa)}"
