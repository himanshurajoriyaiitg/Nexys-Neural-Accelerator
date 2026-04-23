## Nexys A7-100T minimal constraints for this project.
## Clock and LED pin names match Digilent's published master XDC naming.
## UART bridge pins follow the standard Nexys A7 USB-UART connection.

set_property PACKAGE_PIN E3 [get_ports CLK100MHZ]
set_property IOSTANDARD LVCMOS33 [get_ports CLK100MHZ]
create_clock -name sys_clk -period 10.000 [get_ports CLK100MHZ]

set_property PACKAGE_PIN C12 [get_ports CPU_RESETN]
set_property IOSTANDARD LVCMOS33 [get_ports CPU_RESETN]

set_property PACKAGE_PIN H17 [get_ports {LED[0]}]
set_property PACKAGE_PIN K15 [get_ports {LED[1]}]
set_property PACKAGE_PIN J13 [get_ports {LED[2]}]
set_property PACKAGE_PIN N14 [get_ports {LED[3]}]
set_property PACKAGE_PIN R18 [get_ports {LED[4]}]
set_property PACKAGE_PIN V17 [get_ports {LED[5]}]
set_property PACKAGE_PIN U17 [get_ports {LED[6]}]
set_property PACKAGE_PIN U16 [get_ports {LED[7]}]
set_property PACKAGE_PIN V16 [get_ports {LED[8]}]
set_property PACKAGE_PIN T15 [get_ports {LED[9]}]
set_property PACKAGE_PIN U14 [get_ports {LED[10]}]
set_property PACKAGE_PIN T16 [get_ports {LED[11]}]
set_property PACKAGE_PIN V15 [get_ports {LED[12]}]
set_property PACKAGE_PIN V14 [get_ports {LED[13]}]
set_property PACKAGE_PIN V12 [get_ports {LED[14]}]
set_property PACKAGE_PIN V11 [get_ports {LED[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {LED[*]}]

set_property PACKAGE_PIN C4 [get_ports UART_TXD_IN]
set_property PACKAGE_PIN D4 [get_ports UART_RXD_OUT]
set_property IOSTANDARD LVCMOS33 [get_ports UART_TXD_IN]
set_property IOSTANDARD LVCMOS33 [get_ports UART_RXD_OUT]
