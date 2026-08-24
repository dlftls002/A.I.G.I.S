# Jetson ↔ ZYBO SPI 연동 규격 — 평문 R / AES-GCM 키 확인

이 문서는 ZYBO RTL과 Jetson 소프트웨어를 연동하기 위한 개정 규격이다.
Jetson 담당자는 이 문서와 함께 `jetson_main.py`, `aes_gcm_128.py`를 사용한다.

> **적용 완료:** `0x36/0x37` AES-GCM 키 확인 방식이 ZYBO RTL,
> `jetson_main.py` 및 `zybo_secure_control_unit_v2.bit`에 반영되어 있다.
> Basys RTL과 비트스트림은 이 Jetson 전용 변경의 영향을 받지 않는다.

## 1. 전체 동작 원칙

- Jetson은 SPI Master, ZYBO는 SPI Slave다.
- 모든 전송은 정확히 48바이트(384비트)다.
- `TYPE`은 모든 프레임에서 평문이다.
- 난수 `R`은 `0x32`에서 평문으로 전달한다.
- `0x31`~`0x35`는 평문 관리 프레임이다.
- `0x36/0x37`은 새 세션키가 양쪽에서 실제로 동작하는지 확인하기 위해
  확인문/응답문 payload를 AES-128-GCM으로 처리한다.
- Face ID와 출입문 명령의 128비트 payload도 세션키로 AES-128-GCM 처리한다.
- 마스터키와 세션키는 SPI로 전송하지 않는다.
- ZYBO가 만든 하나의 R은 약 30초 동안 유지된다.
- Jetson 핸드셰이크는 PC+Basys 핸드셰이크와 독립적이다. Jetson이 없어도
  PC+ZYBO+Basys 랙 제어는 멈추지 않는다.

## 2. SPI 설정

| 항목 | 값 |
|---|---|
| Linux 장치 | `/dev/spidev0.0` |
| SPI bus/device | bus 0, device 0 |
| Mode | 0 (`CPOL=0`, `CPHA=0`) |
| Bits per word | 8 |
| Bit order | MSB first |
| 속도 | 10 MHz |
| 한 번의 전송 | 정확히 48바이트 |
| CS | 48바이트 전송 동안 Low 유지 |
| 기본 POLL 주기 | 100 ms |

```python
spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = 10_000_000
spi.mode = 0
spi.bits_per_word = 8
spi.lsbfirst = False

rx_frame = bytes(spi.xfer2(list(tx_frame)))
assert len(tx_frame) == 48
assert len(rx_frame) == 48
```

SPI는 Full-Duplex다. 한 번의 `xfer2()`에서 Jetson의 MOSI 프레임과 ZYBO의
MISO 프레임이 동시에 이동한다. ZYBO가 현재 요청을 처리해서 만든 새 응답은
다음 POLL에서 들어올 수 있다.

## 3. 프레임 종류

수신 프로그램은 먼저 `MAGIC`, `TYPE`, `LENGTH`를 읽고 TYPE에 따라
평문 관리 프레임과 AES 보호 프레임을 구분해야 한다.

### 3.1 평문 관리 프레임

`0x31`~`0x35`는 AES 암호화/복호화를 하지 않는다.

| Byte | 크기 | 내용 |
|---:|---:|---|
| 0..1 | 2 | MAGIC `A5 5A` |
| 2 | 1 | TYPE(평문) |
| 3 | 1 | LENGTH `10` |
| 4..15 | 12 | 전부 `00` |
| 16..31 | 16 | 난수 R 또는 16바이트 `00` payload |
| 32..47 | 16 | 전부 `00` |

```text
A5 5A | TYPE | 10 | 000000000000000000000000 | R 16바이트 | 0 16바이트
```

- `0x31`, `0x33`, `0x34`, `0x35`의 payload는 16바이트 전부 `00`이다.
- `0x32`의 payload만 해당 세션의 난수 R이다.
- `0x33`과 `0x35`는 payload로 세션을 식별하지 않으므로 ZYBO와 Jetson은
  각각 정확한 대기 상태에서만 해당 TYPE을 인정해야 한다.
