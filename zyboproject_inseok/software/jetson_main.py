"""Jetson Nano secure SPI endpoint for the AIGIS ZYBO controller.

The Jetson is the SPI master. Every transaction is one complete 48-byte
frame. R is clear in KEY_UPDATE; KEY_CONFIRM/CONFIRM_ACK and application
payloads use AES-128-GCM with MASTER_KEY XOR R.
"""

from __future__ import annotations

import argparse
import random
import time
from collections import deque
from dataclasses import dataclass
from typing import Callable

try:
    import spidev
except ImportError:  # Allows --self-test on a development PC.
    spidev = None

try:
    import Jetson.GPIO as GPIO
except ImportError:  # Allows --self-test on a development PC.
    GPIO = None

from aes_gcm_128 import (
    AuthenticationError,
    FRAME_MAGIC,
    FRAME_SIZE,
    SecureFrameCodec,
    build_clear_frame,
    parse_clear_frame,
)


SPI_BUS = 0
SPI_DEVICE = 0
SPI_SPEED_HZ = 10_000_000
SPI_POLL_INTERVAL_SEC = 0.1
FACE_ID_INTERVAL_SEC = 5.0

MASTER_KEY = bytes.fromhex("6C8E9CF570932BD5A3F104D7B89E62C1")
JETSON_APP_TX_IV_PREFIX = bytes.fromhex("01000001")
ZYBO_APP_TX_IV_PREFIX = bytes.fromhex("06000001")
ZYBO_CONFIRM_TX_IV_PREFIX = bytes.fromhex("36000001")
JETSON_CONFIRM_TX_IV_PREFIX = bytes.fromhex("37000001")

CHALLENGE_CONST = bytes.fromhex("5A5A5A5A5A5A5A5AA5A5A5A5A5A5A5A5")
RESPONSE_CONST = bytes.fromhex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")

TYPE_FACE_ID = 0x01
TYPE_DOOR_COMMAND = 0x06
TYPE_POLL = 0x31
TYPE_KEY_UPDATE = 0x32
TYPE_READY = 0x33
TYPE_KEY_COMMIT = 0x34
TYPE_COMMIT_ACK = 0x35
TYPE_KEY_CONFIRM = 0x36
TYPE_CONFIRM_ACK = 0x37

CMD_IDLE = 0x00
CMD_OPEN = 0x01
CMD_CLOSE = 0x02

USER_IDS = ("jeongmook", "ara", "dongwoo", "seongmin", None)


def xor_128(left: bytes, right: bytes) -> bytes:
    if len(left) != 16 or len(right) != 16:
        raise ValueError("XOR operands must both be 16 bytes")
    return bytes(a ^ b for a, b in zip(left, right))


def make_face_payload(user_id: str, authorized: bool = True) -> bytes:
    """Build the 16-byte Face-ID payload expected by the ZYBO RTL."""
    encoded = user_id.encode("ascii", errors="strict")
    if len(encoded) > 15:
        raise ValueError("Face-ID user name must fit in 15 ASCII bytes")
    auth = 0x80 if authorized else 0x00
    return bytes((auth,)) + encoded.ljust(15, b"\x00")


@dataclass
class OutboundPacket:
    packet_type: int
    payload: bytes
    codec: SecureFrameCodec
    after_send: str | None = None


