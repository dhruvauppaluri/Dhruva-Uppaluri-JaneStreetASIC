param(
    [string]$QuestaBin = "C:\altera_lite\25.1std\questa_fse\win64"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$originalLocation = Get-Location

$vlib = Join-Path $QuestaBin "vlib.exe"
$vlog = Join-Path $QuestaBin "vlog.exe"
$vopt = Join-Path $QuestaBin "vopt.exe"
$vsim = Join-Path $QuestaBin "vsim.exe"

foreach ($tool in @($vlib, $vlog, $vopt, $vsim)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Questa tool not found: $tool"
    }
}

$sources = @(
    "pin_generator.sv",
    "pin_generator_tb.sv",
    "uart_tx.sv",
    "uart_tx_tb.sv",
    "protocol_program_rom.sv",
    "protocol_program_rom_tb.sv",
    "program_counter.sv",
    "program_counter_tb.sv",
    "integration_fetch.sv",
    "integration_fetch_tb.sv",
    "src/protocol_processor.sv",
    "protocol_processor_tb.sv",
    "uart_firmware_tb.sv",
    "spi_firmware_tb.sv",
    "i2c_firmware_tb.sv",
    "src/protocol_classifier.sv",
    "protocol_classifier_tb.sv",
    "src/serial_program_loader.sv",
    "src/tt_um_dhruvauppaluri_protocol_emulator.sv",
    "tiny_tapeout_wrapper_tb.sv"
)

$tests = [ordered]@{
    "pin_generator_tb" = "PASS: timing, enable pause, and zero-cycle safety verified"
    "uart_tx_tb" = "PASS: UART transmitted 0x55 and 0xA3 correctly"
    "protocol_program_rom_tb" = "PASS: protocol program ROM verified"
    "program_counter_tb" = "PASS: program counter reset, advance, hold, resume, and wrap verified"
    "integration_fetch_tb" = "PASS: program counter and instruction ROM integration verified"
    "protocol_processor_tb" = "PASS: complete protocol processor ISA and timing verified"
    "uart_firmware_tb" = "PASS: UART 0xA5 firmware timing verified at 1 Mbit/s"
    "spi_firmware_tb" = "PASS: SPI mode-0 firmware transmitted 0xA with exact timing"
    "i2c_firmware_tb" = "PASS: open-drain I2C START/STOP firmware timing verified"
    "protocol_classifier_tb" = "PASS: programmable protocol signature classifier verified"
    "tiny_tapeout_wrapper_tb" = "PASS: Tiny Tapeout serial loading and execution verified"
}

$runToken = "$PID"

function Assert-ToolSucceeded {
    param([string]$Description)

    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

try {
    Set-Location -LiteralPath $repoRoot

    if (-not (Test-Path -LiteralPath "work")) {
        & $vlib work
        Assert-ToolSucceeded "Creating the Questa work library"
    }

    & $vlog -sv @sources
    Assert-ToolSucceeded "Compiling the RTL and testbenches"

    foreach ($test in $tests.GetEnumerator()) {
        # A unique optimized name avoids OneDrive holding a stale optimized
        # directory open between consecutive simulator processes.
        $optimizedName = "$($test.Key)_opt_$runToken"

        & $vopt "work.$($test.Key)" -o $optimizedName
        Assert-ToolSucceeded "Optimizing $($test.Key)"

        $output = & $vsim -c "work.$optimizedName" -do "run -all; quit -f" 2>&1
        $simulationExitCode = $LASTEXITCODE
        $output | Write-Host

        if ($simulationExitCode -ne 0) {
            throw "$($test.Key) failed with exit code $simulationExitCode"
        }

        if (($output -join "`n") -notmatch [regex]::Escape($test.Value)) {
            throw "$($test.Key) did not print its expected PASS message"
        }
    }

    Write-Host "PASS: all Questa RTL and firmware simulations completed"
}
finally {
    Set-Location -LiteralPath $originalLocation
}
