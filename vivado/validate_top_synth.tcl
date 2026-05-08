set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ".."]]
set out_dir [file normalize [file join $project_root build vivado_validate]]

file mkdir $out_dir

set rtl_list [list \
    [file normalize [file join $project_root rtl params.vh]] \
    [file normalize [file join $project_root rtl a_bram.v]] \
    [file normalize [file join $project_root rtl b_bram.v]] \
    [file normalize [file join $project_root rtl c_bram.v]] \
    [file normalize [file join $project_root rtl reset_sync.sv]] \
    [file normalize [file join $project_root rtl pe.sv]] \
    [file normalize [file join $project_root rtl systolic_array.sv]] \
    [file normalize [file join $project_root rtl controller.sv]] \
    [file normalize [file join $project_root rtl tpu_top.sv]] \
    [file normalize [file join $project_root rtl uart_rx.v]] \
    [file normalize [file join $project_root rtl uart_tx.v]] \
    [file normalize [file join $project_root rtl sevenseg_display.sv]] \
    [file normalize [file join $project_root rtl snn_core.sv]] \
    [file normalize [file join $project_root rtl snn_weights.sv]] \
    [file normalize [file join $project_root rtl nexys_a7_top.v]] \
]

read_verilog -sv $rtl_list
set xdc_path [file normalize [file join $project_root constraint board.xdc]]
read_xdc [list $xdc_path]

synth_design -top nexys_a7_top -part xc7a100tcsg324-1

report_utilization -file [file join $out_dir util_top_synth.rpt]
report_timing_summary -file [file join $out_dir timing_top_synth.rpt]

puts "Standalone synthesis completed successfully."
