; USB low-speed SYNC + DATA0 PID on D+/D- (uio[0]/uio[1]).
; Uses the general assist: 33-cycle bit tick at 50 MHz (~1.5 Mbit/s),
; NRZI, and bit stuffing. SYNC is 0x80 (00000001 chronological, LSB first).
; DATA0 PID is 0xC3.

DIR  0x03
OUT  0x02            ; idle J: D+ low, D- high
AOUT 1, 33           ; bit period
AOUT 0, 0x0C         ; STUFF_EN | NRZI_EN
AOUT 2, 0x80         ; SYNC
AOUT 2, 0xC3         ; DATA0 PID
AOUT 0, 0x0D         ; start TX
wait_done:
AIN  R0, 0
ANDI R0, 0x01
JNZ  R0, wait_done
HALT
