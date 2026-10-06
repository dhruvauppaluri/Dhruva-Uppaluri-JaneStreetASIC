; RMII-10 TX then RX using the same serial engine and Map A pins.
; Firmware loads a 60-byte zero payload; the engine appends preamble,
; SFD, CRC-32, and IFG. The testbench PHY model loops TX dibits to RX
; after TX completes. Analog PMA/magnetics remain off-chip.

AOUT 3, 0xEF
AOUT 1, 10
AOUT 0, 0x10
LDI  R0, 0
LDI  R3, 60
fill:
AOUT 2, R0
ADDI R3, 0xFF
JNZ  R3, fill
AOUT 0, 0x01
wait_tx:
AIN  R0, 0
ANDI R0, 0x01
JNZ  R0, wait_tx
AOUT 0, 0x20
wait_rx:
AIN  R0, 0
ANDI R0, 0x10
JZ   R0, wait_rx
HALT
