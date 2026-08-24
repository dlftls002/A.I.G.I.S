import serial
import time
import json
import os
import threading
import tkinter as tk
from collections import deque
from tkinter import scrolledtext

from aes_gcm_128 import (
    AuthenticationError,
    FRAME_MAGIC,
    SecureFrameCodec,
    build_clear_frame,
    parse_clear_frame,
)

# ============================================================================
# 관제실 PC (Python SW 구현) - GUI 및 Full-Duplex SPI 지원
# ============================================================================
# SERIAL_PORT = 'COM19'
SERIAL_PORT = 'COM10'
#인석이가 수정하려고 포트변경
BAUD_RATE = 115200
DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'users.json')

# This key is stored locally on all three endpoints and is never transmitted.
MASTER_KEY = bytes.fromhex('6C8E9CF570932BD5A3F104D7B89E62C1')
PC_TX_IV_PREFIX = bytes.fromhex('03000001')
TYPE_ZYBO_TO_PC = 0x02
TYPE_PC_TO_ZYBO = 0x03
TYPE_KEY_UPDATE = 0x12
TYPE_KEY_READY = 0x13
TYPE_KEY_COMMIT = 0x14
TYPE_COMMIT_ACK = 0x15
TYPE_KEY_CONFIRM = 0x16
TYPE_CONFIRM_ACK = 0x17
SECURE_FRAME_SIZE = 48

# PC -> ZYBO 명령 포맷
# [출입문] 0x10=Open, 0x20=Close, 0x00=Idle
# [랙] 하위 4비트 (제어): 0x1=Open, 0x0=Close / 상위 4비트 (랙 번호): 0x1=Rack1, 0x2=Rack2, 0x4=Rack3, 0x8=Rack4
DOOR_OPEN_CMD  = 0x10
DOOR_CLOSE_CMD = 0x20
RACK_OPEN_CMD  = 0x01
ALL_CLOSE_CMD  = 0x00
POLL_CMD       = 0x30  # 추가: 주기적 센서 상태 요청 명령
FIRE_TEMP_THRESHOLD = 20 # 화재 경보를 띄울 온도 파라미터 (원하는 온도로 수정 가능)

