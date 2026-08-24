import os
import socket
import select
import struct
import time
import threading
import cv2
import numpy as np
from Crypto.Cipher import AES

MASTER_KEY = bytes.fromhex("6C8E9CF570932BD5A3F104D7B89E62C1")
IV_BYTES = b'\x00' * 12

def unpad_pkcs7(padded_data: bytes) -> bytes:
    if not padded_data:
        return padded_data
    pad_len = padded_data[-1]
    if 1 <= pad_len <= 16 and padded_data[-pad_len:] == bytes([pad_len] * pad_len):
        return padded_data[:-pad_len]
    return padded_data


def decrypt_restarted_gcm_blocks(cipher_data: bytes, key: bytes) -> bytes:
    """Decrypt blocks produced with a fresh fixed-nonce GCM cipher per block.

    The existing camera protocol restarts the same GCM counter for every
    16-byte block. Creating thousands of AES objects per JPEG frame is
    equivalent to XORing every block with the same first-block keystream, so
    compute that keystream once and apply it with NumPy.
    """
    usable_length = len(cipher_data) - (len(cipher_data) % 16)
    if usable_length <= 0:
        return b""
    cipher = AES.new(key, AES.MODE_GCM, nonce=IV_BYTES)
    keystream = np.frombuffer(cipher.decrypt(bytes(16)), dtype=np.uint8)
    encrypted = np.frombuffer(cipher_data[:usable_length], dtype=np.uint8).reshape(-1, 16)
    return np.bitwise_xor(encrypted, keystream).tobytes()

class DualChannelAdapter:
    def __init__(self, stream, channel):
        self.stream = stream
        self.channel = channel
    def read(self):
        if self.channel == 'A':
            return self.stream.read_a()
        return self.stream.read_b()
    def close(self):
        self.stream.close()

