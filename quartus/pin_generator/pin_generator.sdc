create_clock -name clk -period 10.000 [get_ports {clk}]
derive_clock_uncertainty

set_input_delay -clock clk 0.000 [get_ports {reset enable cycles_per_toggle[*]}]
set_output_delay -clock clk 0.000 [get_ports {pin_out}]
