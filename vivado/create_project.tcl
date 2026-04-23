# ================= ROOT PATH SETUP =================
# Always resolve relative to this script location
set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ".."]]

puts "Project root: $project_root"

# ================= PROJECT CONFIG =================
set proj_name nexys_a7_uart_matmul
set proj_dir [file join $project_root vivado_project]

if {![info exists part_name]} {
    set part_name xc7a100tcsg324-1
}

create_project $proj_name $proj_dir -part $part_name -force
set_property target_language Verilog [current_project]

# ================= RTL FILES =================
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
    [file normalize [file join $project_root rtl nexys_a7_top.v]] \
]

add_files $rtl_list

# ================= SIM FILES =================
set sim_list [list \
    [file normalize [file join $project_root sim tb_tpu_top.sv]] \
]

add_files -fileset sim_1 $sim_list

# ================= CONSTRAINT FILE =================
set xdc_path [file normalize [file join $project_root constraint board.xdc]]

puts "XDC path: $xdc_path"

if {![file exists $xdc_path]} {
    error "ERROR: XDC file not found at $xdc_path"
}

add_files -fileset constrs_1 [list $xdc_path]

# ================= FILE TYPE FIX =================
set all_sv_files [get_files [concat $rtl_list $sim_list]]
set_property file_type SystemVerilog $all_sv_files

# ================= INCLUDE DIR =================
set include_path [file normalize [file join $project_root rtl]]

set_property include_dirs $include_path [current_fileset]
set_property include_dirs $include_path [get_filesets sim_1]

# ================= TOP MODULE =================
set_property top nexys_a7_top [current_fileset]
set_property top tb_tpu_top [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

# ================= COMPILE ORDER =================
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
# ================= DONE =================
puts "========================================"
puts "Vivado project created successfully!"
puts "Location: $proj_dir"
puts "Top module: nexys_a7_top"
puts "Part: $part_name"
puts "========================================"
