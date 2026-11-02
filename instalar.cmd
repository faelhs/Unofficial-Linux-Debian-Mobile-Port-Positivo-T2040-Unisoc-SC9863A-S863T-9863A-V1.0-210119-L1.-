@echo off
rem Instala o Debian 13 + Phosh no Positivo T2040. Veja o README.md antes de rodar.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ferramentas\instalar.ps1"
echo.
pause