class SecureJetsonProtocol:
    """State machine for the Jetson side of the secure ZYBO link."""

    def __init__(self, logger: Callable[[str], None] = print) -> None:
        self.log = logger
        self.tx_codec = SecureFrameCodec(MASTER_KEY, JETSON_APP_TX_IV_PREFIX)
        self.rx_codec = SecureFrameCodec(MASTER_KEY, bytes(4))
        self.confirm_tx_codec = SecureFrameCodec(
            MASTER_KEY, JETSON_CONFIRM_TX_IV_PREFIX
        )
        self.previous_tx_codec: SecureFrameCodec | None = None
        self.previous_rx_codec: SecureFrameCodec | None = None
        self.pending_tx_codec: SecureFrameCodec | None = None
        self.pending_rx_codec: SecureFrameCodec | None = None
        self.pending_confirm_tx_codec: SecureFrameCodec | None = None

        self.pending_random: bytes | None = None
        self.current_random: bytes | None = None
        self.session_ready = False
        self.state = "WAIT_KEY_UPDATE"

        self.management_queue: deque[OutboundPacket] = deque(maxlen=16)
        self.face_queue: deque[bytes] = deque(maxlen=16)
        self.last_door_command: int | None = None

    def queue_face_id(self, user_id: str, authorized: bool = True) -> None:
        payload = make_face_payload(user_id, authorized)
        if len(self.face_queue) == self.face_queue.maxlen:
            self.face_queue.popleft()
        self.face_queue.append(payload)

    def _queue_management(
        self,
        packet_type: int,
        payload: bytes,
        codec: SecureFrameCodec,
        after_send: str | None = None,
    ) -> None:
        # A retransmission replaces an already queued identical response.
        for queued in self.management_queue:
            if queued.packet_type == packet_type and queued.payload == payload:
                return
        self.management_queue.append(
            OutboundPacket(packet_type, payload, codec, after_send)
        )

    def next_packet(self) -> OutboundPacket:
        if self.management_queue:
            return self.management_queue.popleft()
        if self.session_ready and self.face_queue:
            return OutboundPacket(
                TYPE_FACE_ID, self.face_queue.popleft(), self.tx_codec
            )
        return OutboundPacket(TYPE_POLL, bytes(16), self.tx_codec)

    @staticmethod
    def encode_packet(packet: OutboundPacket) -> bytes:
        if packet.packet_type in (
            TYPE_POLL, TYPE_READY, TYPE_COMMIT_ACK
        ):
            return build_clear_frame(packet.packet_type, packet.payload)
        return packet.codec.encrypt_frame(packet.packet_type, packet.payload)

    def _switch_to_pending_key(self) -> None:
        if (self.pending_tx_codec is None or self.pending_rx_codec is None or
                self.pending_confirm_tx_codec is None):
            raise RuntimeError("COMMIT received without a pending session key")
        self.previous_tx_codec = self.tx_codec
        self.previous_rx_codec = self.rx_codec
        self.tx_codec = self.pending_tx_codec
        self.rx_codec = self.pending_rx_codec
        self.confirm_tx_codec = self.pending_confirm_tx_codec
        self.state = "WAIT_CONFIRM"
        self.log("[REKEY] COMMIT_ACK 전송 완료 - 새 세션키로 전환")

    def _mark_session_ready(self) -> None:
        self.current_random = self.pending_random
        self.session_ready = True
        self.state = "RUN"
        random_hex = self.current_random.hex().upper() if self.current_random else ""
        self.log(f"[REKEY 완료] Jetson 세션 통신 시작 | R={random_hex}")

    def _decode_received(self, frame: bytes) -> tuple[int, bytes, bool] | None:
        if len(frame) != FRAME_SIZE or frame[:2] != FRAME_MAGIC:
            return None
        packet_type = frame[2]
        if packet_type in (TYPE_KEY_UPDATE, TYPE_KEY_COMMIT):
            try:
                return packet_type, parse_clear_frame(frame, packet_type), False
            except AuthenticationError as error:
                self.log(f"[프레임 폐기] 평문 핸드셰이크 오류: {error}")
                return None
        if packet_type == TYPE_KEY_CONFIRM:
            expected_prefix = ZYBO_CONFIRM_TX_IV_PREFIX
        elif packet_type == TYPE_DOOR_COMMAND:
            expected_prefix = ZYBO_APP_TX_IV_PREFIX
        else:
            self.log(f"[프레임 폐기] 지원하지 않는 ZYBO TYPE: 0x{packet_type:02X}")
            return None

        if frame[4:8] != expected_prefix:
            self.log(f"[보안 폐기] TYPE 0x{packet_type:02X} IV prefix 불일치")
            return None

        candidates: list[tuple[SecureFrameCodec, bool]] = [(self.rx_codec, False)]
        # 0x36 must prove possession of the newly committed key.  Never accept
        # it with the previous key.  The previous key remains only for an
        # application frame already in flight during the key transition.
        if packet_type != TYPE_KEY_CONFIRM and self.previous_rx_codec is not None:
            candidates.append((self.previous_rx_codec, True))

        last_error: AuthenticationError | None = None
        seen_keys: set[bytes] = set()
        for codec, is_previous in candidates:
            if codec.key in seen_keys:
                continue
            seen_keys.add(codec.key)
            try:
                payload = codec.decrypt_frame(frame, packet_type)
                return packet_type, payload, is_previous
            except AuthenticationError as error:
                last_error = error

        self.log(f"[보안 폐기] AES-GCM 인증 실패: {last_error}")
        return None

    def _handle_management(
        self, packet_type: int, payload: bytes, decoded_with_previous: bool
    ) -> None:
        if packet_type == TYPE_KEY_UPDATE:
            is_new_update = payload != self.pending_random or self.state == "RUN"
            self.session_ready = False
            self.pending_random = payload
            pending_key = xor_128(MASTER_KEY, payload)
            self.pending_tx_codec = SecureFrameCodec(
                pending_key, JETSON_APP_TX_IV_PREFIX
            )
            self.pending_rx_codec = SecureFrameCodec(pending_key, bytes(4))
            self.pending_confirm_tx_codec = SecureFrameCodec(
                pending_key, JETSON_CONFIRM_TX_IV_PREFIX
            )
            self.state = "WAIT_COMMIT"
            self._queue_management(TYPE_READY, bytes(16), self.tx_codec)
            if is_new_update:
                self.log(f"[REKEY 시작] ZYBO 난수 수신: {payload.hex().upper()}")
                self.log("[REKEY] READY 평문 전송 대기")
            return

        if packet_type == TYPE_KEY_COMMIT:
            if payload != bytes(16) or self.pending_random is None:
                self.log("[프레임 폐기] KEY_COMMIT payload는 16바이트 0이어야 함")
                return

            if self.state in ("WAIT_CONFIRM", "RUN"):
                # ZYBO가 ACK를 놓친 경우 평문 ACK만 다시 보낸다.
                self._queue_management(
                    TYPE_COMMIT_ACK, bytes(16), self.tx_codec
                )
                return

            if self.state == "WAIT_COMMIT":
                self._queue_management(
                    TYPE_COMMIT_ACK,
                    bytes(16),
                    self.tx_codec,
                    after_send="SWITCH_KEY",
                )
                self.log("[REKEY] KEY_COMMIT 수신 - COMMIT_ACK 전송 대기")
            return

        if packet_type == TYPE_KEY_CONFIRM:
            if self.pending_random is None:
                self.log("[보안 폐기] R 없이 KEY_CONFIRM 수신")
                return
            expected_challenge = xor_128(self.pending_random, CHALLENGE_CONST)
            if payload != expected_challenge:
                self.log("[보안 폐기] KEY_CONFIRM CHALLENGE 불일치")
                return
            response = xor_128(payload, RESPONSE_CONST)
            already_running = self.state == "RUN"
            self._queue_management(
                TYPE_CONFIRM_ACK,
                response,
                self.confirm_tx_codec,
                after_send=None if already_running else "SESSION_READY",
            )
            self.log(
                "[REKEY] 새 키로 KEY_CONFIRM 복호화 성공 "
                "- 암호화 CONFIRM_ACK 전송 대기"
            )

    def complete_transfer(
        self, sent_packet: OutboundPacket, received_frame: bytes
    ) -> int | None:
        """Finish one full-duplex transfer and return a new door command."""
        # The MISO frame was prepared before ZYBO received this MOSI frame.
        # Apply the post-send action first, then allow the previous receive key
        # to authenticate a simultaneously returned old-key management frame.
        if sent_packet.after_send == "SWITCH_KEY":
            self._switch_to_pending_key()
        elif sent_packet.after_send == "SESSION_READY":
            self._mark_session_ready()

        decoded = self._decode_received(received_frame)
        if decoded is None:
            return None

        packet_type, payload, decoded_with_previous = decoded
        if packet_type in (TYPE_KEY_UPDATE, TYPE_KEY_COMMIT, TYPE_KEY_CONFIRM):
            self._handle_management(packet_type, payload, decoded_with_previous)
            return None

        if packet_type != TYPE_DOOR_COMMAND or not self.session_ready:
            return None

        command = payload[0]
        if command not in (CMD_IDLE, CMD_OPEN, CMD_CLOSE):
            self.log(f"[보안 폐기] 알 수 없는 출입문 명령: 0x{command:02X}")
            return None
        if command == self.last_door_command:
            return None
        self.last_door_command = command
        return command

    def exchange(self, spi_device) -> int | None:
        packet = self.next_packet()
        tx_frame = self.encode_packet(packet)
        if len(tx_frame) != FRAME_SIZE:
            raise RuntimeError("Secure SPI frame must be exactly 48 bytes")
        rx_frame = bytes(spi_device.xfer2(list(tx_frame)))
        if len(rx_frame) != FRAME_SIZE:
            raise RuntimeError("SPI transfer did not return exactly 48 bytes")
        return self.complete_transfer(packet, rx_frame)


