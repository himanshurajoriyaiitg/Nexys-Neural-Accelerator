set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]

set proj_name nexys_a7_uart_matmul
set proj_dir [file join $project_root vivado_project]

if {![info exists part_name]} {
    set part_name xc7a100tcsg324-1
}

create_project $proj_name $proj_dir -part $part_name -force
set_property target_language Verilog [current_project]

add_files [list \
    [file join $project_root rtl params.vh] \
    [file join $project_root rtl a_bram.v] \
    [file join $project_root rtl b_bram.v] \
    [file join $project_root rtl c_bram.v] \
    [file join $project_root rtl pe.v] \
    [file join $project_root rtl systolic_array.v] \
    [file join $project_root rtl controller.v] \
    [file join $project_root rtl tpu_top.v] \
    [file join $project_root rtl uart_rx.v] \
    [file join $project_root rtl uart_tx.v] \
    [file join $project_root rtl nexys_a7_top.v] \
]

add_files -fileset sim_1 [list \
    [file join $project_root sim tb_tpu_top.v] \
]

add_files -fileset constrs_1 [list \
    [file join $project_root constraints nexys_a7_top.xdc] \
]

set rtl_files [get_files [list \
    [file join $project_root rtl a_bram.v] \
    [file join $project_root rtl b_bram.v] \
    [file join $project_root rtl c_bram.v] \
    [file join $project_root rtl pe.v] \
    [file join $project_root rtl systolic_array.v] \
    [file join $project_root rtl controller.v] \
    [file join $project_root rtl tpu_top.v] \
    [file join $project_root rtl uart_rx.v] \
    [file join $project_root rtl uart_tx.v] \
    [file join $project_root rtl nexys_a7_top.v] \
    [file join $project_root sim tb_tpu_top.v] \
]]
set_property file_type SystemVerilog $rtl_files

set_property include_dirs [file join $project_root rtl] [current_fileset]
set_property include_dirs [file join $project_root rtl] [get_filesets sim_1]

set_property top nexys_a7_top [current_fileset]
set_property top tb_tpu_top [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Vivado project created at $proj_dir"
puts "Top module: nexys_a7_top"
puts "Part: $part_name"
