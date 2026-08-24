# 실제 사용 소프트웨어

이 폴더에는 Version 2 시스템에서 실제 사용하는 파일만 둔다.

## Jetson Nano

- `jetson_main.py`
- 기존 Jetson ↔ ZYBO 8-bit SPI 동작을 그대로 사용한다.
- 실행 환경: Jetson Nano, Python, `spidev`, `Jetson.GPIO`

```bash
python3 jetson_main.py
```

## 관제실 PC

- `pc_control_room_secure.py`: AES-128-GCM UART 관제 프로그램 및 30초 세션키 핸드셰이크
- `aes_gcm_128.py`: 48-byte 암호 프레임 처리 모듈
- `users.json`: 사용자 정보
- 실행 전 `pc_control_room_secure.py`의 `SERIAL_PORT`를 실제 COM 번호로 맞춘다.
- 실행 환경: Python 3, `pyserial`, Tkinter

```powershell
python pc_control_room_secure.py
```

ZYBO가 보낸 난수만 `0초 / 30초`부터 매초 로그에 표시한다. 마스터키와
계산된 세션키는 로그에 출력하지 않는다. 키 교환 중 사용자가 누른 명령은
보관했다가 새 키 확인이 끝난 후 자동 전송한다.

관제실 파일 세 개는 반드시 같은 폴더에 둔다. `__pycache__`와 `.pyc`는 Python이 자동으로 다시 만드는 임시 파일이므로 전달 대상이 아니다.
