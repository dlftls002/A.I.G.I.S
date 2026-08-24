"""Minimal AES-128-GCM codec for one 16-byte block and no AAD.

This module intentionally mirrors the supplied RTL IP transaction shape:
96-bit IV, 128-bit plaintext/ciphertext, and a 128-bit authentication tag.
It uses only the Python standard library so the control-room PC does not need
an additional crypto package during board bring-up.
"""

from __future__ import annotations

import hmac
from dataclasses import dataclass


SBOX = (
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
)

RCON = (0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)
FRAME_MAGIC = b"\xA5\x5A"
FRAME_SIZE = 48
PLAINTEXT_SIZE = 16


class AuthenticationError(ValueError):
    """Raised when a GCM tag or secure-frame header does not verify."""


def _xtime(value: int) -> int:
    return ((value << 1) ^ (0x1B if value & 0x80 else 0)) & 0xFF


def _expand_key(key: bytes) -> tuple[bytes, ...]:
    if len(key) != 16:
        raise ValueError("AES-128 key must be exactly 16 bytes")
    words = [list(key[index:index + 4]) for index in range(0, 16, 4)]
    for index in range(4, 44):
        temp = words[index - 1].copy()
        if index % 4 == 0:
            temp = temp[1:] + temp[:1]
            temp = [SBOX[value] for value in temp]
            temp[0] ^= RCON[index // 4]
        words.append([words[index - 4][i] ^ temp[i] for i in range(4)])
    return tuple(bytes(sum(words[round_index * 4:(round_index + 1) * 4], [])) for round_index in range(11))


def _add_round_key(state: list[int], round_key: bytes) -> None:
    for index, value in enumerate(round_key):
        state[index] ^= value


def _sub_bytes(state: list[int]) -> None:
    for index, value in enumerate(state):
        state[index] = SBOX[value]


def _shift_rows(state: list[int]) -> None:
    original = state.copy()
    for row in range(4):
        for column in range(4):
            state[row + 4 * column] = original[row + 4 * ((column + row) % 4)]


def _mix_columns(state: list[int]) -> None:
    for column in range(4):
        offset = 4 * column
        a0, a1, a2, a3 = state[offset:offset + 4]
        total = a0 ^ a1 ^ a2 ^ a3
        state[offset] = a0 ^ total ^ _xtime(a0 ^ a1)
        state[offset + 1] = a1 ^ total ^ _xtime(a1 ^ a2)
        state[offset + 2] = a2 ^ total ^ _xtime(a2 ^ a3)
        state[offset + 3] = a3 ^ total ^ _xtime(a3 ^ a0)


def aes128_encrypt_block(key: bytes, block: bytes) -> bytes:
    if len(block) != 16:
        raise ValueError("AES block must be exactly 16 bytes")
    round_keys = _expand_key(key)
    state = list(block)
    _add_round_key(state, round_keys[0])
    for round_index in range(1, 10):
        _sub_bytes(state)
        _shift_rows(state)
        _mix_columns(state)
        _add_round_key(state, round_keys[round_index])
    _sub_bytes(state)
    _shift_rows(state)
    _add_round_key(state, round_keys[10])
    return bytes(state)


def _gf_multiply(x: int, y: int) -> int:
    z = 0
    v = y
    reduction = 0xE1000000000000000000000000000000
    for bit in range(128):
        if (x >> (127 - bit)) & 1:
            z ^= v
        v = (v >> 1) ^ (reduction if v & 1 else 0)
    return z


def _ghash(hash_subkey: bytes, ciphertext: bytes) -> bytes:
    h = int.from_bytes(hash_subkey, "big")
    y = 0
    blocks = [ciphertext, (0).to_bytes(8, "big") + (len(ciphertext) * 8).to_bytes(8, "big")]
    for block in blocks:
        y = _gf_multiply(y ^ int.from_bytes(block, "big"), h)
    return y.to_bytes(16, "big")


def encrypt_block(key: bytes, iv: bytes, plaintext: bytes) -> tuple[bytes, bytes]:
    if len(iv) != 12:
        raise ValueError("GCM IV must be exactly 12 bytes")
    if len(plaintext) != PLAINTEXT_SIZE:
        raise ValueError("RTL-compatible plaintext must be exactly 16 bytes")
    hash_subkey = aes128_encrypt_block(key, bytes(16))
    j0 = iv + b"\x00\x00\x00\x01"
    counter_block = iv + b"\x00\x00\x00\x02"
    stream = aes128_encrypt_block(key, counter_block)
    ciphertext = bytes(left ^ right for left, right in zip(plaintext, stream))
    ghash = _ghash(hash_subkey, ciphertext)
    tag_mask = aes128_encrypt_block(key, j0)
    tag = bytes(left ^ right for left, right in zip(tag_mask, ghash))
    return ciphertext, tag


def decrypt_block(key: bytes, iv: bytes, ciphertext: bytes, tag: bytes) -> bytes:
    if len(ciphertext) != 16 or len(tag) != 16:
        raise ValueError("Ciphertext and tag must each be exactly 16 bytes")
    hash_subkey = aes128_encrypt_block(key, bytes(16))
    j0 = iv + b"\x00\x00\x00\x01"
    expected_tag = bytes(
        left ^ right
        for left, right in zip(aes128_encrypt_block(key, j0), _ghash(hash_subkey, ciphertext))
    )
    if not hmac.compare_digest(tag, expected_tag):
        raise AuthenticationError("AES-GCM authentication failed")
    stream = aes128_encrypt_block(key, iv + b"\x00\x00\x00\x02")
    return bytes(left ^ right for left, right in zip(ciphertext, stream))


def build_clear_frame(packet_type: int, payload: bytes) -> bytes:
    """Build a 48-byte session-management frame with TYPE and R in clear."""
    if len(payload) != PLAINTEXT_SIZE:
        raise ValueError("Clear-frame payload must be exactly 16 bytes")
    return (
        FRAME_MAGIC
        + bytes((packet_type & 0xFF, PLAINTEXT_SIZE))
        + bytes(12)
        + payload
        + bytes(16)
    )


def parse_clear_frame(frame: bytes, expected_type: int) -> bytes:
    """Validate and return clear R from a session-management frame."""
    if len(frame) != FRAME_SIZE:
        raise AuthenticationError("Clear frame must be exactly 48 bytes")
    if frame[:2] != FRAME_MAGIC or frame[2] != expected_type or frame[3] != PLAINTEXT_SIZE:
        raise AuthenticationError("Clear frame header mismatch")
    if frame[4:16] != bytes(12) or frame[32:48] != bytes(16):
        raise AuthenticationError("Clear frame reserved fields must be zero")
    return frame[16:32]


@dataclass
class SecureFrameCodec:
    key: bytes
    iv_prefix: bytes
    counter: int = 1

    def __post_init__(self) -> None:
        if len(self.key) != 16:
            raise ValueError("AES-128 key must be 16 bytes")
        if len(self.iv_prefix) != 4:
            raise ValueError("IV prefix must be 4 bytes")

    def encrypt_frame(self, packet_type: int, plaintext: bytes) -> bytes:
        iv = self.iv_prefix + self.counter.to_bytes(8, "big")
        self.counter = (self.counter + 1) & 0xFFFFFFFFFFFFFFFF
        ciphertext, tag = encrypt_block(self.key, iv, plaintext)
        return FRAME_MAGIC + bytes((packet_type & 0xFF, PLAINTEXT_SIZE)) + iv + ciphertext + tag

    def decrypt_frame(self, frame: bytes, expected_type: int) -> bytes:
        if len(frame) != FRAME_SIZE:
            raise AuthenticationError("Secure frame must be exactly 48 bytes")
        if frame[:2] != FRAME_MAGIC or frame[2] != expected_type or frame[3] != PLAINTEXT_SIZE:
            raise AuthenticationError("Secure frame header mismatch")
        return decrypt_block(self.key, frame[4:16], frame[16:32], frame[32:48])


def _self_test() -> None:
    key = bytes(16)
    iv = bytes(12)
    plaintext = bytes(16)
    ciphertext, tag = encrypt_block(key, iv, plaintext)
    assert ciphertext.hex() == "0388dace60b6a392f328c2b971b2fe78"
    assert tag.hex() == "ab6e47d42cec13bdf53a67b21257bddf"
    assert decrypt_block(key, iv, ciphertext, tag) == plaintext
    clear = build_clear_frame(0x12, bytes(range(16)))
    assert parse_clear_frame(clear, 0x12) == bytes(range(16))


if __name__ == "__main__":
    _self_test()
    print("PASS: Python AES-128-GCM matches the NIST one-block vector")
