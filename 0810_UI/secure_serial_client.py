"""Threaded secure UART client for the AIGIS ZYBO controller."""

from __future__ import annotations

import random
import threading
import time
from collections import deque
from queue import Queue

import serial

from aes_gcm_128 import (
    AuthenticationError,
    FRAME_MAGIC,
    SecureFrameCodec,
    build_clear_frame,
    parse_clear_frame,
)


MASTER_KEY = bytes.fromhex("6C8E9CF570932BD5A3F104D7B89E62C1")
PC_TX_IV_PREFIX = bytes.fromhex("03000001")
TYPE_ZYBO_TO_PC = 0x02
TYPE_PC_TO_ZYBO = 0x03
TYPE_KEY_UPDATE = 0x12
TYPE_KEY_READY = 0x13
TYPE_KEY_COMMIT = 0x14
TYPE_COMMIT_ACK = 0x15
TYPE_KEY_CONFIRM = 0x16
TYPE_CONFIRM_ACK = 0x17
FRAME_SIZE = 48

DOOR_OPEN_CMD = 0x10
DOOR_CLOSE_CMD = 0x20
POLL_CMD = 0x30


PACKET_NAMES = {
    TYPE_ZYBO_TO_PC: "ZYBO_TO_PC",
    TYPE_PC_TO_ZYBO: "PC_TO_ZYBO",
    TYPE_KEY_UPDATE: "KEY_UPDATE",
    TYPE_KEY_READY: "KEY_READY",
    TYPE_KEY_COMMIT: "KEY_COMMIT",
    TYPE_COMMIT_ACK: "COMMIT_ACK",
    TYPE_KEY_CONFIRM: "KEY_CONFIRM",
    TYPE_CONFIRM_ACK: "CONFIRM_ACK",
}


