<#
.SYNOPSIS
    Assemble the MADS bounce demo for the Commander X16 and, optionally,
    run it. MADS has no linker: it writes a FLAT image, so this script
    prepends the two-byte CBM load address ($0801) to make the .prg.

    MADS is NOT a VS64 toolkit (like dasm/Prog8), but F5 source-level
    debugging still works here: this script assembles with mads AND writes
    build\bounce.dbg (a cc65-format debug file synthesized from MADS's
    listing + label dump). VS64 picks its debug-info parser by extension,
    so its existing "vice" debugger loads that .dbg and steps the MADS
    source exactly like the ACME/ca65/dasm projects -- same F10/F11/
    breakpoints, same Box16 fork. build\bounce.lbl (VICE labels) drives
    Box16's own -sym symbolic disassembly.

.EXAMPLE
    .\build_mads.ps1                       # assemble -> build\bounce.prg
    .\build_mads.ps1 -Run                  # ...and run in x16emu
    .\build_mads.ps1 -Source examples\bounce.asm
#>
param(
    [string]$Source = "examples\bounce.asm",
    [int]$LoadAddress = 0x0801,
    [switch]$Run,
    [int]$Scale = 2
)

$ErrorActionPreference = "Stop"

function Fail([string]$message) {
    Write-Host $message -ForegroundColor Red
    exit 1
}

$root  = $PSScriptRoot
$repo  = Split-Path $root -Parent
$mads  = Join-Path $repo "mads-sdk\mads.exe"
$emu   = Join-Path $repo "emulator\x16emu.exe"
$rom   = Join-Path $repo "emulator\rom.bin"
$src   = Join-Path $root "src_mads"
$build = Join-Path $root "build"

if (-not (Test-Path $mads)) { Fail "missing: $mads (see README -- install MADS into mads-sdk\)" }
if (-not (Test-Path $src))  { Fail "missing: $src (copy src_mads\ from x16_library -- see README)" }
if (-not (Test-Path $build)) { New-Item -ItemType Directory -Path $build | Out-Null }

$name = [IO.Path]::GetFileNameWithoutExtension($Source)
$bin  = Join-Path $build "$name.bin"     # flat image, no load address
$prg  = Join-Path $build "$name.prg"
$lbl  = Join-Path $build "$name.lbl"
$lst  = Join-Path $build "$name.lst"
$dbg  = Join-Path $build "$name.dbg"

# -c keeps symbols case-sensitive (jsrfar vs the KERNAL's JSRFAR).
# -i:src_mads puts the library files on the include path.
# -l writes the listing (file/line/address/bytes) and -t the label dump;
# together they become the .dbg + the VICE .lbl below.
Write-Host "mads  $Source -> $prg"
Push-Location $root
try {
    & $mads $Source -c "-i:$src" "-o:$bin" "-l:$lst" "-t:$lbl" | Out-Null
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { Fail "mads assembly failed" }

# MADS emits a flat image (x16.asm sets `opt h-`), so prepend the CBM load
# address (little-endian) -- the same .prg ca65/ld65, 64tass --cbm-prg and
# ACME -f cbm produce.
$bytes = [IO.File]::ReadAllBytes($bin)
$out   = New-Object byte[] ($bytes.Length + 2)
$out[0] = [byte]($LoadAddress -band 0xFF)
$out[1] = [byte](($LoadAddress -shr 8) -band 0xFF)
[Array]::Copy($bytes, 0, $out, 2, $bytes.Length)
[IO.File]::WriteAllBytes($prg, $out)
Write-Host ("      {0} bytes" -f $out.Length)

# Turn the listing + label dump into a cc65-style .dbg so VS64's debugger
# can step through the MADS source (VS64 selects the parser by extension).
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if ($py) {
    & $py (Join-Path $root "tools\mads2dbg.py") $lst $lbl $dbg $prg $LoadAddress
} else {
    Write-Host "      (python not found -- skipping .dbg; symbolic Box16 debug still works)" -ForegroundColor Yellow
}

# Convert MADS's label dump ("BB<TAB>AAAA<TAB>NAME") into a VICE label file
# ("al C:AAAA .NAME") so Box16's -sym shows your names. MADS's -t already
# IS the label source; rewrite it into the VICE syntax and drop the wide
# (>16-bit) VRAM constants a 16-bit VICE label can't hold.
$labels = Get-Content $lbl |
    Where-Object { $_ -match '^[0-9A-Fa-f]{2}\t([0-9A-Fa-f]{1,4})\t([A-Za-z_][\w]*)\s*$' } |
    ForEach-Object {
        $null = $_ -match '^[0-9A-Fa-f]{2}\t([0-9A-Fa-f]{1,4})\t([A-Za-z_][\w]*)\s*$'
        "al C:$('{0:x4}' -f [Convert]::ToInt32($Matches[1],16)) .$($Matches[2])"
    }
[IO.File]::WriteAllLines($lbl, $labels)
Write-Host ("      {0} labels -> {1}" -f $labels.Count, (Split-Path $lbl -Leaf))

if ($Run) {
    if (-not (Test-Path $emu)) { Fail "missing: $emu" }
    Write-Host "x16emu $prg"
    & $emu -rom $rom -prg $prg -run -scale $Scale
}