class ControlRoomApp:
    def __init__(self, root):
        self.root = root
        self.root.title("관제실 메인 컨트롤러 (Face ID + UI)")
        self.root.geometry("650x700")
        
        self.ser = None
        self.running = True
        self.serial_tx_lock = threading.Lock()
        self.tx_codec = SecureFrameCodec(MASTER_KEY, PC_TX_IV_PREFIX)
        self.rx_codec = SecureFrameCodec(MASTER_KEY, bytes(4))
        self.previous_tx_codec = None
        self.previous_rx_codec = None
        self.pending_tx_codec = None
        self.pending_rx_codec = None
        self.pending_random = None
        self.pending_key_active = False
        self.current_random = None
        self.session_ready = False
        self.session_started_at = None
        self.session_generation = 0
        self.queued_commands = deque(maxlen=32)
        self.rx_buffer = bytearray()
        
        self.setup_ui()
        self.connect_serial()
        
        # 시리얼 수신 스레드 시작
        self.rx_thread = threading.Thread(target=self.serial_rx_loop, daemon=True)
        self.rx_thread.start()
        
        # 센서 폴링 스레드 시작
        self.poll_thread = threading.Thread(target=self.sensor_poll_loop, daemon=True)
        self.poll_thread.start()

    def setup_ui(self):
        # 상단 컨트롤 패널
        control_frame = tk.Frame(self.root, pady=10)
        control_frame.pack(fill=tk.X)
        
        tk.Label(control_frame, text="[메인 출입문 수동 제어]", font=("Arial", 12, "bold")).pack()
        
        btn_frame = tk.Frame(control_frame)
        btn_frame.pack(pady=5)
        
        self.btn_open = tk.Button(btn_frame, text="문 열기 (OPEN)", width=15, bg="#4CAF50", fg="white", font=("Arial", 10, "bold"), command=self.cmd_door_open)
        self.btn_open.pack(side=tk.LEFT, padx=10)
        
        self.btn_close = tk.Button(btn_frame, text="문 닫기 (CLOSE)", width=15, bg="#F44336", fg="white", font=("Arial", 10, "bold"), command=self.cmd_door_close)
        self.btn_close.pack(side=tk.LEFT, padx=10)
        
        # 화재 임계 온도 설정 패널
        temp_frame = tk.Frame(self.root, pady=5)
        temp_frame.pack(fill=tk.X)
        tk.Label(temp_frame, text="화재 경보 임계 온도 (℃):", font=("Arial", 10, "bold")).pack(side=tk.LEFT, padx=5, anchor=tk.E, expand=True)
        self.temp_var = tk.IntVar(value=FIRE_TEMP_THRESHOLD)
        self.temp_spinbox = tk.Spinbox(temp_frame, from_=20, to=60, textvariable=self.temp_var, font=("Arial", 10), width=5, command=self.cmd_set_temp_threshold)
        self.temp_spinbox.pack(side=tk.LEFT, padx=5, anchor=tk.W, expand=True)
        self.temp_spinbox.bind('<Return>', lambda e: self.cmd_set_temp_threshold())
        
        # 중간 랙 제어 패널 추가
        rack_frame = tk.Frame(self.root, pady=10)
        rack_frame.pack(fill=tk.X)
        tk.Label(rack_frame, text="[랙(Rack) 수동 제어]", font=("Arial", 12, "bold")).pack()
        
        rbtn_frame1 = tk.Frame(rack_frame)
        rbtn_frame1.pack(pady=5)
        
        tk.Button(rbtn_frame1, text="1번 랙 열기", width=12, bg="#2196F3", fg="white", font=("Arial", 9, "bold"), command=lambda: self.cmd_rack_open(1)).pack(side=tk.LEFT, padx=5)
        tk.Button(rbtn_frame1, text="2번 랙 열기", width=12, bg="#2196F3", fg="white", font=("Arial", 9, "bold"), command=lambda: self.cmd_rack_open(2)).pack(side=tk.LEFT, padx=5)
        tk.Button(rbtn_frame1, text="3번 랙 열기", width=12, bg="#2196F3", fg="white", font=("Arial", 9, "bold"), command=lambda: self.cmd_rack_open(3)).pack(side=tk.LEFT, padx=5)
        tk.Button(rbtn_frame1, text="4번 랙 열기", width=12, bg="#2196F3", fg="white", font=("Arial", 9, "bold"), command=lambda: self.cmd_rack_open(4)).pack(side=tk.LEFT, padx=5)
        
        rbtn_frame2 = tk.Frame(rack_frame)
        rbtn_frame2.pack(pady=5)
        tk.Button(rbtn_frame2, text="전체 랙 열기", width=15, bg="#FF9800", fg="white", font=("Arial", 10, "bold"), command=lambda: self.cmd_rack_open(0)).pack(side=tk.LEFT, padx=10)
        tk.Button(rbtn_frame2, text="전체 랙 닫기", width=15, bg="#9E9E9E", fg="white", font=("Arial", 10, "bold"), command=self.cmd_rack_close).pack(side=tk.LEFT, padx=10)

        # 3x2 카메라 모니터링 현황판 (총 3개 유닛)
        cam_frame = tk.Frame(self.root, pady=10)
        cam_frame.pack(fill=tk.X)
        tk.Label(cam_frame, text="[카메라 비전 기반 LED 상태 감시]", font=("Arial", 12, "bold")).pack()
        
        self.cam_labels = []
        for i in range(3):
            lbl = tk.Label(cam_frame, text=f"유닛 {i+1}: 확인중...", width=25, bg="gray", fg="white", font=("Arial", 10, "bold"))
            lbl.pack(pady=2)
            self.cam_labels.append(lbl)

        # 하단 로그 패널
        log_frame = tk.Frame(self.root, padx=10, pady=10)
        log_frame.pack(fill=tk.BOTH, expand=True)
        
        tk.Label(log_frame, text="시스템 로그", font=("Arial", 10, "bold")).pack(anchor=tk.W)
        
        self.log_text = scrolledtext.ScrolledText(log_frame, state='disabled', height=15)
        self.log_text.pack(fill=tk.BOTH, expand=True)

    def log(self, message):
        self.log_text.config(state='normal')
        self.log_text.insert(tk.END, message + "\n")
        self.log_text.see(tk.END)
        self.log_text.config(state='disabled')

    def update_cam_label(self, unit_idx, state):
        if state == 0:
            self.cam_labels[unit_idx].config(text=f"유닛 {unit_idx+1}: 비활성화", bg="gray")
        elif state == 1:
            self.cam_labels[unit_idx].config(text=f"유닛 {unit_idx+1}: 정상", bg="#4CAF50")
        elif state == 2:
            self.cam_labels[unit_idx].config(text=f"유닛 {unit_idx+1}: 이상 발생! (경고)", bg="#FF9800")
        elif state == 3:
            self.cam_labels[unit_idx].config(text=f"유닛 {unit_idx+1}: 비상 사태!", bg="#F44336")

    def connect_serial(self):
        try:
            self.ser = serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=0.1)
            self.log(f"[*] UART 연결 성공: {SERIAL_PORT} @ {BAUD_RATE}bps")
        except serial.SerialException as e:
            self.log(f"[!] 시리얼 포트 오류: {e}")

    @staticmethod
    def xor_key(left, right):
        return bytes(a ^ b for a, b in zip(left, right))

    def send_secure_payload(self, packet_type, payload, codec=None, flush=False):
        if not (self.ser and self.ser.is_open) or len(payload) != 16:
            return False
        with self.serial_tx_lock:
            selected_codec = codec if codec is not None else self.tx_codec
            frame = selected_codec.encrypt_frame(packet_type, payload)
            self.ser.write(frame)
            if flush:
                self.ser.flush()
        return True

    def send_clear_payload(self, packet_type, payload, flush=False):
        """Send TYPE and the 128-bit handshake random without AES."""
        if not (self.ser and self.ser.is_open) or len(payload) != 16:
            return False
        with self.serial_tx_lock:
            self.ser.write(build_clear_frame(packet_type, payload))
            if flush:
                self.ser.flush()
        return True

    def send_secure_command(self, command, queue_if_rekey=True):
        """Encrypt one legacy command byte into the common 48-byte frame."""
        if not (self.ser and self.ser.is_open):
            return False
        if not self.session_ready:
            if queue_if_rekey:
                self.queued_commands.append(command & 0xFF)
                self.log(f"[키 교환 대기] 명령 0x{command & 0xFF:02X} 저장")
            return False
        plaintext = bytes([command & 0xFF]) + bytes(15)
        return self.send_secure_payload(TYPE_PC_TO_ZYBO, plaintext)

    def flush_queued_commands(self):
        while self.session_ready and self.queued_commands:
            command = self.queued_commands.popleft()
            self.send_secure_command(command, queue_if_rekey=False)
            self.log(f"[키 교환 완료] 저장 명령 0x{command:02X} 전송")

    def start_random_log(self):
        self.session_generation += 1
        generation = self.session_generation
        self.session_started_at = time.monotonic()
        self.log_random_tick(generation)

    def stop_random_log(self):
        self.session_generation += 1
        self.session_started_at = None

    def log_random_tick(self, generation):
        if generation != self.session_generation or not self.session_ready:
            return
        elapsed = int(time.monotonic() - self.session_started_at)
        if elapsed < 30:
            random_hex = self.current_random.hex().upper()
            self.log(f"[현재 난수] {elapsed:2d}초 / 30초 | R = {random_hex}")
            self.root.after(1000, self.log_random_tick, generation)
        else:
            self.log("[REKEY] 30초 만료 - ZYBO의 새 난수 대기")

    def handle_management_packet(self, packet_type, payload, decoded_with_previous):
        if packet_type == TYPE_KEY_UPDATE:
            if self.session_ready and payload == self.current_random:
                self.send_clear_payload(TYPE_KEY_READY, payload, flush=True)
                return
            self.session_ready = False
            self.stop_random_log()
            self.pending_random = payload
            self.pending_key_active = False
            pending_key = self.xor_key(MASTER_KEY, payload)
            self.pending_tx_codec = SecureFrameCodec(pending_key, PC_TX_IV_PREFIX)
            self.pending_rx_codec = SecureFrameCodec(pending_key, bytes(4))
            self.log(f"[REKEY 시작] 새 난수 수신: {payload.hex().upper()}")
            self.send_clear_payload(TYPE_KEY_READY, payload, flush=True)
            self.log("[REKEY] READY 평문 전송")
            return

        if packet_type == TYPE_KEY_COMMIT and self.pending_random == payload:
            if self.pending_key_active:
                self.send_clear_payload(TYPE_COMMIT_ACK, payload, flush=True)
                return

            with self.serial_tx_lock:
                self.ser.write(build_clear_frame(TYPE_COMMIT_ACK, payload))
                self.ser.flush()
                self.previous_tx_codec = self.tx_codec
                self.previous_rx_codec = self.rx_codec
                self.tx_codec = self.pending_tx_codec
                self.rx_codec = self.pending_rx_codec
                self.pending_key_active = True
            self.log("[REKEY] COMMIT_ACK 평문 전송 후 새 세션키로 전환")
            return

        if packet_type == TYPE_KEY_CONFIRM and self.pending_random == payload:
            self.send_clear_payload(TYPE_CONFIRM_ACK, payload, flush=True)
            if self.session_ready and self.current_random == payload:
                return
            self.current_random = payload
            self.session_ready = True
            self.log("[REKEY 완료] 새 세션 통신 시작")
            self.start_random_log()
            self.flush_queued_commands()

    def cmd_door_open(self):
        if self.ser and self.ser.is_open:
            self.send_secure_command(DOOR_OPEN_CMD)
            self.log(">> [수동 제어] 메인 출입문 열기 명령어 전송 (0x10)")

    def cmd_door_close(self):
        if self.ser and self.ser.is_open:
            self.send_secure_command(DOOR_CLOSE_CMD)
            self.log(">> [명령 전송] 전체 랙 및 메인 출입문 닫기: 0x00")
            
    def cmd_set_temp_threshold(self):
        global FIRE_TEMP_THRESHOLD
        try:
            val = self.temp_var.get()
            if 20 <= val <= 60:
                FIRE_TEMP_THRESHOLD = val
                # 최상위 비트(MSB)를 1로 설정하여 온도 명령임을 표시 (예: 0x80 | 40 = 0xA8)
                if self.ser and self.ser.is_open:
                    cmd = 0x80 | val
                    self.send_secure_command(cmd)
                    self.log(f">> [명령 전송] 화재 경보 임계 온도 설정: {val}℃ (명령어: 0x{cmd:02X})")
                else:
                    self.log(f"🔥 화재 경보 임계 온도가 {val}℃로 설정되었습니다. (시리얼 미연결)")
        except Exception as e:
            pass
            
    def cmd_rack_open(self, rack_num):
        if self.ser and self.ser.is_open:
            cmd = DOOR_OPEN_CMD # 기본적으로 메인 출입문도 같이 열림 상태를 유지한다고 가정
            if rack_num == 0:
                cmd |= 0x0F # 전체 랙 개방
                self.log(">> [수동 제어] 전체 랙 열기 명령어 전송 (0x1F)")
            else:
                cmd |= (1 << (rack_num - 1))
                self.log(f">> [수동 제어] {rack_num}번 랙 열기 명령어 전송 (0x{cmd:02X})")
            self.send_secure_command(cmd)

    def cmd_rack_close(self):
        if self.ser and self.ser.is_open:
            self.send_secure_command(ALL_CLOSE_CMD)
            self.log(">> [명령 전송] 전체 랙 문 닫기: 0x00")

    def sensor_poll_loop(self):
        while self.running:
            if self.ser and self.ser.is_open:
                try:
                    self.send_secure_command(POLL_CMD, queue_if_rekey=False)
                except Exception:
                    pass
            time.sleep(2.0)

    def load_user_db(self):
        if not os.path.exists(DB_PATH):
            return {}
        with open(DB_PATH, 'r', encoding='utf-8') as f:
            return json.load(f)

    def match_rack(self, user_id):
        db = self.load_user_db()
        if user_id in db:
            user_info = db[user_id]
            cmd_byte = 0x00
            
            # 상위 4비트 (출입문 제어) - DOOR_OPEN_CMD(0x10), DOOR_CLOSE_CMD(0x20)
            if user_info.get("open_entrance", False):
                cmd_byte |= DOOR_OPEN_CMD
            else:
                cmd_byte |= DOOR_CLOSE_CMD
                
            # 하위 4비트 (랙 선택 비트마스크: 1=Rack1, 2=Rack2, 4=Rack3, 8=Rack4)
            rack_bits = 0x0
            rack_ctrl = user_info.get("rack_control", {})
            for rack_name, is_open in rack_ctrl.items():
                if is_open:
                    try:
                        rack_num = int(rack_name.split("-")[1])
                        if 1 <= rack_num <= 4:
                            rack_bits |= (1 << (rack_num - 1))
                    except:
                        pass
            
            cmd_byte |= rack_bits
            return cmd_byte
        return ALL_CLOSE_CMD

    def serial_rx_loop(self):
        while self.running:
            if self.ser and self.ser.is_open:
                try:
                    if self.ser.in_waiting > 0:
                        raw = self.ser.read(self.ser.in_waiting)
                        self.rx_buffer.extend(raw)

                        while True:
                            sync_index = self.rx_buffer.find(FRAME_MAGIC)
                            if sync_index < 0:
                                # Keep a trailing A5 because it may be the first magic byte.
                                if self.rx_buffer[-1:] == FRAME_MAGIC[:1]:
                                    self.rx_buffer[:] = self.rx_buffer[-1:]
                                else:
                                    self.rx_buffer.clear()
                                break
                            if sync_index:
                                del self.rx_buffer[:sync_index]
                            if len(self.rx_buffer) < SECURE_FRAME_SIZE:
                                break

                            frame = bytes(self.rx_buffer[:SECURE_FRAME_SIZE])
                            del self.rx_buffer[:SECURE_FRAME_SIZE]
                            packet_type = frame[2]
                            decoded_with_previous = False

                            if packet_type in (
                                TYPE_KEY_UPDATE, TYPE_KEY_COMMIT,
                                TYPE_KEY_CONFIRM
                            ):
                                try:
                                    rx_data_bytes = parse_clear_frame(
                                        frame, packet_type
                                    )
                                except AuthenticationError as error:
                                    self.log(f"[프레임 폐기] 평문 핸드셰이크 오류: {error}")
                                    continue
                                self.handle_management_packet(
                                    packet_type, rx_data_bytes, False
                                )
                                continue

                            try:
                                rx_data_bytes = self.rx_codec.decrypt_frame(
                                    frame, packet_type
                                )
                            except AuthenticationError as error:
                                # Keep one old receive key during COMMIT so a
                                # retransmitted old-key COMMIT can be ACKed.
                                try:
                                    if (self.previous_rx_codec is None or
                                            packet_type != TYPE_KEY_COMMIT):
                                        raise error
                                    rx_data_bytes = self.previous_rx_codec.decrypt_frame(
                                        frame, packet_type
                                    )
                                    decoded_with_previous = True
                                except AuthenticationError:
                                    self.log(f"[보안 폐기] AES-GCM 인증 실패: {error}")
                                    continue

                            if packet_type != TYPE_ZYBO_TO_PC or not self.session_ready:
                                continue

                            # [Byte 0] 헤더 파싱
                            header = rx_data_bytes[0]
                        
                            if header == 0xBB: # 센서 데이터
                                fire_state = rx_data_bytes[1]
                                
                                t1, h1 = rx_data_bytes[2], rx_data_bytes[3]
                                t2, h2 = rx_data_bytes[4], rx_data_bytes[5]
                                t3, h3 = rx_data_bytes[6], rx_data_bytes[7]
                                t4, h4 = rx_data_bytes[8], rx_data_bytes[9]
                                
                                camera_state = rx_data_bytes[10]
                                
                                temps = [t1, t2, t3, t4]
                                hums = [h1, h2, h3, h4]
                                
                                warn_msg = ""
                                
                                # 카메라 비전 상태 업데이트
                                for i in range(3):
                                    state = (camera_state >> (i * 2)) & 0x03
                                    self.root.after(0, self.update_cam_label, i, state)
                                    if state == 2:
                                        warn_msg += f"🚨 [비전 감지] {i+1}번 유닛 이상 발생! (경고) 🚨\n"
                                    elif state == 3:
                                        warn_msg += f"🚨 [비전 감지] {i+1}번 유닛 비상 사태! 🚨\n"
                                
                                # 기존 센서 상태 업데이트
                                for i in range(4):
                                    if temps[i] >= FIRE_TEMP_THRESHOLD:
                                        warn_msg += f"🚨 [긴급] {i+1}번 랙 화재 감지! (온도: {temps[i]}℃ / 습도: {hums[i]}%) 화재 진압 서보 작동! 🚨\n"
                                        
                                if warn_msg != "":
                                    self.log(warn_msg.strip())
                            else: # Face ID 데이터
                                # ZYBO가 더 이상 MSB를 강제하지 않으므로 기존 로직 복구
                                is_auth = (header & 0x80) >> 7  # MSB 1비트: 인가(1) / 비인가(0)
                                
                                # [Byte 1~15] 유저 ID 파싱
                                user_id_raw = bytearray([b & 0x7F for b in rx_data_bytes[1:16]])
                                user_id_str = user_id_raw.decode('ascii', errors='ignore').strip('\x00').strip()
                                
                                self.log(f"\n[Face ID 감지] 유저: '{user_id_str}' (Flag: {is_auth})")
                                
                                if is_auth == 1:
                                    tx_cmd = self.match_rack(user_id_str)
                                    if tx_cmd != ALL_CLOSE_CMD:
                                        self.log(f"<< [인증 성공] 출입문/랙 개방 명령어 전송: 0x{tx_cmd:02X}")
                                        self.send_secure_command(tx_cmd)
                                    else:
                                        self.log("<< [권한 없음] 문 닫힘 유지")
                                else:
                                    self.log("<< [인증 실패] 비인가자 감지")
                                    self.send_secure_command(ALL_CLOSE_CMD)
                                    self.log("<< [자동 닫힘] 초기 상태(ALL CLOSE) 전송: 0x00")
                except Exception as e:
                    pass
            time.sleep(0.01)
                        


    def on_closing(self):
        self.running = False
        if self.ser and self.ser.is_open:
            self.ser.close()
        self.root.destroy()

if __name__ == "__main__":
    root = tk.Tk()
    app = ControlRoomApp(root)
    root.protocol("WM_DELETE_WINDOW", app.on_closing)
    root.mainloop()