class ServoController:
    """Software-PWM controller for the Jetson-connected SG90 servo."""

    SERVO_PIN = 32
    PWM_PERIOD_SEC = 0.020
    MIN_PULSE_SEC = 0.0005
    MAX_PULSE_SEC = 0.0025
    MOVE_DURATION_SEC = 0.3

    def __init__(self, open_angle: int = 90, close_angle: int = 0) -> None:
        if GPIO is None:
            raise RuntimeError("Jetson.GPIO is not installed")
        self.open_angle = open_angle
        self.close_angle = close_angle
        self.current_state = "CLOSED"

        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BOARD)
        GPIO.setup(self.SERVO_PIN, GPIO.OUT, initial=GPIO.LOW)
        print("[SERVO] SG90 소프트웨어 PWM 준비 완료")
        self.move_to_angle(close_angle)

    @classmethod
    def angle_to_pulse(cls, angle: int) -> float:
        angle = max(0, min(180, angle))
        pulse_range = cls.MAX_PULSE_SEC - cls.MIN_PULSE_SEC
        return cls.MIN_PULSE_SEC + (angle / 180.0) * pulse_range

    def move_to_angle(self, angle: int) -> None:
        pulse_width = self.angle_to_pulse(angle)
        end_time = time.perf_counter() + self.MOVE_DURATION_SEC
        while time.perf_counter() < end_time:
            cycle_start = time.perf_counter()
            GPIO.output(self.SERVO_PIN, GPIO.HIGH)
            time.sleep(pulse_width)
            GPIO.output(self.SERVO_PIN, GPIO.LOW)
            remaining = self.PWM_PERIOD_SEC - (time.perf_counter() - cycle_start)
            if remaining > 0:
                time.sleep(remaining)
        GPIO.output(self.SERVO_PIN, GPIO.LOW)

    def apply_command(self, command: int) -> None:
        if command == CMD_OPEN and self.current_state != "OPEN":
            print("[DOOR] 문을 엽니다.")
            self.move_to_angle(self.open_angle)
            self.current_state = "OPEN"
            print("[DOOR] 문 열림 완료")
        elif command == CMD_CLOSE and self.current_state != "CLOSED":
            print("[DOOR] 문을 닫습니다.")
            self.move_to_angle(self.close_angle)
            self.current_state = "CLOSED"
            print("[DOOR] 문 닫힘 완료")

    def cleanup(self) -> None:
        GPIO.output(self.SERVO_PIN, GPIO.LOW)
        GPIO.cleanup()
        print("[SERVO] GPIO 정리 완료")


