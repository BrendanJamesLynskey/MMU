# MMU Technical Report — Sv32 Memory Management Unit

Brendan Lynskey 2025

## 1. Introduction

This report documents the design and verification of a synthesisable Sv32 Memory Management Unit (MMU) implemented in SystemVerilog. The MMU performs virtual-to-physical address translation compatible with the RISC-V Privileged Specification, supporting two-level page table walks, TLB caching, permission checking, and SFENCE.VMA invalidation.

## 2. Sv32 Page Table Format

The Sv32 format uses a two-level page table with 4 KiB pages and 4 MiB megapages. A 32-bit virtual address is divided into:

| Field | Bits | Width | Description |
|-------|------|-------|-------------|
| VPN[1] | 31:22 | 10 | Level-1 page table index |
| VPN[0] | 21:12 | 10 | Level-0 page table index |
| Offset | 11:0 | 12 | Byte offset within page |

Each Page Table Entry (PTE) is 32 bits:

| Field | Bits | Description |
|-------|------|-------------|
| PPN | 31:10 | Physical Page Number (22 bits) |
| RSW | 9:8 | Reserved for software |
| D | 7 | Dirty |
| A | 6 | Accessed |
| G | 5 | Global |
| U | 4 | User-mode accessible |
| X | 3 | Execute permission |
| W | 2 | Write permission |
| R | 1 | Read permission |
| V | 0 | Valid |

## 3. TLB Design

### 3.1 Organisation

The TLB is fully associative with a parameterised entry count (default 16). Each entry stores:

- Valid bit
- 9-bit ASID (Address Space Identifier)
- 20-bit VPN
- 22-bit PPN
- Permission bits (D, A, U, X, W, R, G)
- Megapage flag

### 3.2 Lookup

Lookup is combinational (single-cycle). For each valid entry, the TLB checks:

1. **ASID match**: Global pages (G=1) match any ASID; non-global pages require exact ASID match
2. **VPN match**: Normal pages match full VPN[19:0]; megapages match only VPN[1] (bits 19:10)

Match signals are generated using `generate` blocks to avoid local variable declarations inside `always_comb` (an iverilog compatibility consideration).

### 3.3 Replacement Policy

The LRU tracker implements true LRU using an NxN bit matrix. For entry pair (i,j), `matrix[i][j] = 1` means entry i was accessed more recently than j.

On access to entry k:
- Set row k to all 1s (k beats everyone)
- Set column k to all 0s (everyone else loses to k)

The LRU victim is the entry whose row is all zeros (lost every pairwise comparison).

### 3.4 SFENCE.VMA Support

The TLB supports four flush modes:

| vaddr | asid | Action |
|-------|------|--------|
| 0 | 0 | Flush all entries |
| ≠0 | 0 | Flush entries matching VPN |
| 0 | ≠0 | Flush entries matching ASID (except global) |
| ≠0 | ≠0 | Flush entries matching both VPN and ASID |

## 4. Page Table Walker FSM

The PTW implements an 8-state FSM:

```
IDLE → L1_REQ → L1_WAIT → L1_CHECK → L0_REQ → L0_WAIT → L0_CHECK → DONE
                              │                                        ↑
                              └── (megapage leaf) ─────────────────────┘
                              └── (fault) ─────────────────────────────┘
```

### 4.1 Address Calculation

- **L1**: `pte_addr = satp.PPN × 4096 + VPN[1] × 4`
- **L0**: `pte_addr = L1_PTE.PPN × 4096 + VPN[0] × 4`

### 4.2 PTE Validity Checks

At each level, the PTW checks:

1. V bit must be set
2. Reserved encoding (W=1, R=0) is invalid
3. Megapage alignment: if leaf at L1, PPN[9:0] must be zero

### 4.3 Memory Interface

The PTW uses a valid/ready handshake for requests and a valid signal for responses. It supports both single-cycle and multi-cycle memory latencies.

## 5. Permission Checking