- 관리 프레임에는 유효한 IV와 TAG가 없으므로 AES 복호화를 호출하면 안 된다.

Python에서는 다음 공통 함수를 사용한다.

```python
frame = build_clear_frame(packet_type, payload)
payload = parse_clear_frame(frame, expected_type)
```

### 3.2 AES-GCM 보호 프레임

`0x01`, `0x06`, `0x36`, `0x37`의 실제 128비트 payload를 AES-GCM으로
보호한다. TYPE과 IV는 평문이며 payload만 암호문으로 변환된다.

| Byte | 크기 | 내용 | 암호화 여부 |
|---:|---:|---|---|
| 0..1 | 2 | MAGIC `A5 5A` | 평문 |
| 2 | 1 | TYPE | 평문 |
| 3 | 1 | LENGTH `10` | 평문 |
| 4..15 | 12 | IV | 평문 |
| 16..31 | 16 | ciphertext | AES 암호문 |
| 32..47 | 16 | authentication TAG | 인증값 |

- 알고리즘: AES-128-GCM
- 원데이터 크기: 정확히 16바이트
- IV 크기: 12바이트
- TAG 크기: 16바이트
- AAD: 사용하지 않음
- 바이트/카운터 순서: big-endian
- Jetson → ZYBO Face ID(`0x01`) IV prefix: `01 00 00 01`
- ZYBO → Jetson 출입문 명령(`0x06`) IV prefix: `06 00 00 01`
- ZYBO → Jetson KEY_CONFIRM(`0x36`) IV prefix: `36 00 00 01`
- Jetson → ZYBO CONFIRM_ACK(`0x37`) IV prefix: `37 00 00 01`
- Jetson 송신 counter는 세션 codec 생성 시 1부터 시작하고 프레임마다 증가한다.
- 동일한 키에서 같은 IV를 재사용하면 안 된다.
- TAG 검증 실패 프레임은 명령이나 Face ID에 사용하지 않고 폐기한다.

## 4. 키 생성

개발용 마스터키는 Jetson과 ZYBO에 동일하게 내장한다.

```text
MASTER_KEY = 6C8E9CF570932BD5A3F104D7B89E62C1
```

ZYBO가 평문 `0x32 KEY_UPDATE`로 보낸 16바이트 R을 마스터키와 바이트 단위
XOR하여 세션키를 만든다.

```python
session_key = bytes(a ^ b for a, b in zip(MASTER_KEY, R))
```

```text
session_key = MASTER_KEY XOR R
```

- R만 SPI로 전달된다.
- MASTER_KEY는 SPI로 보내지 않는다.
- 계산된 session_key도 SPI로 보내지 않는다.
- 새로운 R을 받아도 COMMIT_ACK 전송이 끝나기 전까지는 현재 active key를
  즉시 바꾸면 안 된다.

## 5. TYPE 전체 표

| TYPE | 방향 | 의미 | Payload | AES 여부 |
|---:|---|---|---|---|
| `0x01` | Jetson → ZYBO | Face ID 애플리케이션 | 인증 결과 + 사용자 ID | AES-GCM |
| `0x06` | ZYBO → Jetson | 출입문 명령 | IDLE/OPEN/CLOSE | AES-GCM |
| `0x31` | Jetson → ZYBO | 응답 수신용 POLL | 16바이트 `00` | 평문 |
| `0x32` | ZYBO → Jetson | KEY_UPDATE | R | 평문 |
| `0x33` | Jetson → ZYBO | READY | 16바이트 `00` | 평문 |
| `0x34` | ZYBO → Jetson | KEY_COMMIT | 16바이트 `00` | 평문 |
| `0x35` | Jetson → ZYBO | COMMIT_ACK | 16바이트 `00` | 평문 |
| `0x36` | ZYBO → Jetson | 새 키 복호화 확인 요청 | CHALLENGE | AES-GCM(새 키) |
| `0x37` | Jetson → ZYBO | 복호화 성공 및 역방향 키 확인 | RESPONSE | AES-GCM(새 키) |

