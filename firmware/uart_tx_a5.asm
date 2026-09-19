; Transmit 0xA5 as 8N1 UART on pin 0 at 1 Mbit/s with a 50 MHz clock.
; The interval between OUT instructions is WAIT + 2 cycles, so WAIT 48
; produces a 50-cycle bit period.

DIR  0x01
OUT  0x01            ; idle high
WAIT 2

OUT  0x00            ; start bit
WAIT 48
OUT  0x01            ; data bit 0
WAIT 48
OUT  0x00            ; data bit 1
WAIT 48
OUT  0x01            ; data bit 2
WAIT 48
OUT  0x00            ; data bit 3
WAIT 48
OUT  0x00            ; data bit 4
WAIT 48
OUT  0x01            ; data bit 5
WAIT 48
OUT  0x00            ; data bit 6
WAIT 48
OUT  0x01            ; data bit 7
WAIT 48
OUT  0x01            ; stop bit
WAIT 48
HALT