The permission checker is purely combinational, implementing RISC-V Privileged Spec §4.3.1:

1. **PTE validity**: V must be set; (W=1, R=0) is reserved
2. **Accessed bit**: A must be set
3. **Privilege mode**:
   - User mode: U bit must be set
   - Supervisor mode: if U=1 and SUM=0, fault
4. **Access type**:
   - Load: requires R (or X if MXR=1)
   - Store: requires W and D
   - Execute: requires X

## 6. Top-Level FSM

The MMU top coordinates all submodules through a 5-state FSM:

```
IDLE → TLB_LOOKUP → PTW_ACTIVE → PTW_DONE → PERM_CHECK
  │         │
  │         └── (TLB hit) → permission check → respond
  └── (bare mode) → passthrough respond
```

### 6.1 Bare Mode

When `satp.MODE = 0` (Bare), the MMU passes the virtual address through as the physical address with no translation. This is a single-cycle combinational path.

### 6.2 Translation Flow

1. **IDLE**: Accept CPU request; latch vaddr, access_type, priv_mode
2. **TLB_LOOKUP**: Combinational TLB lookup. Hit → permission check → respond. Miss → start PTW.
3. **PTW_ACTIVE**: Wait for PTW to complete. On done, register results.
4. **PTW_DONE**: Write TLB entry with registered PTW results. If PTW reported a fault, respond with fault.
5. **PERM_CHECK**: Permission check using registered PTW values. Respond with translated address or fault.

The separation of PTW_DONE and PERM_CHECK states was chosen to avoid combinational feedback loops between the PTW outputs, TLB write path, and permission checker — which caused infinite event loops in iverilog's event-driven simulation.

## 7. Timing Considerations

| Operation | Cycles |
|-----------|--------|
| Bare mode passthrough | 1 (combinational) |
| TLB hit | 2 (IDLE → TLB_LOOKUP → respond) |
| TLB miss (2-level walk, single-cycle memory) | ~10 (IDLE → TLB_LOOKUP → PTW walk → PTW_DONE → PERM_CHECK) |
| TLB miss (megapage) | ~7 (shorter PTW walk) |
| Page fault | Same as miss path |

## 8. Verification Summary

### 8.1 SystemVerilog Testbenches

| Module | Tests | Coverage |
|--------|-------|----------|
| lru_tracker | 10 | Sequential access, re-access promotion, reset, complex patterns |
| permission_checker | 20 | All access types × privilege modes, SUM, MXR, reserved encodings |
| tlb | 17 | Hit/miss, ASID isolation, megapage, eviction, SFENCE modes, global pages |
| page_table_walker | 11 | 2-level walk, megapage, invalid PTEs at L1/L0, misalignment, reserved encoding |
| mmu_top | 22 | Bare mode, PTW fill, TLB hit, store/load/execute, faults, SFENCE, SUM, MXR, ASID |
| **Total** | **80** | |

### 8.2 CocoTB Testbenches

| Module | Tests |
|--------|-------|
| lru_tracker | 7 |
| permission_checker | 16 |
| tlb | 9 |
| page_table_walker | 8 |
| mmu_top | 11 |
| **Total** | **51** |

## 9. Area and Performance Considerations

The design prioritises correctness and clarity over area optimisation:

- **TLB storage**: 16 entries × ~58 bits = ~928 bits of entry storage plus 256 bits of LRU matrix
- **PTW**: Single outstanding memory request; no pipelining
- **Permission checker**: Purely combinational; minimal gate count

For area-constrained implementations, the LRU matrix could be replaced with pseudo-LRU (tree-based), and TLB depth could be reduced to 4-8 entries.

## 10. Known Limitations

- Physical address output is 32 bits (not the full 34 bits of Sv32)
- No Dirty/Accessed bit writeback to page table memory
- No PMP/PMA checking
- Single ASID width (9 bits) — no ASID extension
- PTW does not cache intermediate page table entries
