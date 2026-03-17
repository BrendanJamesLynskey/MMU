# MMU — Memory Management Unit (Sv32)

Synthesisable SystemVerilog implementation of an Sv32 Memory Management Unit for RISC-V processors. Features a fully-associative TLB with true LRU replacement, a hardware page table walker, permission checking per the RISC-V Privileged Specification, and SFENCE.VMA support.

Brendan Lynskey 2025

## What Is a Memory Management Unit?

A Memory Management Unit is a hardware block that sits between a processor core and main memory, translating the virtual addresses that software uses into the physical addresses that the memory system understands. Every time a program accesses memory — fetching an instruction, loading a variable, writing to the stack — the MMU intercepts the address before it reaches the bus.

Without an MMU, every process would share a single flat address space. Any program could read or overwrite any other program's data, or corrupt the operating system itself. The MMU makes modern multitasking possible by giving each process the illusion of its own private address space while the OS controls which physical pages back each virtual mapping.

### Core Operations

**Address translation** is the primary job. The MMU takes a virtual address, splits it into a virtual page number and a page offset, looks up the corresponding physical page number in a page table, and concatenates it with the offset to produce a physical address. In Sv32 (the scheme implemented here), this involves walking a two-level radix tree stored in main memory — the page table walker reads a level-1 entry to find the level-0 table, then reads a level-0 entry to find the final physical page.

**TLB caching** makes translation fast. A page table walk requires multiple memory reads, which would be catastrophic if every instruction fetch or data access had to pay that cost. The Translation Lookaside Buffer caches recent translations so that hits (typically 95-99% of accesses) resolve in a single cycle. A TLB miss triggers the hardware page table walker.

**Permission checking** enforces access control on every translation. Each page table entry carries permission bits — read, write, execute — along with a user/supervisor distinction. The MMU checks these against the current access type and privilege level. A user-mode program attempting to write to a read-only page, or to execute from a page marked non-executable, triggers a page fault exception that the OS can handle.

**Page fault generation** is how the MMU signals that a translation failed. Faults can mean the page isn't mapped (the OS needs to allocate a frame or load from disk), the page exists but permissions forbid the access, or the page table entry is malformed. The MMU distinguishes instruction page faults, load page faults, and store/AMO page faults so the OS can respond appropriately.

### History

The concept of virtual memory dates to the Atlas Computer at the University of Manchester (1962), which introduced the idea of a "one-level store" where programs could address more memory than physically existed. The hardware would automatically transfer pages between drum storage and core memory.

Through the 1960s and 1970s, virtual memory moved from research curiosity to commercial necessity. The IBM System/360 Model 67 (1965) and Multics (1969) established the pattern of paged virtual memory with hardware-walked page tables and per-page protection bits. These machines demonstrated that hardware address translation was essential — software-only translation was far too slow for every memory access.

The microprocessor era initially did without MMUs. Early chips like the Intel 8080 and MOS 6502 used flat physical addressing. The Motorola 68010 (1982) was among the first microprocessors with full virtual memory support. Intel's 80386 (1985) brought paged virtual memory to the x86 line with a two-level page table scheme that, in its fundamentals, persisted for decades.

RISC architectures took a different path. MIPS and SPARC used software-managed TLBs — the hardware detected a TLB miss, but the OS handled the page table walk in a trap handler. This simplified the hardware but added interrupt latency on every miss. ARM and later RISC-V returned to hardware-walked page tables, recognising that the performance cost of software TLB refill was too high for modern memory access patterns.

The RISC-V Privileged Specification defines Sv32 (two-level, 32-bit virtual address), Sv39 (three-level, 39-bit), and Sv48 (four-level, 48-bit) as standardised page table formats. Sv32, implemented in this project, is the simplest and targets RV32 systems — embedded processors, microcontrollers, and educational cores where a 4 GiB virtual address space is sufficient.

### Security Role

The MMU is one of the most security-critical components in a processor. It is the hardware root of process isolation — the mechanism that prevents one process from reading another's memory, that stops user code from modifying kernel data structures, and that enforces W^X (write XOR execute) policies to make code injection harder.

**Process isolation** depends entirely on the MMU. Each process gets its own page table, mapping virtual addresses to different physical frames. Process A simply cannot name a virtual address that resolves to Process B's physical memory unless the OS explicitly creates a shared mapping. This is the foundation that separates a multi-user operating system from a cooperative batch monitor.

**Privilege separation** between user mode and supervisor mode is enforced through the U bit in each page table entry. Kernel pages are marked U=0, making them inaccessible from user mode. The SUM (Supervisor User Memory access) bit in `mstatus` controls whether even the kernel can access user pages — a deliberate restriction that prevents confused-deputy attacks where the kernel is tricked into reading user-controlled mappings.

