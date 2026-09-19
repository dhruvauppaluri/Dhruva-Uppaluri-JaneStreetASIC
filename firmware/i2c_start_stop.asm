; Generate an open-drain I2C START followed by STOP.
; pin 0 = SDA, pin 1 = SCL. OUT remains zero; DIR drives a pin low when its
; bit is one and releases it when its bit is zero.

OUT  0x00
DIR  0x00            ; release SDA and SCL
WAIT 8
DIR  0x01            ; START: SDA low while SCL is high
WAIT 8
DIR  0x03            ; pull SCL low
WAIT 8
DIR  0x01            ; release SCL high
WAIT 8
DIR  0x00            ; STOP: release SDA high
HALT
