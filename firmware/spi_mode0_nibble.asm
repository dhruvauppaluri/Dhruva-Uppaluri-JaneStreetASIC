; Send the four-bit value 0xA, MSB first, using SPI mode 0.
; pin 0 = MOSI, pin 1 = SCLK. Each half-period is ten clocks at 50 MHz.

DIR  0x03
OUT  0x01
WAIT 8
OUT  0x03
WAIT 8
OUT  0x00
WAIT 8
OUT  0x02
WAIT 8
OUT  0x01
WAIT 8
OUT  0x03
WAIT 8
OUT  0x00
WAIT 8
OUT  0x02
WAIT 8
OUT  0x00
HALT