TYPE 자체는 모든 프레임에서 평문이다. `0x01`, `0x06`, `0x36`, `0x37`에서
AES 대상은 해당 프레임의 16바이트 payload이며 IV와 TYPE은 평문이다.

### 5.1 KEY_CONFIRM 확인값

양쪽 구현이 같은 값을 계산할 수 있도록 확인문과 응답문 원문을 다음과 같이
정의한다.

```text
CHALLENGE_CONST = 5A5A5A5A5A5A5A5AA5A5A5A5A5A5A5A5
RESPONSE_CONST  = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

CHALLENGE = R XOR CHALLENGE_CONST
RESPONSE  = CHALLENGE XOR RESPONSE_CONST
```

- `0x36`의 암호화 전 원문은 CHALLENGE다.
- `0x37`의 암호화 전 원문은 RESPONSE다.
- R, 마스터키, 세션키 자체를 `0x36/0x37`에 넣지 않는다.
- TAG 검증과 예상 원문 비교가 모두 성공해야 키 확인 성공으로 인정한다.

## 6. Jetson 핸드셰이크 순서

```text
Jetson                         ZYBO
  |                              |
  |-- 0x31 POLL, payload=0 ------>|
  |<-- 0x32 KEY_UPDATE, R --------|
  |                              |
  | R 저장                       |
  | pending_key=MASTER_KEY XOR R |
  |                              |
  |-- 0x33 READY, payload=0 ------>|
  |<-- 0x34 KEY_COMMIT, payload=0 -|
  |                              |
  |-- 0x35 COMMIT_ACK, payload=0 ->|
  | ACK 전송 완료 후 key 전환     |
  |                              |
  |-- 0x31 POLL, payload=0 ------>|
  |<-- 0x36 AES(KEY_CONFIRM) -----|
  | 새 키로 TAG 검증/복호화       |
  | CHALLENGE 확인                 |
  |                              |
  |-- 0x37 AES(CONFIRM_ACK) ------>|
  |                 새 키로 복호화|
  |                 RESPONSE 확인 |
  | ACK 전송 완료 후 RUN          |
  |                              |
  |<==== 0x01/0x06 AES 통신 =====>|
```

구현 순서는 다음과 같다.

1. 시작 직후 `0x31` 평문 POLL을 반복한다.
2. `0x32`를 받으면 payload R을 저장하고 pending session key를 계산한다.
3. 아직 active key는 바꾸지 않고 `0x33 READY`에 16바이트 `00`을 넣어 보낸다.
4. payload가 16바이트 `00`인 `0x34 KEY_COMMIT`을 받는다.
5. `0x35 COMMIT_ACK` 평문 프레임을 실제 `xfer2()`로 끝까지 전송한다.
6. 해당 `xfer2()`가 반환된 뒤 송수신 AES codec을 pending key로 교체한다.
7. 계속 평문 POLL을 보내 새 세션키로 암호화된 `0x36 KEY_CONFIRM`을 받는다.
8. 새 세션키로 TAG를 검증하고 복호화한 CHALLENGE가 예상값과 같은지 확인한다.
9. 성공하면 RESPONSE를 만들고 새 세션키로 암호화한 `0x37 CONFIRM_ACK`을 보낸다.
10. ZYBO는 `0x37`을 새 세션키로 복호화하고 RESPONSE를 확인한다.
11. Jetson은 `0x37` 전송 완료 후, ZYBO는 `0x37` 검증 완료 후에만 RUN 상태로
    들어가 Face ID와 출입문 애플리케이션 통신을 허용한다.

## 7. 재전송과 중복 메시지 처리

ZYBO는 응답을 받지 못하면 관리 메시지를 다시 보낼 수 있다. SPI가
Full-Duplex이고 응답이 다음 전송에서 도착하므로 중복 프레임은 정상적으로
발생할 수 있다.

