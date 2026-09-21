BUILD_DIR := build
CORE_SOURCES := src/protocol_processor.sv
ASIC_SOURCES := $(CORE_SOURCES) src/serial_program_loader.sv src/protocol_classifier.sv src/tt_um_dhruvauppaluri_protocol_emulator.sv

.PHONY: all test firmware lint synth clean

all: test lint synth

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

firmware: | $(BUILD_DIR)
	python3 tools/assemble.py firmware/uart_tx_a5.asm $(BUILD_DIR)/uart_tx_a5.hex
	python3 tools/assemble.py firmware/spi_mode0_nibble.asm $(BUILD_DIR)/spi_mode0_nibble.hex
	python3 tools/assemble.py firmware/i2c_start_stop.asm $(BUILD_DIR)/i2c_start_stop.hex
	cmp firmware/uart_tx_a5.hex $(BUILD_DIR)/uart_tx_a5.hex
	cmp firmware/spi_mode0_nibble.hex $(BUILD_DIR)/spi_mode0_nibble.hex
	cmp firmware/i2c_start_stop.hex $(BUILD_DIR)/i2c_start_stop.hex

test: firmware
	iverilog -g2012 -Wall -s pin_generator_tb -o $(BUILD_DIR)/pin_generator_tb.out pin_generator.sv pin_generator_tb.sv
	vvp $(BUILD_DIR)/pin_generator_tb.out
	iverilog -g2012 -Wall -s uart_tx_tb -o $(BUILD_DIR)/uart_tx_tb.out uart_tx.sv uart_tx_tb.sv
	vvp $(BUILD_DIR)/uart_tx_tb.out
	iverilog -g2012 -Wall -s protocol_program_rom_tb -o $(BUILD_DIR)/protocol_program_rom_tb.out protocol_program_rom.sv protocol_program_rom_tb.sv
	vvp $(BUILD_DIR)/protocol_program_rom_tb.out
	iverilog -g2012 -Wall -s program_counter_tb -o $(BUILD_DIR)/program_counter_tb.out program_counter.sv program_counter_tb.sv
	vvp $(BUILD_DIR)/program_counter_tb.out
	iverilog -g2012 -Wall -s integration_fetch_tb -o $(BUILD_DIR)/integration_fetch_tb.out program_counter.sv protocol_program_rom.sv integration_fetch.sv integration_fetch_tb.sv
	vvp $(BUILD_DIR)/integration_fetch_tb.out
	iverilog -g2012 -Wall -s protocol_processor_tb -o $(BUILD_DIR)/protocol_processor_tb.out $(CORE_SOURCES) protocol_processor_tb.sv
	vvp $(BUILD_DIR)/protocol_processor_tb.out
	iverilog -g2012 -Wall -s uart_firmware_tb -o $(BUILD_DIR)/uart_firmware_tb.out $(CORE_SOURCES) uart_firmware_tb.sv
	vvp $(BUILD_DIR)/uart_firmware_tb.out
	iverilog -g2012 -Wall -s spi_firmware_tb -o $(BUILD_DIR)/spi_firmware_tb.out $(CORE_SOURCES) spi_firmware_tb.sv
	vvp $(BUILD_DIR)/spi_firmware_tb.out
	iverilog -g2012 -Wall -s i2c_firmware_tb -o $(BUILD_DIR)/i2c_firmware_tb.out $(CORE_SOURCES) i2c_firmware_tb.sv
	vvp $(BUILD_DIR)/i2c_firmware_tb.out
	iverilog -g2012 -Wall -s protocol_classifier_tb -o $(BUILD_DIR)/protocol_classifier_tb.out src/protocol_classifier.sv protocol_classifier_tb.sv
	vvp $(BUILD_DIR)/protocol_classifier_tb.out
	iverilog -g2012 -Wall -s tiny_tapeout_wrapper_tb -o $(BUILD_DIR)/tiny_tapeout_wrapper_tb.out $(ASIC_SOURCES) tiny_tapeout_wrapper_tb.sv
	vvp $(BUILD_DIR)/tiny_tapeout_wrapper_tb.out

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME --top-module tt_um_dhruvauppaluri_protocol_emulator $(ASIC_SOURCES)

synth: | $(BUILD_DIR)
	yosys -ql $(BUILD_DIR)/synthesis.log -p "read_verilog -sv $(ASIC_SOURCES); synth -top tt_um_dhruvauppaluri_protocol_emulator; check; stat"

clean:
	rm -rf $(BUILD_DIR)