def get_face_id() -> str | None:
    """Return a test Face-ID event; replace this with the real recognition model."""
    return random.choice(USER_IDS)


def configure_spi():
    if spidev is None:
        raise RuntimeError("spidev is not installed")
    spi = spidev.SpiDev()
    spi.open(SPI_BUS, SPI_DEVICE)
    spi.max_speed_hz = SPI_SPEED_HZ
    spi.mode = 0
    spi.bits_per_word = 8
    spi.lsbfirst = False
    return spi


def run(no_servo: bool = False) -> None:
    spi = None
    servo = None
    try:
        spi = configure_spi()
        if not no_servo:
            servo = ServoController(open_angle=90, close_angle=0)

        protocol = SecureJetsonProtocol()
        print("\n[SYSTEM] ZYBO-Jetson AES-128-GCM 보안 SPI 시작")
        print("[SYSTEM] 48바이트 SPI Mode 0, 10MHz, 100ms 폴링")
        print("[SYSTEM] ZYBO의 KEY_UPDATE 및 세션 확정을 기다립니다.")
        print("[SYSTEM] Ctrl+C: 종료\n")

        last_face_id_time = time.monotonic()
        while True:
            now = time.monotonic()
            if now - last_face_id_time >= FACE_ID_INTERVAL_SEC:
                last_face_id_time = now
                user_id = get_face_id()
                if user_id is not None:
                    protocol.queue_face_id(user_id, authorized=True)
                    print(f"[Face ID] 인식 성공: {user_id} (보안 전송 대기)")

            command = protocol.exchange(spi)
            if command is not None:
                command_name = {
                    CMD_IDLE: "IDLE",
                    CMD_OPEN: "OPEN",
                    CMD_CLOSE: "CLOSE",
                }[command]
                print(f"[SPI 수신] 인증된 명령: 0x{command:02X} ({command_name})")
                if servo is not None:
                    servo.apply_command(command)

            time.sleep(SPI_POLL_INTERVAL_SEC)

    except KeyboardInterrupt:
        print("\n[SYSTEM] 프로그램을 종료합니다.")
    finally:
        if spi is not None:
            spi.close()
        if servo is not None:
            servo.cleanup()


