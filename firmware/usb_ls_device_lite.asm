; USB LS device-lite on D+/D- (Map A uio[0]/uio[1]).
; Shared serial engine: 33-cycle tick, NRZI, stuffing, CRC-16, auto EOP.
; Reacts to bus reset (debounced SE0 longer than EOP), SET_ADDRESS, and
; GET_DESCRIPTOR (device). Token CRC-5 is ignored. Analog PHY is off-chip.

DIR  0x00
LDI  R1, 0
LDI  R2, 0

main:
AIN  R0, 0
ANDI R0, 0x08
JZ   R0, start_rx
LDI  R3, 8
se0_loop:
WAIT 31
AIN  R0, 0
ANDI R0, 0x08
JZ   R0, start_rx
ADDI R3, 0xFF
JNZ  R3, se0_loop
wait_j:
AIN  R0, 0
ANDI R0, 0x08
JNZ  R0, wait_j
LDI  R1, 0
LDI  R2, 0
JMP  main

start_rx:
AOUT 1, 33
AOUT 3, 0xD8
AOUT 0, 0x2C
wait_pkt:
AIN  R0, 0
ANDI R0, 0x10
JZ   R0, wait_pkt
AIN  R0, 2
XORI R0, 0x2D
JZ   R0, do_setup
XORI R0, 0x2D
XORI R0, 0x69
JZ   R0, do_in
XORI R0, 0x69
XORI R0, 0xE1
JZ   R0, do_out
JMP  main

do_setup:
AOUT 1, 33
AOUT 3, 0xD8
AOUT 0, 0x2C
wait_sdata:
AIN  R0, 0
ANDI R0, 0x10
JZ   R0, wait_sdata
AIN  R0, 2
AIN  R0, 2
AIN  R3, 2
XORI R3, 5
JZ   R3, sav_addr
XORI R3, 5
XORI R3, 6
JZ   R3, sav_gdesc
JMP  send_ack
sav_addr:
AIN  R1, 2
LDI  R2, 1
JMP  send_ack
sav_gdesc:
LDI  R2, 2
JMP  send_ack

do_in:
XORI R2, 2
JZ   R2, send_desc
XORI R2, 2
XORI R2, 1
JZ   R2, send_zlp
JMP  main

do_out:
AOUT 1, 33
AOUT 3, 0xD8
AOUT 0, 0x2C
wait_odata:
AIN  R0, 0
ANDI R0, 0x10
JZ   R0, wait_odata
LDI  R2, 0
JMP  send_ack

send_ack:
AOUT 0, 0x02
AOUT 1, 33
AOUT 3, 0xD0
AOUT 0, 0x0C
AOUT 2, 0x80
AOUT 2, 0xD2
AOUT 0, 0x0D
wait_ack:
AIN  R0, 0
ANDI R0, 0x01
JNZ  R0, wait_ack
AOUT 0, 0x0C
JMP  main

send_zlp:
AOUT 0, 0x02
AOUT 1, 33
AOUT 3, 0xD8
AOUT 0, 0x0C
AOUT 2, 0x80
AOUT 2, 0x4B
AOUT 0, 0x0D
wait_zlp:
AIN  R0, 0
ANDI R0, 0x01
JNZ  R0, wait_zlp
AOUT 0, 0x0C
LDI  R2, 0
JMP  main

send_desc:
AOUT 0, 0x02
AOUT 1, 33
AOUT 3, 0xD8
AOUT 0, 0x0C
AOUT 2, 0x80
AOUT 2, 0x4B
AOUT 2, 0x12
AOUT 2, 0x01
AOUT 2, 0x00
AOUT 2, 0x02
AOUT 2, 0x00
AOUT 2, 0x00
AOUT 2, 0x00
AOUT 2, 0x08
AOUT 2, 0xFF
AOUT 2, 0xFF
AOUT 2, 0x01
AOUT 2, 0x00
AOUT 2, 0x00
AOUT 2, 0x01
AOUT 2, 0x00
AOUT 2, 0x00
AOUT 2, 0x00
AOUT 2, 0x01
AOUT 0, 0x0D
wait_desc:
AIN  R0, 0
ANDI R0, 0x01
JNZ  R0, wait_desc
AOUT 0, 0x0C
LDI  R2, 0
JMP  main