**Non-executable memory** (the X bit) is a direct hardware defence against code injection. Marking the stack and heap as non-executable means that even if an attacker writes shellcode into a buffer, the processor will fault when trying to execute it. Combined with non-writable code pages (W=0 on text segments), the MMU enforces W^X at the hardware level.

**Side-channel attacks** have revealed that the MMU and TLB are also an attack surface. Meltdown (2018) exploited speculative execution to read kernel memory from user space, bypassing MMU permission checks in the speculative window. Spectre variants used TLB timing to infer information about other processes' memory layouts. These attacks led to kernel page table isolation (KPTI / KAISER), where user-mode and kernel-mode page tables are separated so that kernel mappings are not even present in the TLB during user execution. The ASID (Address Space Identifier) tagging in this design is part of the same defence — it allows the TLB to hold entries from multiple address spaces without cross-contamination, and SFENCE.VMA provides the mechanism to invalidate stale entries on context switches.

### The Future

MMU designs continue to evolve under pressure from larger address spaces, virtualisation, and security requirements.

**Larger virtual address spaces** are driven by growing memory capacities. Sv39 and Sv48 extend the page table to three and four levels respectively, supporting 512 GiB and 256 TiB virtual address spaces. Sv57 (five levels, 128 PiB) is specified for future use. Each additional level adds latency to TLB misses, increasing the importance of large TLBs and hardware page table walk caches.

**Hardware virtualisation** adds a second layer of address translation. A hypervisor's MMU must translate guest-virtual to guest-physical to host-physical addresses, potentially doubling the page table walk depth. RISC-V's hypervisor extension (H-extension) defines a two-stage translation scheme where the MMU performs nested walks. Efficient implementations cache intermediate translations and use larger TLBs to absorb the extra miss cost.

**Confidential computing** architectures like ARM CCA, Intel TDX, and AMD SEV extend the MMU's role from simple translation to cryptographic memory isolation. The MMU becomes part of a trust boundary — pages belonging to a confidential VM are encrypted in DRAM with per-VM keys, and the MMU metadata includes integrity tags. Future RISC-V extensions (such as the proposed IOPMP and WorldGuard specifications) are moving in the same direction, using the translation infrastructure to enforce hardware-rooted isolation between security domains.

**Memory tagging** (ARM MTE, CHERI capabilities) represents a convergence of MMU and pointer safety. Instead of treating the address as an opaque integer, the hardware attaches metadata — a tag, a capability, a colour — that the MMU checks on every access. This moves security enforcement from the page granularity (4 KiB) down to individual allocations (16 bytes for MTE), catching use-after-free and buffer overflows that page-level protection cannot detect.

**Hardware-accelerated page table management** is another active area. Current designs require the OS to maintain page tables in memory and flush the TLB on changes. Research into hardware-maintained page tables, speculative TLB prefetching, and translation-aware cache hierarchies aims to reduce the cost of page faults and TLB misses as working sets grow beyond what current TLB sizes can cover.

## Architecture Overview

```
                     ┌─────────────────────────────────────────────────┐
                     │                   mmu_top                      │
                     │                                                │
  CPU Request ──────►│  ┌──────────┐     ┌──────────────────┐         │
  (vaddr, type,      │  │          │hit  │                  │         │
   priv_mode)        │  │   TLB    ├────►│   Permission     ├──►Response
                     │  │  (FA,    │     │   Checker        │  (paddr,
  satp ─────────────►│  │   LRU)   │     │                  │   fault)
                     │  │          │     └──────────────────┘         │
  SFENCE.VMA ───────►│  └────┬─────┘                                  │
                     │       │miss                                    │
                     │       ▼                                        │
                     │  ┌──────────┐     ┌──────────────────┐         │
                     │  │  Page    │────►│   Memory         │         │
                     │  │  Table   │◄────│   Interface      │◄───────►│ Memory
                     │  │  Walker  │     └──────────────────┘         │
                     │  └──────────┘                                  │
                     └─────────────────────────────────────────────────┘
```

## Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `TLB_ENTRIES` | 16 | Number of fully-associative TLB entries |
| `PAGE_SIZE` | 4096 | Page size in bytes (4 KiB) |
| `VPN_W` | 20 | Virtual page number width (2 × 10-bit VPN fields) |
| `PPN_W` | 22 | Physical page number width |
| `ASID_W` | 9 | Address Space Identifier width |

## Module Hierarchy

```
mmu_top                         Top-level MMU with arbitration FSM
├── mmu_pkg.sv                  Package: parameters, types, constants
├── tlb.sv                      Fully-associative TLB with LRU replacement
│   └── lru_tracker.sv          True LRU replacement tracker (NxN matrix)
├── page_table_walker.sv        Sv32 two-level PTW (FSM + memory interface)
└── permission_checker.sv       Access permission & fault logic
```

## Sv32 Address Translation

