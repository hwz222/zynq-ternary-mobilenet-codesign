@echo off
REM ============================================================================
REM  build.cmd -- RTL to bitstream in one step. Can be started from any directory.
REM
REM    [0/3]  multi-drive lint        rtl\sim\lint_multidrive.py --selftest
REM           elaborate the wrapper   vivado\elab_fuse_layer.ps1
REM    [1/3]  package the IP          vivado\package_fuse_ip.tcl
REM    [2/3]  block design, synthesis, implementation, post-route recovery, bitstream, XSA
REM                                   vivado\build_bd_fuse.tcl
REM
REM  Output (build\):  system_fuse_ternpose.bit, system_fuse_ternpose.xsa, util_*, timing_* and
REM  dpcheck_* reports; Vivado logs in vivado\*.log. About an hour.
REM
REM  Environment (all optional):
REM    VIVADO_SETTINGS  Vivado settings64.bat (default C:\Xilinx\Vivado\2023.2\settings64.bat)
REM    PYTHON           interpreter for the lint (default: python from PATH)
REM    FUSE_TAG         tag of the output names (default ternpose)
REM
REM  The variables set below are the build recipe; the block-design script documents each one.
REM  The recipe is the only one that closes timing at 240 MHz: do not change the strategy.
REM ============================================================================
if not defined VIVADO_SETTINGS set "VIVADO_SETTINGS=C:\Xilinx\Vivado\2023.2\settings64.bat"
call "%VIVADO_SETTINGS%"
if not defined FUSE_TAG set "FUSE_TAG=ternpose"
set "LOGTAG=_%FUSE_TAG%"
set "FUSE_HD_PROBE=1"
set "BOARD_PS=1"
set "FUSE_IMPL=1"
set "FUSE_BIT=1"
set "TWN_FREQ=240"
set "BUILD_STRATEGY=Performance_NetDelay_high"
set "FUSE_HP3_SPLIT=1"
set "FUSE_CC_ROWS3=1"
set "FUSE_T1_PBLOCK=1"
cd /d "%~dp0.."
echo ============ TREE ============
echo   building from: %CD%
if not defined PYTHON set "PYTHON=python"
echo   python: %PYTHON%
echo ============ [0/3] MULTI-DRIVE LINT ============
"%PYTHON%" rtl\sim\lint_multidrive.py --selftest
if errorlevel 1 (echo LINT FAIL -- do not build & exit /b 1)
echo ============ [0/3] ELABORATE WRAPPER ============
powershell -NoProfile -ExecutionPolicy Bypass -File vivado\elab_fuse_layer.ps1
if errorlevel 1 (echo ELABORATE FAIL & exit /b 1)
echo ============ [1/3] PACKAGE IP ============
call vivado -mode batch -nojournal -log vivado\package_fuse_ip%LOGTAG%.log -source vivado\package_fuse_ip.tcl
if not exist rtl\ip\twn_fuse_ip\component.xml (echo PACKAGE FAIL & exit /b 1)
echo ============ [2/3] BLOCK DESIGN + IMPLEMENTATION + BITSTREAM ============
call vivado -mode batch -nojournal -log vivado\build_bd_fuse%LOGTAG%.log -source vivado\build_bd_fuse.tcl
if errorlevel 1 (echo BUILD FAIL - see vivado\build_bd_fuse%LOGTAG%.log & exit /b 1)
if not exist build\system_fuse_%FUSE_TAG%.bit (echo NO BITSTREAM -- timing not met, see build\timing_impl_fuse_%FUSE_TAG%.rpt & exit /b 1)
echo ============ RESULT ============
findstr /C:"POSTROUTE" /C:"IMPL RESULT" /C:"VERDICT" vivado\build_bd_fuse%LOGTAG%.log
echo bitstream: build\system_fuse_%FUSE_TAG%.bit
echo ============ BUILD DONE ============