class SecureSerialClient:
    """Owns UART, AES-GCM session state, polling, and decoded event delivery."""

    def __init__(
        self,
        event_queue: Queue,
        port: str = "COM10",
        baud_rate: int = 115200,
        simulate: bool = False,
    ) -> None:
        self.events = event_queue
        self.port = port
        self.baud_rate = baud_rate
        self.simulate = simulate
        self.ser: serial.Serial | None = None
        self.running = False
        self.session_ready = simulate
        self.current_random: bytes | None = None
        self.pending_random: bytes | None = None
        self.pending_key_active = False
        self.tx_codec = SecureFrameCodec(MASTER_KEY, PC_TX_IV_PREFIX)
        self.rx_codec = SecureFrameCodec(MASTER_KEY, bytes(4))
        self.pending_tx_codec: SecureFrameCodec | None = None
        self.pending_rx_codec: SecureFrameCodec | None = None
        self.previous_rx_codec: SecureFrameCodec | None = None
        self.queued_commands: deque[int] = deque(maxlen=32)
        self.rx_buffer = bytearray()
        self.tx_lock = threading.Lock()
        self.rack_mask = 0
        self._threads: list[threading.Thread] = []

    def start(self) -> None:
        if self.running:
            return
        self.running = True
        if self.simulate:
            self._emit("connection", connected=True, secure=True, mode="SIMULATION")
            self.current_random = bytes(random.getrandbits(8) for _ in range(16))
            demo_key = self._xor_key(MASTER_KEY, self.current_random)
            self.tx_codec = SecureFrameCodec(demo_key, PC_TX_IV_PREFIX)
            self.rx_codec = SecureFrameCodec(demo_key, bytes(4))
            self._emit(
                "security",
                state="REKEYING",
                master_key_hex=MASTER_KEY.hex().upper(),
                random_hex=self.current_random.hex().upper(),
                session_key_hex=demo_key.hex().upper(),
                simulated=True,
            )
            self._emit("security", state="SECURE", random_hex=self.current_random.hex().upper(), simulated=True)
            thread = threading.Thread(target=self._simulation_loop, daemon=True)
            self._threads.append(thread)
            thread.start()
            return

        try:
            self.ser = serial.Serial(self.port, self.baud_rate, timeout=0.1)
            self._emit("connection", connected=True, secure=False, mode="HARDWARE")
        except serial.SerialException as error:
            self._emit("connection", connected=False, secure=False, error=str(error), mode="HARDWARE")
            return

        for target in (self._receive_loop, self._poll_loop):
            thread = threading.Thread(target=target, daemon=True)
            self._threads.append(thread)
            thread.start()

    def stop(self) -> None:
        self.running = False
        if self.ser and self.ser.is_open:
            self.ser.close()

    def _emit(self, event_type: str, **data) -> None:
        self.events.put({"type": event_type, "timestamp": time.time(), **data})

    @staticmethod
    def _xor_key(left: bytes, right: bytes) -> bytes:
        return bytes(a ^ b for a, b in zip(left, right))

    def _send_secure_payload(self, packet_type: int, payload: bytes) -> bool:
        if len(payload) != 16:
            return False
        with self.tx_lock:
            frame = self.tx_codec.encrypt_frame(packet_type, payload)
            delivered = self.simulate or bool(self.ser and self.ser.is_open)
            if not self.simulate and delivered:
                self.ser.write(frame)
        self._emit_crypto("TX", packet_type, frame, payload, self.tx_codec.key, delivered=delivered)
        return delivered

    def _emit_crypto(
        self,
        direction: str,
        packet_type: int,
        frame: bytes,
        plaintext: bytes | None,
        key: bytes,
        *,
        delivered: bool = True,
        authenticated: bool = True,
        attack: bool = False,
        correct_key: bytes | None = None,
        master_key: bytes | None = None,
    ) -> None:
        self._emit(
            "crypto",
            direction=direction,
            packet_type=packet_type,
            packet_name=PACKET_NAMES.get(packet_type, f"TYPE_0x{packet_type:02X}"),
            master_key_hex=(master_key or MASTER_KEY).hex().upper(),
            correct_master_key_hex=MASTER_KEY.hex().upper() if attack else "",
            random_hex=self.current_random.hex().upper() if self.current_random else "",
            session_key_hex=key.hex().upper(),
            correct_key_hex=correct_key.hex().upper() if correct_key else "",
            plaintext_hex=plaintext.hex().upper() if plaintext is not None else "",
            iv_hex=frame[4:16].hex().upper(),
            counter=int.from_bytes(frame[8:16], "big"),
            ciphertext_hex=frame[16:32].hex().upper(),
            tag_hex=frame[32:48].hex().upper(),
            delivered=delivered,
            authenticated=authenticated,
            attack=attack,
            simulated=self.simulate,
        )

    def _send_clear_payload(self, packet_type: int, payload: bytes, flush: bool = False) -> bool:
        if not self.ser or not self.ser.is_open or len(payload) != 16:
            return False
        with self.tx_lock:
            self.ser.write(build_clear_frame(packet_type, payload))
            if flush:
                self.ser.flush()
        return True

    def send_command(self, command: int, queue_if_rekey: bool = True) -> bool:
        command &= 0xFF
        if self.simulate:
            delivered = self._send_secure_payload(TYPE_PC_TO_ZYBO, bytes((command,)) + bytes(15))
            self._emit("command", command=command, delivered=delivered, simulated=True)
            return delivered
        if not self.ser or not self.ser.is_open:
            self._emit("command", command=command, delivered=False, reason="UART 연결 안 됨")
            return False
        if not self.session_ready:
            if queue_if_rekey:
                self.queued_commands.append(command)
                self._emit("command", command=command, delivered=False, queued=True)
            return False
        delivered = self._send_secure_payload(TYPE_PC_TO_ZYBO, bytes((command,)) + bytes(15))
        self._emit("command", command=command, delivered=delivered)
        return delivered

    def send_invalid_key_command(self, command: int) -> bool:
        """Send one command encrypted with a deliberately corrupted master key.

        This never changes the local rack mask. The receiving AES-GCM endpoint
        should reject the tag and therefore never execute the actuator command.
        """
        command &= 0xFF
        payload = bytes((command,)) + bytes(15)
        correct_key = self.tx_codec.key
        wrong_master = bytes((MASTER_KEY[0] ^ 0x01,)) + MASTER_KEY[1:]
        wrong_key = self._xor_key(wrong_master, self.current_random) if self.current_random else wrong_master
        wrong_codec = SecureFrameCodec(wrong_key, PC_TX_IV_PREFIX, self.tx_codec.counter)
        frame = wrong_codec.encrypt_frame(TYPE_PC_TO_ZYBO, payload)
        delivered = self.simulate or bool(self.ser and self.ser.is_open and self.session_ready)
        if not self.simulate and delivered:
            with self.tx_lock:
                self.ser.write(frame)
        self._emit_crypto(
            "TX",
            TYPE_PC_TO_ZYBO,
            frame,
            payload,
            wrong_key,
            delivered=delivered,
            authenticated=False,
            attack=True,
            correct_key=correct_key,
            master_key=wrong_master,
        )
        self._emit(
            "attack_test",
            delivered=delivered,
            command=command,
            expected="GCM TAG 검증 실패 · 명령 폐기",
            simulated=self.simulate,
        )
        return delivered

    def send_invalid_key_all_open(self) -> bool:
        """Backward-compatible shortcut used by the dedicated attack button."""
        return self.send_invalid_key_command(DOOR_OPEN_CMD | 0x0F)

    def set_door(self, opened: bool) -> bool:
        return self.send_command(DOOR_OPEN_CMD if opened else DOOR_CLOSE_CMD)

    def set_rack(self, rack_number: int, opened: bool) -> bool:
        if not 1 <= rack_number <= 4:
            raise ValueError("rack_number must be 1..4")
        bit = 1 << (rack_number - 1)
        if opened:
            self.rack_mask |= bit
            # Preserve the command shape already proven on the current hardware.
            command = self.rack_mask
        else:
            self.rack_mask &= ~bit
            # Upper nibble 0 means door IDLE; lower nibble is the full rack state.
            command = self.rack_mask
        result = self.send_command(command)
        self._emit("rack_state", mask=self.rack_mask, source="command")
        return result

    def set_all_racks(self, opened: bool) -> bool:
        self.rack_mask = 0x0F if opened else 0x00
        command = (DOOR_OPEN_CMD | self.rack_mask) if opened else 0x00
        result = self.send_command(command)
        self._emit("rack_state", mask=self.rack_mask, source="command")
        return result

    def _handle_management(self, packet_type: int, payload: bytes) -> None:
        if packet_type == TYPE_KEY_UPDATE:
            if self.session_ready and payload == self.current_random:
                self._send_clear_payload(TYPE_KEY_READY, payload, flush=True)
                return
            self.session_ready = False
            self.pending_random = payload
            self.pending_key_active = False
            pending_key = self._xor_key(MASTER_KEY, payload)
            self.pending_tx_codec = SecureFrameCodec(pending_key, PC_TX_IV_PREFIX)
            self.pending_rx_codec = SecureFrameCodec(pending_key, bytes(4))
            self._emit(
                "security",
                state="REKEYING",
                master_key_hex=MASTER_KEY.hex().upper(),
                random_hex=payload.hex().upper(),
                session_key_hex=pending_key.hex().upper(),
            )
            self._send_clear_payload(TYPE_KEY_READY, payload, flush=True)
            return

        if packet_type == TYPE_KEY_COMMIT and self.pending_random == payload:
            if self.pending_key_active:
                self._send_clear_payload(TYPE_COMMIT_ACK, payload, flush=True)
                return
            if not self.ser or not self.pending_tx_codec or not self.pending_rx_codec:
                return
            with self.tx_lock:
                self.ser.write(build_clear_frame(TYPE_COMMIT_ACK, payload))
                self.ser.flush()
                self.previous_rx_codec = self.rx_codec
                self.tx_codec = self.pending_tx_codec
                self.rx_codec = self.pending_rx_codec
                self.pending_key_active = True
            return

        if packet_type == TYPE_KEY_CONFIRM and self.pending_random == payload:
            self._send_clear_payload(TYPE_CONFIRM_ACK, payload, flush=True)
            if self.session_ready and self.current_random == payload:
                return
            self.current_random = payload
            self.session_ready = True
            self._emit("security", state="SECURE", random_hex=payload.hex().upper())
            while self.session_ready and self.queued_commands:
                self.send_command(self.queued_commands.popleft(), queue_if_rekey=False)

    def _receive_loop(self) -> None:
        while self.running and self.ser and self.ser.is_open:
            try:
                waiting = self.ser.in_waiting
                if waiting:
                    self.rx_buffer.extend(self.ser.read(waiting))
                    self._consume_frames()
            except (serial.SerialException, OSError) as error:
                self._emit("connection", connected=False, secure=False, error=str(error), mode="HARDWARE")
                break
            time.sleep(0.01)

    def _consume_frames(self) -> None:
        while True:
            sync_index = self.rx_buffer.find(FRAME_MAGIC)
            if sync_index < 0:
                self.rx_buffer[:] = self.rx_buffer[-1:] if self.rx_buffer[-1:] == FRAME_MAGIC[:1] else b""
                return
            if sync_index:
                del self.rx_buffer[:sync_index]
            if len(self.rx_buffer) < FRAME_SIZE:
                return
            frame = bytes(self.rx_buffer[:FRAME_SIZE])
            del self.rx_buffer[:FRAME_SIZE]
            packet_type = frame[2]
            if packet_type in (TYPE_KEY_UPDATE, TYPE_KEY_COMMIT, TYPE_KEY_CONFIRM):
                try:
                    payload = parse_clear_frame(frame, packet_type)
                except AuthenticationError as error:
                    self._emit("security_error", message=str(error))
                    continue
                self._handle_management(packet_type, payload)
                continue

            used_codec = self.rx_codec
            try:
                payload = used_codec.decrypt_frame(frame, packet_type)
            except AuthenticationError as error:
                try:
                    if not self.previous_rx_codec or packet_type != TYPE_KEY_COMMIT:
                        raise error
                    used_codec = self.previous_rx_codec
                    payload = used_codec.decrypt_frame(frame, packet_type)
                except AuthenticationError:
                    self._emit_crypto(
                        "RX",
                        packet_type,
                        frame,
                        None,
                        self.rx_codec.key,
                        authenticated=False,
                    )
                    self._emit("security_error", message="AES-GCM 인증 실패")
                    continue
            self._emit_crypto("RX", packet_type, frame, payload, used_codec.key)
            if packet_type == TYPE_ZYBO_TO_PC and self.session_ready:
                self._decode_application_payload(payload)

    def _decode_application_payload(self, payload: bytes) -> None:
        if payload[0] == 0xBB:
            camera_byte = payload[10]
            self._emit(
                "sensor",
                fire_mask=payload[1] & 0x0F,
                temperatures=[payload[2], payload[4], payload[6], payload[8]],
                humidities=[payload[3], payload[5], payload[7], payload[9]],
                camera_states=[(camera_byte >> (index * 2)) & 0x03 for index in range(3)],
            )
            return
        authorized = bool(payload[0] & 0x80)
        user_id = bytes(value & 0x7F for value in payload[1:16]).decode("ascii", errors="ignore").strip("\x00 ")
        self._emit("face", authorized=authorized, user_id=user_id)

    def _poll_loop(self) -> None:
        while self.running:
            self.send_command(POLL_CMD, queue_if_rekey=False)
            time.sleep(2.0)

    def _simulation_loop(self) -> None:
        started = time.monotonic()
        tick = 0
        while self.running:
            tick += 1
            elapsed = time.monotonic() - started
            if tick % 2 == 1:
                self.send_command(POLL_CMD, queue_if_rekey=False)
            temperatures = [23, 22, 24, 25]
            humidities = [50, 58, 56, 62]
            camera_states = [1, 1, 1]
            if int(elapsed) % 18 >= 11:
                camera_states[2] = 3
            self._emit(
                "sensor",
                fire_mask=0x08 if temperatures[3] >= 30 else 0,
                temperatures=temperatures,
                humidities=humidities,
                camera_states=camera_states,
                simulated=True,
            )
            if tick % 8 == 0:
                self._emit(
                    "face",
                    authorized=True,
                    user_id=random.choice(["ssm", "jjm", "car", "kdw"]),
                    simulated=True,
                )
            time.sleep(2.0)
