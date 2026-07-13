<#
.SYNOPSIS
    Assemble the dasm bounce demo for the Commander X16 and, optionally,
    run it. dasm has no linker: it writes the .prg directly.

    dasm is NOT a VS64 toolkit (like Prog8/64tass), so this project has no
    project-config.json and no F5 source-level debugging. What you get:
    build + run + SYMBOLIC debugging in Box16's own ImGui debugger, via a
    VICE label file converted from dasm's symbol dump.

.EXAMPLE
    .\build_dasm.ps1                       # assemble -> build\bounce.prg
    .\build_dasm.ps1 -Run                  # ...and run in x16emu
    .\build_dasm.ps1 -Source examples\bounce.asm
#>
param(
    [string]$Source = "examples\bounce.asm",
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
$dasm  = Join-Path $repo "dasm-sdk\dasm.exe"
$emu   = Join-Path $repo "emulator\x16emu.exe"
$rom   = Join-Path $repo "emulator\rom.bin"
$src   = Join-Path $root "src_dasm"
$build = Join-Path $root "build"

if (-not (Test-Path $dasm)) { Fail "missing: $dasm (see README -- install dasm into dasm-sdk\)" }
if (-not (Test-Path $src))  { Fail "missing: $src (copy src_dasm\ from x16_library -- see README)" }
if (-not (Test-Path $build)) { New-Item -ItemType Directory -Path $build | Out-Null }

$name = [IO.Path]::GetFileNameWithoutExtension($Source)
$prg  = Join-Path $build "$name.prg"
$sym  = Join-Path $build "$name.sym"
$lbl  = Join-Path $build "$name.lbl"
$lst  = Join-Path $build "$name.lst"
$dbg  = Join-Path $build "$name.dbg"

# dasm resolves `include` against the current dir and each -I path.
# -l writes the listing (file/line/address/bytes) that becomes the .dbg.
Write-Host "dasm  $Source -> $prg"
Push-Location $root
try {
    & $dasm $Source "-I$src" -f1 "-o$prg" "-s$sym" "-l$lst"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { Fail "dasm assembly failed" }
Write-Host ("      {0} bytes" -f (Get-Item $prg).Length)

# Turn the listing + symbol dump into a cc65-style .dbg so VS64's debugger
# can step through the dasm source (VS64 selects the parser by extension).
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if ($py) {
    & $py (Join-Path $root "tools\dasm2dbg.py") $lst $sym $dbg $prg 0x0801
} else {
    Write-Host "      (python not found -- skipping .dbg; symbolic Box16 debug still works)" -ForegroundColor Yellow
}

# Convert dasm's symbol dump ("LABEL   HHHH   (R )") into a VICE label
# file ("al C:HHHH .LABEL") so Box16's -sym shows your names.
$labels = Get-Content $sym |
    Where-Object { $_ -match '^([A-Za-z_][\w]*)\s+([0-9A-Fa-f]{4})\b' } |
    ForEach-Object {
        $null = $_ -match '^([A-Za-z_][\w]*)\s+([0-9A-Fa-f]{4})\b'
        "al C:$($Matches[2]) .$($Matches[1])"
    }
[IO.File]::WriteAllLines($lbl, $labels)
Write-Host ("      {0} labels -> {1}" -f $labels.Count, (Split-Path $lbl -Leaf))

if ($Run) {
    if (-not (Test-Path $emu)) { Fail "missing: $emu" }
    Write-Host "x16emu $prg"
    & $emu -rom $rom -prg $prg -run -scale $Scale
}
