set_param general.maxThreads 4
create_project -in_memory -part xc7a35tcpg236-1

read_verilog -sv [list \
    /home/brendan/synthesis_workspace/MMU/rtl/mmu_pkg.sv \
    /home/brendan/synthesis_workspace/MMU/rtl/lru_tracker.sv \
    /home/brendan/synthesis_workspace/MMU/rtl/page_table_walker.sv \
    /home/brendan/synthesis_workspace/MMU/rtl/permission_checker.sv \
    /home/brendan/synthesis_workspace/MMU/rtl/tlb.sv \
    /home/brendan/synthesis_workspace/MMU/rtl/mmu_top.sv \
]

set xdc_file "/home/brendan/synthesis_workspace/MMU/synthesis_logs/clock.xdc"
set fp [open $xdc_file w]
puts $fp "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fp
read_xdc $xdc_file

synth_design -top mmu_top -part xc7a35tcpg236-1

report_utilization -file /home/brendan/synthesis_workspace/MMU/synthesis_logs/utilization_mmu_top.rpt
report_timing_summary -file /home/brendan/synthesis_workspace/MMU/synthesis_logs/timing_mmu_top.rpt