class TCPCameraStream:
    def __init__(self, host='10.10.15.133', port=5000, master_key=None):
        self.host = host
        self.port = port
        self.master_key = master_key or MASTER_KEY
        self.b_master_key = self.master_key
        self.last_frame_a = None
        self.last_frame_b = None
        self.current_R = None
        self._pending_R = None
        self._running = True
        
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        
    def set_b_master_key(self, new_key: bytes):
        self.b_master_key = new_key
        
    def update_random(self, new_R: bytes) -> None:
        self._pending_R = new_R

    def get_adapter(self, channel: str):
        return DualChannelAdapter(self, channel)
        
    def read_a(self):
        return self.last_frame_a
        
    def read_b(self):
        return self.last_frame_b
        
    def close(self):
        self._running = False
        if self._thread.is_alive():
            self._thread.join(timeout=1.0)
            
    def _recvall(self, sock, count):
        buf = b''
        while count and self._running:
            try:
                newbuf = sock.recv(count)
                if not newbuf: 
                    return None
                buf += newbuf
                count -= len(newbuf)
            except socket.timeout:
                continue
            except Exception:
                return None
        return buf

    def _send_frame(self, sock, pkt_type, payload):
        magic = b'\xA5\x5A'
        header = struct.pack("<2sBL", magic, pkt_type, len(payload))
        sock.sendall(header + payload)

    def _recv_frame(self, sock):
        header = self._recvall(sock, 7)
        if not header: return None, None
        magic, pkt_type, length = struct.unpack("<2sBL", header)
        if magic != b'\xA5\x5A':
            return None, None
        payload = self._recvall(sock, length) if length > 0 else b''
        return pkt_type, payload

    def _run(self):
        client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_socket.settimeout(1.0)
        
        while self._running:
            try:
                client_socket.connect((self.host, self.port))
                print(f"[TCPCameraStream] 서버 연결 성공! ({self.host}:{self.port})")
                break
            except Exception as e:
                print(f"[TCPCameraStream] 서버 연결 실패, 재시도 중... {e}")
                time.sleep(2)
                
        if not self._running:
            client_socket.close()
            return
            
        client_socket.settimeout(0.5)
        
        # ZYBO로부터 난수 수신 대기
        print("[TCPCameraStream] UART 메인 난수(R) 수신 대기 중...")
        while self._running and self.current_R is None and self._pending_R is None:
            time.sleep(0.1)
            
        if not self._running:
            client_socket.close()
            return
            
        if self._pending_R:
            self.current_R = self._pending_R
            self._pending_R = None

        # 초기 핸드셰이크
        print("[TCPCameraStream] 핸드셰이크 시작...")
        session_key = self.master_key
        
        self._send_frame(client_socket, 0x32, self.current_R)
        
        handshake_done = False
        while self._running and not handshake_done:
            pkt_type, payload = self._recv_frame(client_socket)
            if pkt_type == 0x33:
                self._send_frame(client_socket, 0x34, b'\x00' * 16)
            elif pkt_type == 0x35:
                session_key = bytes(a ^ b for a, b in zip(self.master_key, self.current_R))
                challenge = bytes(a ^ b for a, b in zip(self.current_R, bytes.fromhex("5A5A5A5A5A5A5A5AA5A5A5A5A5A5A5A5")))
                iv = b'\x36\x00\x00\x01' + b'\x00' * 8
                cipher = AES.new(session_key, AES.MODE_GCM, nonce=iv)
                ciphertext, tag = cipher.encrypt_and_digest(challenge)
                self._send_frame(client_socket, 0x36, iv + ciphertext + tag)
            elif pkt_type == 0x37:
                print("[TCPCameraStream] 초기 핸드셰이크 완료!")
                handshake_done = True
                
        while self._running:
            if self._pending_R is not None:
                print(f"[TCPCameraStream] UART 난수(R={self._pending_R.hex().upper()}) 수신, 세션키 갱신 요청...")
                self.current_R = self._pending_R
                self._pending_R = None
                self._send_frame(client_socket, 0x32, self.current_R)
                
            try:
                pkt_type, cipher_data = self._recv_frame(client_socket)
                if pkt_type is None:
                    continue
                    
                if pkt_type == 0x40:
                    b_session_key = bytes(a ^ b for a, b in zip(self.b_master_key, self.current_R))
        
                    # Decode Channel A
                    padded_plain_a = decrypt_restarted_gcm_blocks(cipher_data, session_key)
                    raw_jpeg_a = unpad_pkcs7(padded_plain_a)
                    np_arr_a = np.frombuffer(raw_jpeg_a, dtype=np.uint8)
                    frame_a = cv2.imdecode(np_arr_a, cv2.IMREAD_COLOR)
                    if frame_a is not None:
                        self.last_frame_a = cv2.rotate(frame_a, cv2.ROTATE_180)
                    else:
                        self.last_frame_a = None
                        
                    # Decode Channel B
                    if self.b_master_key == self.master_key:
                        self.last_frame_b = self.last_frame_a
                    else:
                        padded_plain_b = decrypt_restarted_gcm_blocks(cipher_data, b_session_key)
                        raw_jpeg_b = unpad_pkcs7(padded_plain_b)
                        np_arr_b = np.frombuffer(raw_jpeg_b, dtype=np.uint8)
                        frame_b = cv2.imdecode(np_arr_b, cv2.IMREAD_COLOR)
                        if frame_b is not None:
                            self.last_frame_b = cv2.rotate(frame_b, cv2.ROTATE_180)
                        else:
                            self.last_frame_b = None
                elif pkt_type == 0x33:
                    self._send_frame(client_socket, 0x34, b'\x00' * 16)
                elif pkt_type == 0x35:
                    session_key = bytes(a ^ b for a, b in zip(self.master_key, self.current_R))
                    challenge = bytes(a ^ b for a, b in zip(self.current_R, bytes.fromhex("5A5A5A5A5A5A5A5AA5A5A5A5A5A5A5A5")))
                    iv = b'\x36\x00\x00\x01' + b'\x00' * 8
                    cipher = AES.new(session_key, AES.MODE_GCM, nonce=iv)
                    ciphertext, tag = cipher.encrypt_and_digest(challenge)
                    self._send_frame(client_socket, 0x36, iv + ciphertext + tag)
                elif pkt_type == 0x37:
                    print("[TCPCameraStream] 키 갱신 핸드셰이크 완료!")
            except Exception as e:
                self.last_frame_a = None
                self.last_frame_b = None
                
        client_socket.close()
