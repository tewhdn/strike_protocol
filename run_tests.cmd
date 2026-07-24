@echo off
setlocal
cd /d "%~dp0.."
python -m strike_protocol.server.test_server
if errorlevel 1 pause

