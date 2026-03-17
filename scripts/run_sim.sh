#!/bin/bash
# Brendan Lynskey 2025
# Master simulation runner for MMU RTL (iverilog)
# Usage: ./run_sim.sh [module|all]

set -e

cd "$(dirname "$0")/.."

RTL_DIR="rtl"
TB_DIR="tb/sv"
BUILD_DIR="build"
mkdir -p "$BUILD_DIR"

PKG="$RTL_DIR/mmu_pkg.sv"

declare -A MODULES
MODULES=(
    [lru_tracker]="$PKG $RTL_DIR/lru_tracker.sv|$TB_DIR/tb_lru_tracker.sv"
    [permission_checker]="$PKG $RTL_DIR/permission_checker.sv|$TB_DIR/tb_permission_checker.sv"
    [tlb]="$PKG $RTL_DIR/lru_tracker.sv $RTL_DIR/tlb.sv|$TB_DIR/tb_tlb.sv"
    [page_table_walker]="$PKG $RTL_DIR/page_table_walker.sv|$TB_DIR/tb_page_table_walker.sv"
    [mmu_top]="$PKG $RTL_DIR/lru_tracker.sv $RTL_DIR/tlb.sv $RTL_DIR/permission_checker.sv $RTL_DIR/page_table_walker.sv $RTL_DIR/mmu_top.sv|$TB_DIR/tb_mmu_top.sv"
)

run_module() {
    local name=$1
    local spec=${MODULES[$name]}
    local rtl_files="${spec%%|*}"
    local tb_file="${spec##*|}"
    local sim_out="$BUILD_DIR/sim_$name"

    echo "=== Compiling $name ==="
    iverilog -g2012 -Wall -o "$sim_out" $rtl_files $tb_file

    echo "=== Running $name ==="
    if vvp "$sim_out" | tee /dev/stderr | grep -q "FAIL"; then
        echo "--- $name: FAILED ---"
        return 1
    else
        echo "--- $name: PASSED ---"
        return 0
    fi
}

if [ $# -eq 0 ] || [ "$1" = "all" ]; then
    TOTAL=0
    PASSED=0
    FAILED=0
    for mod in lru_tracker permission_checker tlb page_table_walker mmu_top; do
        TOTAL=$((TOTAL + 1))
        if run_module "$mod"; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
        echo ""
    done
    echo "=============================="
    echo "Total: $TOTAL  Passed: $PASSED  Failed: $FAILED"
    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
elif [ -n "${MODULES[$1]}" ]; then
    run_module "$1"
else
    echo "Unknown module: $1"
    echo "Available: ${!MODULES[*]}"
    echo "Usage: $0 [module|all]"
    exit 1
fi
