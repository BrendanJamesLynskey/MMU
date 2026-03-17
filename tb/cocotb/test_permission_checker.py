# Brendan Lynskey 2025
# CocoTB tests for Permission Checker

import cocotb
from cocotb.triggers import Timer


def set_pte(dut, v, r, w, x, u, a, d):
    dut.pte_v.value = v
    dut.pte_r.value = r
    dut.pte_w.value = w
    dut.pte_x.value = x
    dut.pte_u.value = u
    dut.pte_a.value = a
    dut.pte_d.value = d


async def settle(dut):
    await Timer(1, units="ns")


@cocotb.test()
async def test_user_load_valid(dut):
    """User load on a readable page should not fault."""
    set_pte(dut, 1, 1, 0, 0, 1, 1, 0)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 0, "Expected no fault"


@cocotb.test()
async def test_user_store_valid(dut):
    """User store on RW page with D bit should not fault."""
    set_pte(dut, 1, 1, 1, 0, 1, 1, 1)
    dut.access_type.value = 0b01
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 0, "Expected no fault"


@cocotb.test()
async def test_user_execute_valid(dut):
    """User execute on X page should not fault."""
    set_pte(dut, 1, 0, 0, 1, 1, 1, 0)
    dut.access_type.value = 0b10
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 0, "Expected no fault"


@cocotb.test()
async def test_invalid_pte(dut):
    """V=0 should always fault."""
    set_pte(dut, 0, 1, 1, 1, 1, 1, 1)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for V=0"


@cocotb.test()
async def test_reserved_wr_encoding(dut):
    """W=1, R=0 is a reserved encoding and should fault."""
    set_pte(dut, 1, 0, 1, 0, 1, 1, 1)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for W=1 R=0"


@cocotb.test()
async def test_accessed_bit_required(dut):
    """A=0 should fault."""
    set_pte(dut, 1, 1, 0, 0, 1, 0, 0)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for A=0"


@cocotb.test()
async def test_user_on_supervisor_page(dut):
    """User accessing U=0 page should fault."""
    set_pte(dut, 1, 1, 0, 0, 0, 1, 0)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for user on S-mode page"


@cocotb.test()
async def test_supervisor_on_user_page_no_sum(dut):
    """Supervisor accessing U=1 page without SUM should fault."""
    set_pte(dut, 1, 1, 0, 0, 1, 1, 0)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 1
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for supervisor on U-page without SUM"


@cocotb.test()
async def test_supervisor_on_user_page_with_sum(dut):
    """Supervisor accessing U=1 page with SUM=1 should not fault."""
    set_pte(dut, 1, 1, 0, 0, 1, 1, 0)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 1
    dut.mxr.value = 0
    dut.sum.value = 1
    await settle(dut)
    assert dut.fault.value == 0, "Expected no fault with SUM=1"


@cocotb.test()
async def test_store_without_write(dut):
    """Store without W bit should fault."""
    set_pte(dut, 1, 1, 0, 0, 1, 1, 0)
    dut.access_type.value = 0b01
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for store without W"


@cocotb.test()
async def test_store_without_dirty(dut):
    """Store with W but without D bit should fault."""
    set_pte(dut, 1, 1, 1, 0, 1, 1, 0)
    dut.access_type.value = 0b01
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for store with D=0"


@cocotb.test()
async def test_execute_without_x(dut):
    """Execute without X bit should fault."""
    set_pte(dut, 1, 1, 1, 0, 1, 1, 1)
    dut.access_type.value = 0b10
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1, "Expected fault for execute without X"


@cocotb.test()
async def test_mxr_load_x_page(dut):
    """Load on X-only page with MXR=1 should not fault."""
    set_pte(dut, 1, 0, 0, 1, 1, 1, 0)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 0
    dut.mxr.value = 1
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 0, "Expected no fault with MXR=1 on X page"


@cocotb.test()
async def test_load_fault_type(dut):
    """Fault type should be LOAD (01) for load access."""
    set_pte(dut, 0, 0, 0, 0, 0, 0, 0)
    dut.access_type.value = 0b00
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1
    assert dut.fault_type.value == 0b01, f"Expected FAULT_LOAD=01, got {dut.fault_type.value}"


@cocotb.test()
async def test_store_fault_type(dut):
    """Fault type should be STORE (10) for store access."""
    set_pte(dut, 0, 0, 0, 0, 0, 0, 0)
    dut.access_type.value = 0b01
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1
    assert dut.fault_type.value == 0b10, f"Expected FAULT_STORE=10, got {dut.fault_type.value}"


@cocotb.test()
async def test_instruction_fault_type(dut):
    """Fault type should be INSTRUCTION (00) for execute access."""
    set_pte(dut, 0, 0, 0, 0, 0, 0, 0)
    dut.access_type.value = 0b10
    dut.priv_mode.value = 0
    dut.mxr.value = 0
    dut.sum.value = 0
    await settle(dut)
    assert dut.fault.value == 1
    assert dut.fault_type.value == 0b00, f"Expected FAULT_INSTRUCTION=00, got {dut.fault_type.value}"
