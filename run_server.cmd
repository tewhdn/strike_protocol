@echo off
setlocal
cd /d "%~dp0.."
python -m strike_protocol.server.server --host 0.0.0.0 --port 8765 %*
if errorlevel 1 pause