```
 31    22 21    12 11        0
┌────────┬────────┬───────────┐
│ VPN[1] │ VPN[0] │  Offset   │   Virtual Address (32-bit)
└───┬────┴───┬────┴───────────┘
    │        │
    │  ┌─────┘
    ▼  ▼
  Two-level page table walk
    │  │
    ▼  ▼
┌────────────────┬───────────┐
│     PPN        │  Offset   │   Physical Address (32-bit)
└────────────────┴───────────┘

Megapage (4 MiB): PPN[1] from PTE, VPN[0]+Offset from VA
```

## Project Structure

```
MMU/
├── rtl/
│   ├── mmu_pkg.sv                  # Package: parameters, types, PTE struct
│   ├── lru_tracker.sv              # LRU replacement policy
│   ├── tlb.sv                      # Fully-associative TLB
│   ├── permission_checker.sv       # Access permission & fault generation
│   ├── page_table_walker.sv        # Sv32 two-level hardware PTW
│   └── mmu_top.sv                  # Top-level with arbitration FSM
├── tb/
│   ├── sv/
│   │   ├── tb_lru_tracker.sv       # 10 tests
│   │   ├── tb_tlb.sv               # 17 tests
│   │   ├── tb_permission_checker.sv # 20 tests
│   │   ├── tb_page_table_walker.sv # 11 tests
│   │   └── tb_mmu_top.sv           # 22 tests
│   └── cocotb/
│       ├── test_lru_tracker.py     # 7 tests
│       ├── test_tlb.py             # 9 tests
│       ├── test_permission_checker.py # 16 tests
│       ├── test_page_table_walker.py  # 8 tests
│       ├── test_mmu_top.py         # 11 tests
│       ├── Makefile.lru
│       ├── Makefile.tlb
│       ├── Makefile.perm
│       ├── Makefile.ptw
│       └── Makefile.mmu
├── scripts/
│   ├── run_sim.sh                  # Master SV simulation runner
│   └── run_cocotb.sh               # Master CocoTB runner
├── docs/
│   └── mmu_report.md               # Technical report
└── README.md
```

## Verification

### SystemVerilog Testbenches (80 tests)

```bash
# Run all SV tests
./scripts/run_sim.sh all

# Run a specific module
./scripts/run_sim.sh tlb
```

### CocoTB Testbenches (51 tests)

```bash
# Run all CocoTB tests
./scripts/run_cocotb.sh all

# Run a specific module
./scripts/run_cocotb.sh page_table_walker
```

### Manual Compilation

```bash
# Single module
iverilog -g2012 -Wall -o sim_tlb rtl/mmu_pkg.sv rtl/lru_tracker.sv rtl/tlb.sv tb/sv/tb_tlb.sv
vvp sim_tlb

# Full integration
iverilog -g2012 -Wall -o sim_mmu rtl/mmu_pkg.sv rtl/lru_tracker.sv rtl/tlb.sv \
    rtl/permission_checker.sv rtl/page_table_walker.sv rtl/mmu_top.sv tb/sv/tb_mmu_top.sv
vvp sim_mmu
```

## Design Decisions

- **Sv32 format**: Chosen for compatibility with 32-bit RISC-V cores (RV32). Two-level page tables keep the PTW simple while supporting 4 GiB virtual address spaces.

- **Fully-associative TLB**: Avoids conflict misses that plague direct-mapped or set-associative TLBs. Practical at the default 16-entry size. The NxN matrix LRU approach provides true LRU tracking without the complexity of age counters.

- **True LRU replacement**: The NxN bit matrix provides exact LRU ordering. For 16 entries this requires 256 bits of state — acceptable for a TLB. Pseudo-LRU would use less area but provides weaker eviction guarantees.

- **Multi-state PTW completion**: After the PTW finishes, results are registered before permission checking (ST_PTW_DONE → ST_PERM_CHECK). This avoids combinational loops between the PTW, TLB, and permission checker that can cause simulation issues in iverilog while also providing cleaner timing for synthesis.

- **32-bit physical address output**: Although Sv32 supports 34-bit physical addresses, this implementation outputs 32-bit addresses for simpler integration with 32-bit bus systems.

## Extending the Design

- **Sv39 support**: Add a third page table level and extend VPN to 27 bits. The PTW FSM would need L2_REQ/L2_WAIT/L2_CHECK states. Parameterise the walk depth.

- **Larger TLBs**: Increase `TLB_ENTRIES`. For >32 entries, consider switching to set-associative organisation and pseudo-LRU to reduce area.

- **Two-level TLB**: Add a small L1 TLB (4-8 entries, fully associative) and a larger L2 (64+ entries, set associative) with different access latencies.

- **D/A bit writeback**: Extend the PTW to write back Dirty and Accessed bits to the page table in memory when they transition from 0 to 1.

- **PMP/PMA checking**: Add Physical Memory Protection and Physical Memory Attribute checking after address translation.

- **Performance counters**: Add TLB hit/miss counters and PTW cycle counters for profiling.

## License

MIT