def self_test() -> None:
    logs: list[str] = []
    protocol = SecureJetsonProtocol(logs.append)
    random_value = bytes.fromhex("00112233445566778899AABBCCDDEEFF")
    session_key = xor_128(MASTER_KEY, random_value)
    zybo_session = SecureFrameCodec(session_key, ZYBO_APP_TX_IV_PREFIX)
    zybo_confirm = SecureFrameCodec(session_key, ZYBO_CONFIRM_TX_IV_PREFIX)

    poll = protocol.next_packet()
    assert poll.packet_type == TYPE_POLL
    assert parse_clear_frame(protocol.encode_packet(poll), TYPE_POLL) == bytes(16)

    update = build_clear_frame(TYPE_KEY_UPDATE, random_value)
    protocol.complete_transfer(poll, update)
    ready = protocol.next_packet()
    assert ready.packet_type == TYPE_READY
    assert parse_clear_frame(protocol.encode_packet(ready), TYPE_READY) == bytes(16)

    commit = build_clear_frame(TYPE_KEY_COMMIT, bytes(16))
    protocol.complete_transfer(ready, commit)
    commit_ack = protocol.next_packet()
    assert commit_ack.packet_type == TYPE_COMMIT_ACK
    assert parse_clear_frame(
        protocol.encode_packet(commit_ack), TYPE_COMMIT_ACK
    ) == bytes(16)
    protocol.complete_transfer(commit_ack, bytes(FRAME_SIZE))
    assert protocol.state == "WAIT_CONFIRM"

    new_poll = protocol.next_packet()
    assert parse_clear_frame(protocol.encode_packet(new_poll), TYPE_POLL) == bytes(16)
    challenge = xor_128(random_value, CHALLENGE_CONST)
    confirm = zybo_confirm.encrypt_frame(TYPE_KEY_CONFIRM, challenge)
    protocol.complete_transfer(new_poll, confirm)
    confirm_ack = protocol.next_packet()
    assert confirm_ack.packet_type == TYPE_CONFIRM_ACK
    confirm_ack_frame = protocol.encode_packet(confirm_ack)
    assert confirm_ack_frame[4:8] == JETSON_CONFIRM_TX_IV_PREFIX
    response = SecureFrameCodec(session_key, bytes(4)).decrypt_frame(
        confirm_ack_frame, TYPE_CONFIRM_ACK
    )
    assert response == xor_128(challenge, RESPONSE_CONST)
    protocol.complete_transfer(confirm_ack, bytes(FRAME_SIZE))
    assert protocol.session_ready

    protocol.queue_face_id("jjm")
    face = protocol.next_packet()
    face_plain = SecureFrameCodec(session_key, bytes(4)).decrypt_frame(
        protocol.encode_packet(face), TYPE_FACE_ID
    )
    assert face_plain == bytes.fromhex(
        "806A6A6D000000000000000000000000"
    )

    door = zybo_session.encrypt_frame(
        TYPE_DOOR_COMMAND, bytes((CMD_OPEN,)) + bytes(15)
    )
    assert protocol.complete_transfer(face, door) == CMD_OPEN
    print("PASS: Jetson clear-R handshake + AES-GCM key-confirm/application self-test")


def main() -> None:
    parser = argparse.ArgumentParser(description="AIGIS secure Jetson SPI endpoint")
    parser.add_argument(
        "--no-servo",
        action="store_true",
        help="run secure SPI/handshake without Jetson GPIO servo control",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="test crypto and handshake without Jetson hardware",
    )
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        run(no_servo=args.no_servo)


if __name__ == "__main__":
    main()