- `0x33 READY(0)`는 ZYBO의 `WAIT_READY` 상태에서만 인정한다.
- `0x34 KEY_COMMIT(0)`은 Jetson의 `WAIT_COMMIT` 상태에서만 새 키 전환
  절차로 인정한다.
- `0x35 COMMIT_ACK(0)`은 ZYBO의 `WAIT_COMMIT_ACK` 상태에서만 인정한다.
- 같은 `0x32 KEY_UPDATE(R)`를 다시 받으면 `0x33 READY(0)`를 다시 보낸다.
- 키 전환 후 `0x34 KEY_COMMIT(0)`을 다시 받으면 `0x35`만 다시 보내고
  키를 두 번 전환하지 않는다.
- RUN 상태에서 같은 `0x36 KEY_CONFIRM`이 다시 오고 TAG와 CHALLENGE가 모두
  유효하면 `0x37`을 다시 암호화해 보내되 세션/로그를 다시 시작하지 않는다.
- 관리 응답 큐는 Face ID보다 우선 처리한다.
- 보낼 관리 응답이나 Face ID가 없으면 `0x31 POLL`을 보낸다.

## 8. 애플리케이션 payload

### 8.1 Jetson → ZYBO: `0x01` Face ID

복호화 전에는 AES ciphertext이며, 복호화 후 16바이트 배치는 다음과 같다.

```text
Byte 0    : bit7 인증 결과(1=인가, 0=비인가)
Byte 1..15: 사용자 ID ASCII, 남는 바이트는 00 패딩
```

인가된 사용자 `jjm` 예시:

```text
80 6A 6A 6D 00 00 00 00 00 00 00 00 00 00 00 00
```

- 사용자 ID는 최대 15바이트 ASCII다.
- `session_ready=True`가 되기 전에는 Face ID를 전송하지 않는다.
- 실제 얼굴 인식 모델은 `jetson_main.py`의 `get_face_id()`를 교체하거나,
  인식 성공 시 `queue_face_id(user_id, authorized)`를 호출하여 연결한다.

### 8.2 ZYBO → Jetson: `0x06` 출입문 명령

복호화 후 payload:

```text
Byte 0    : 00=IDLE, 01=OPEN, 02=CLOSE
Byte 1..15: 전부 00
```

- 알 수 없는 명령값은 폐기한다.
- 같은 명령이 반복되면 서보를 불필요하게 다시 동작시키지 않아도 된다.
- 현재 예제는 Jetson BOARD 번호 32번 핀에서 SG90 소프트웨어 PWM을 사용한다.

## 9. 수신 처리 순서

```python
if len(frame) != 48:
    drop()
elif frame[0:2] != b"\xA5\x5A":
    drop()
else:
    packet_type = frame[2]

    if packet_type in (0x32, 0x34):
        # AES 복호화를 하지 않는다.
        payload = parse_clear_frame(frame, packet_type)
        # 0x32는 R, 0x34는 16바이트 0이다.
        handle_management(packet_type, payload)

    elif packet_type in (0x06, 0x36):
        # 새로 적용한 현재 session key로 TAG 검증 + AES-GCM 복호화
        payload = rx_codec.decrypt_frame(frame, packet_type)
        if packet_type == 0x36:
            verify_challenge_and_queue_encrypted_response(payload)
        else:
            handle_door_command(payload)

    else:
        drop()
```

송신 시에는 다음 기준을 적용한다.

- `0x31`, `0x33`, `0x35`: `build_clear_frame()` 사용
- `0x01`: 현재 session key의 `encrypt_frame()` 사용
- `0x37`: 새 세션키로 RESPONSE를 `encrypt_frame()`하여 사용

## 10. 시작·재시작 동작

- 별도 스위치를 누르지 않는다. Jetson은 실행 후 평문 POLL을 자동 전송한다.
- Jetson이 처음 연결되지 않아도 PC+ZYBO+Basys는 정상 동작한다.
- Jetson이 나중에 시작되면 ZYBO가 준비한 현재 KEY_UPDATE를 받고 별도
  핸드셰이크로 합류한다.
