import socket
import struct
import threading
import time
import os
import json
import base64
from typing import Optional, Dict, Any
from queue import Empty, Queue
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad

class TCPFaceClient:
    def __init__(self, host: str, port: int, master_key: bytes):
        self.host = host
        self.port = port
        self.master_key = master_key
        
        self.session_key = None
        self.current_R = None
        self._pending_R = None
        
        self._running = False
        self._thread: Optional[threading.Thread] = None
        
        self.event_queue = Queue()
        self._pending_events = []
        self.latest_frame = None

    def update_master_key(self, new_key: bytes) -> None:
        self.master_key = new_key

    def update_random(self, new_R: bytes) -> None:
        self._pending_R = new_R
        
    def close(self):
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
            
    def start(self):
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=1.0)
            
    def get_latest_event(self) -> Optional[Dict[str, Any]]:
        event = None
        while not self.event_queue.empty():
            event = self.event_queue.get()
        return event

    def get_matching_event(
        self,
        user_id: str,
        authorized: bool,
        max_age_seconds: float = 5.0,
    ) -> Optional[Dict[str, Any]]:
        """Return only a fresh TCP result matching the UART identity result.

        TCP and UART reach the UI through independent transports, so their
        arrival order is not guaranteed. Unmatched fresh events are retained
        briefly instead of being consumed as another user's visualization.
        """
        while True:
            try:
                self._pending_events.append(self.event_queue.get_nowait())
            except Empty:
                break

        now = time.monotonic()
        self._pending_events = [
            event
            for event in self._pending_events
            if now - float(event.get("_received_monotonic", now)) <= max_age_seconds
        ]
        expected_id = str(user_id or "")
        expected_authorized = bool(authorized)
        for index in range(len(self._pending_events) - 1, -1, -1):
            event = self._pending_events[index]
            if (
                bool(event.get("is_authorized", False)) == expected_authorized
                and str(event.get("user_id", "") or "") == expected_id
            ):
                matched = self._pending_events.pop(index)
                matched.pop("_received_monotonic", None)
                return matched
        return None

    def read(self):
        return self.latest_frame

    def _recvall(self, sock, count):
        buf = b''
        while count:
            newbuf = sock.recv(count)
            if not newbuf:
                return None
            buf += newbuf
            count -= len(newbuf)
        return buf

    def _send_frame(self, sock, pkt_type, payload):
        magic = b'\xA5\x5A'
        header = struct.pack("<2sBL", magic, pkt_type, len(payload))
        sock.sendall(header + payload)

    def _recv_frame(self, sock):
        header = self._recvall(sock, 7)
        if not header:
            return None, None
        magic, pkt_type, length = struct.unpack("<2sBL", header)
        if magic != b'\xA5\x5A':
            return None, None
        payload = self._recvall(sock, length) if length > 0 else b''
        return pkt_type, payload

    def _run(self):
        while self._running:
            client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            client_socket.settimeout(2.0)
            try:
                client_socket.connect((self.host, self.port))
                print(f"[TCPFaceClient] Connected to {self.host}:{self.port}")
            except Exception as e:
                print(f"[TCPFaceClient] Connection failed: {e}")
                client_socket.close()
                time.sleep(1.0)
                continue

            print("[TCPFaceClient] UART 메인 난수(R) 수신 대기 중...")
            while self._running and self.current_R is None and self._pending_R is None:
                time.sleep(0.1)
                
            if not self._running:
                client_socket.close()
                break
                
            if self._pending_R:
                self.current_R = self._pending_R
                self._pending_R = None

            print("[TCPFaceClient] 핸드셰이크 시작...")
            self._send_frame(client_socket, 0x32, self.current_R)
            
            handshake_done = False
            
            client_socket.settimeout(1.0)
            while self._running:
                if not handshake_done:
                    try:
                        pkt_type, payload = self._recv_frame(client_socket)
                        if pkt_type is None:
                            continue
                        if pkt_type == 0x33:
                            self._send_frame(client_socket, 0x34, b'\x00' * 16)
                        elif pkt_type == 0x35:
                            self.session_key = bytes(a ^ b for a, b in zip(self.master_key, self.current_R))
                            challenge = bytes(a ^ b for a, b in zip(self.current_R, bytes.fromhex("5A5A5A5A5A5A5A5AA5A5A5A5A5A5A5A5")))
                            iv = b'\x36\x00\x00\x01' + b'\x00' * 8
                            cipher = AES.new(self.session_key, AES.MODE_GCM, nonce=iv)
                            ciphertext, tag = cipher.encrypt_and_digest(challenge)
                            self._send_frame(client_socket, 0x36, iv + ciphertext + tag)
                        elif pkt_type == 0x37:
                            print("[TCPFaceClient] Handshake complete!")
                            handshake_done = True
                    except socket.timeout:
                        pass
                    except Exception as e:
                        print(f"[TCPFaceClient] Handshake error: {e}")
                        break
                else:
                    if self._pending_R is not None:
                        print(f"[TCPFaceClient] UART 난수(R={self._pending_R.hex().upper()}) 수신, 세션키 갱신 요청...")
                        self.current_R = self._pending_R
                        self._pending_R = None
                        self._send_frame(client_socket, 0x32, self.current_R)
                        handshake_done = False
                        continue
                        
                    try:
                        pkt_type, payload = self._recv_frame(client_socket)
                        if pkt_type is None:
                            continue
                        
                        if pkt_type == 0x40 and self.session_key:
                            iv = payload[:12]
                            tag = payload[12:28]
                            ciphertext = payload[28:]
                            cipher = AES.new(self.session_key, AES.MODE_GCM, nonce=iv)
                            try:
                                json_bytes = cipher.decrypt_and_verify(ciphertext, tag)
                                json_str = json_bytes.decode('utf-8')
                                event_dict = json.loads(json_str)
                                event_dict["_received_monotonic"] = time.monotonic()
                                self.event_queue.put(event_dict)
                            except Exception as de:
                                print(f"[TCPFaceClient] Decryption/JSON parse error: {de}")
                        
                        elif pkt_type == 0x41 and self.session_key:
                            iv = payload[:12]
                            tag = payload[12:28]
                            ciphertext = payload[28:]
                            cipher = AES.new(self.session_key, AES.MODE_GCM, nonce=iv)
                            try:
                                jpeg_bytes = cipher.decrypt_and_verify(ciphertext, tag)
                                import numpy as np
                                import cv2
                                np_arr = np.frombuffer(jpeg_bytes, np.uint8)
                                frame = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
                                if frame is not None:
                                    frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
                                    self.latest_frame = frame
                                else:
                                    print("[TCPFaceClient] Decoded frame is None")
                            except Exception as de:
                                print(f"[TCPFaceClient] Decryption/JPEG parse error: {de}")
                        elif pkt_type == 0x41:
                            print("[TCPFaceClient] Received 0x41 but session_key is None!")
                                
                    except socket.timeout:
                        pass
                    except Exception as e:
                        print(f"[TCPFaceClient] Receive error: {e}")
                        break

            client_socket.close()
            time.sleep(1.0)
