@echo off
setlocal EnableDelayedExpansion
rem ld65 wrapper for the cx16 target, selected by the "linker" attribute in
rem project-config.json.
rem
rem Why it exists: VS64 2.6.2 hardcodes "c64.lib" as the runtime library at
rem the END of its cc65 link line and never emits the project "libraries"
rem attribute. ld65 only pulls archive members referenced by PRECEDING
rem object files, so extra libraries cannot be smuggled in via linkerFlags
rem (those land BEFORE the objects). This wrapper therefore drops the wrong
rem c64.lib and appends the x16clib archive plus the cx16 runtime, keeping
rem every other argument (including --dbgfile) untouched.
set ARGS=
for %%A in (%*) do (
    if /I not "%%~A"=="c64.lib" set ARGS=!ARGS! "%%~A"
)
"%~dp0..\cc65-sdk\bin\ld65.exe" !ARGS! "%~dp0dist_ca65\x16c.lib" "%~dp0..\cc65-sdk\lib\cx16.lib"
exit /b %ERRORLEVEL%