- Jetson은 PC+Basys가 이미 시작한 현재 30초 구간 중간에 합류할 수 있으므로
  첫 Jetson 세션의 실제 남은 시간은 30초보다 짧을 수 있다.
- Jetson 프로그램만 중간에 재시작하면 평문 POLL을 계속 보내고 다음
  KEY_UPDATE에서 다시 동기화한다. 즉시 재동기화가 필요하면 ZYBO도 재시작한다.
- 새 R이 오면 애플리케이션 송수신을 잠시 중지하고 핸드셰이크 완료 후 재개한다.

## 11. 오류 처리

- MAGIC, LENGTH 또는 평문 관리 프레임의 0 예약 영역이 틀리면 폐기한다.
- AES 보호 프레임의 IV prefix가 TYPE/방향과 다르면 폐기한다.
- AES-GCM TAG 검증에 실패하면 payload를 사용하지 않는다.
- `0x34` payload가 16바이트 `00`이 아니면 폐기한다.
- `0x36` 복호화 결과가 예상 CHALLENGE와 다르면 폐기한다.
- `0x37` 복호화 결과가 예상 RESPONSE와 다르면 ZYBO는 RUN으로 전환하지 않는다.
- zero-payload READY/COMMIT_ACK는 해당 TYPE을 기다리는 상태가 아니면 무시한다.
- `session_ready=False`에서는 Face ID를 전송하거나 출입문 명령을 실행하지 않는다.
- 현재 별도의 ERROR TYPE 응답은 정의되어 있지 않으며 오류는 로그로 남기고
  다음 POLL/재전송을 기다린다.

## 12. 제공 파일과 실행

Jetson에 같은 폴더로 복사할 파일:

```text
jetson_main.py
aes_gcm_128.py
```

필수 Python 모듈:

```bash
python3 -m pip install spidev
```

서보를 사용할 경우 Jetson.GPIO도 필요하다.

하드웨어 없이 암호·프레임·핸드셰이크 자체 테스트:

```bash
python3 jetson_main.py --self-test
```

SPI 통신만 확인하고 Jetson 서보를 사용하지 않는 실행:

```bash
python3 jetson_main.py --no-servo
```

SPI와 Jetson 연결 SG90 서보를 함께 실행:

```bash
python3 jetson_main.py
```

정상 자체 테스트 출력:

```text
PASS: Jetson clear-R handshake + AES-GCM key-confirm/application self-test
```

## 13. Jetson 담당자 필수 체크리스트

- [ ] SPI Mode 0, MSB first, 10 MHz로 설정했다.
- [ ] 모든 `xfer2()`가 정확히 48바이트다.
- [ ] TYPE을 AES 복호화 전에 먼저 읽는다.
- [ ] `0x31`~`0x35`만 평문 관리 프레임으로 처리한다.
- [ ] `0x32`의 R을 16바이트 그대로 저장한다.
- [ ] `0x31`, `0x33`, `0x34`, `0x35` payload를 16바이트 `00`으로 처리한다.
- [ ] `MASTER_KEY XOR R`로 정확히 16바이트 세션키를 만든다.
- [ ] COMMIT_ACK 전송 완료 후에만 AES key를 바꾼다.
- [ ] `0x36`의 TAG와 CHALLENGE를 새 세션키로 검증한다.
- [ ] `0x37`의 RESPONSE를 새 세션키로 AES-GCM 암호화한다.
- [ ] CONFIRM_ACK 전송 완료 후에만 애플리케이션 통신을 시작한다.
- [ ] `0x01`, `0x06`, `0x36`, `0x37`에서 AES-GCM TAG를 생성/검증한다.
- [ ] 관리 메시지 재전송과 중복 수신을 허용한다.
- [ ] Face ID payload를 정확히 16바이트로 만든다.
- [ ] 세션 미완료 상태에서는 Face ID/서보 명령을 사용하지 않는다.
