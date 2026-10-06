; USB low-speed DATA0 packet: SYNC, PID, one payload byte, CRC-16.
; CRC is computed by the assist (USB polynomial) over the payload only.
; Payload 0xA5 -> CRC wire bytes 0x80, 0xC4. After the packet, drive two
; bit-times of SE0 and return to J (end-of-packet).

DIR  0x03
OUT  0x02
AOUT 1, 33
AOUT 0, 0x1C         ; CRC_RESET | STUFF_EN | NRZI_EN
AOUT 3, 0xA5         ; feed payload into CRC-16
AIN  R0, 3           ; CRC low (wire value)
AIN  R1, 1           ; CRC high (wire value)
AOUT 0, 0x0C
AOUT 2, 0x80         ; SYNC
AOUT 2, 0xC3         ; DATA0 PID
AOUT 2, 0xA5         ; payload
AOUT 2, R0           ; CRC-16 low
AOUT 2, R1           ; CRC-16 high
AOUT 0, 0x0D         ; start TX
wait_done:
AIN  R0, 0
ANDI R0, 0x01
JNZ  R0, wait_done
AOUT 0, 0x4C         ; FORCE_SE0 | STUFF_EN | NRZI_EN
WAIT 64              ; 66-cycle gap from this AOUT to the next (~2 LS bits)
AOUT 0, 0x8C         ; overlay J idle
WAIT 31
AOUT 0, 0x00         ; release pins back to CPU
HALT
