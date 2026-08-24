@echo off
cd /d "%~dp0"
python app.py --port COM10 --fullscreen
pause
