; 10 Mbps MAC: 60-byte padded frame on RMII Map A (uio[2:7]).
; Serial engine: period 10, width-2 NRZ, CRC-32, hardware preamble/SFD/IFG.
; After TX, start RX so a LAN8720-class loopback model can return the frame.
; Analog PHY and magnetics stay off-chip.

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
HALT
