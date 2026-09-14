create_clock -name clk -period 10.000 [get_ports {clk}]
derive_clock_uncertainty

set_input_delay -clock clk 0.000 [get_ports {reset start data[*]}]
set_output_delay -clock clk 0.000 [get_ports {tx busy done}]
