"""AIGIS three-screen operational control-room UI."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
from queue import Empty, Queue
import shutil
import tkinter as tk
from tkinter import messagebox, ttk
import time

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageGrab, ImageTk

from secure_serial_client import DOOR_CLOSE_CMD, MASTER_KEY, SecureSerialClient
from user_repository import UserRepository
from tcp_camera_stream import TCPCameraStream
from tcp_face_client import TCPFaceClient


ROOT_DIR = Path(__file__).resolve().parent
ASSET_DIR = ROOT_DIR / "assets"
FACE_REGISTRY_DIR = ROOT_DIR / "face_registry"
CONFIG_PATH = ROOT_DIR / "config.json"

BG = "#030b18"
PANEL = "#07172b"
PANEL_2 = "#0b213b"
PANEL_3 = "#0d2947"
TEXT = "#f5f9ff"
MUTED = "#83a0bf"
CYAN = "#19c7ff"
GREEN = "#27d56f"
RED = "#ff343f"
ORANGE = "#ff9e31"
BLUE = "#168fe0"
BORDER = "#1c486a"


def load_config() -> dict:
    defaults = {
        "serial_port": "COM10",
        "baud_rate": 115200,
        "cctv_source": None,
        "pcam_ch_a_source": None,
        "pcam_ch_b_source": None,
        "face_camera_source": 0,
        "fire_threshold": 30,
        "show_security_random": True,
        "face_overlay_seconds": 8,
        "registration_timeout_seconds": 180,
    }
    if CONFIG_PATH.exists():
        try:
            defaults.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
        except (json.JSONDecodeError, OSError):
            pass
    return defaults


def button(parent, text, command, color=BLUE, width=12, font_size=10, pady=7):
    return tk.Button(
        parent,
        text=text,
        command=command,
        bg=color,
        activebackground=color,
        fg="white",
        activeforeground="white",
        relief="flat",
        cursor="hand2",
        font=("Malgun Gothic", font_size, "bold"),
        width=width,
        pady=pady,
        borderwidth=0,
    )


class Header(tk.Frame):
    def __init__(self, parent, title: str, app: "AigisApp", active: str) -> None:
        super().__init__(parent, bg=BG, height=145, highlightthickness=0)
        self.pack_propagate(False)
        self.clock = tk.Label(self, text="00:00:00", bg=BG, fg=CYAN, font=("Segoe UI", 29, "bold"))
        self.clock.place(x=24, y=91, anchor="w")
        tk.Label(self, text="LIVE SYSTEM", bg=BG, fg=MUTED, font=("Segoe UI", 9, "bold")).place(x=190, y=99, anchor="w")
        tk.Label(self, text=title, bg=BG, fg=TEXT, font=("Segoe UI", 90, "bold")).place(relx=0.5, y=65, anchor="center")

        right = tk.Frame(self, bg=BG)
        right.place(relx=0.99, y=100, anchor="e")
        nav = tk.Frame(right, bg=BG)
        nav.pack(side="left", padx=(0, 12))
        for label, name in (("관제", "monitor"), ("랙", "racks"), ("등록", "register")):
            color = "#0d4568" if name == active else PANEL_2
            nav_button = button(nav, label, lambda page=name: app.show_page(page), color, 6, 10, 6)
            nav_button.pack(side="left", padx=3)
            if name == active:
                nav_button.config(highlightthickness=1, highlightbackground=CYAN)
        button(nav, "전체화면", app.toggle_fullscreen, "#174b70", 8, 10, 6).pack(side="left", padx=3)
        self.secure = tk.Label(
            right,
            text="● 보안 통신 대기",
            bg=PANEL_2,
            fg=ORANGE,
            font=("Malgun Gothic", 9, "bold"),
            padx=12,
            pady=8,
        )
        self.secure.pack(side="left")
        tk.Frame(self, height=1, bg=CYAN).place(relx=0, rely=0.98, relwidth=1)
        self._tick()

    def set_security(self, text: str, color: str) -> None:
        self.secure.config(text=f"● {text}", fg=color)

    def _tick(self) -> None:
        self.clock.config(text=datetime.now().strftime("%H:%M:%S"))
        self.after(500, self._tick)


class CameraStream:
    """One OpenCV capture shared by all pages that show the same source."""

    def __init__(self, source=None) -> None:
        self.capture = None
        self.last_frame = None
        if source is not None:
            try:
                self.capture = cv2.VideoCapture(source)
            except Exception:
                self.capture = None

    def read(self):
        if self.capture and self.capture.isOpened():
            ok, frame = self.capture.read()
            if ok:
                self.last_frame = frame
        return self.last_frame

    def close(self) -> None:
        if self.capture:
            self.capture.release()


class CameraPanel(tk.Frame):
    def __init__(
        self,
        parent,
        title: str,
        stream: CameraStream,
        compact=False,
        title_font_size: int | None = None,
        center_title: bool = False,
        active_check=None,
        frame_interval_ms: int = 50,
    ) -> None:
        super().__init__(parent, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        self.stream = stream
        self.active_check = active_check
        self.frame_interval_ms = max(33, int(frame_interval_ms))
        self.last_frame = None
        self._last_source_frame = None
        self._render_signature = None
        self._last_error_text = None
        self.custom_error_msg = ""
        header_height = 36 if compact else max(54, (title_font_size or 15) + 30)
        header = tk.Frame(self, bg=PANEL, height=header_height)
        header.pack(fill="x")
        header.pack_propagate(False)
        title_label = tk.Label(
            header,
            text=title,
            bg=PANEL,
            fg=CYAN,
            font=("Segoe UI", title_font_size or (12 if compact else 15), "bold"),
        )
        if center_title:
            title_label.place(relx=0.5, rely=0.5, anchor="center")
        else:
            title_label.pack(side="left", padx=20)
        self.health = tk.Label(header, text="CAMERA READY", bg=PANEL, fg=GREEN, font=("Segoe UI", 10, "bold"))
        self.health.pack(side="right", padx=20)
        
        self.info_area = tk.Frame(self, bg=PANEL, height=115)
        self.info_area.pack(fill="x", padx=7, pady=(5, 5))
        self.info_area.pack_propagate(False)
        
        self.video = tk.Label(self, text="영상 입력 대기", bg="#01050c", fg=MUTED, font=("Malgun Gothic", 14))
        self.video.pack(fill="both", expand=True, padx=7, pady=(0, 7))
        
        self.jpeg_error_sim = False
        self._distortion_tick = 0
        self.handshake_dropout_enabled = False
        self.handshake_dropout_period = 15.0
        self.handshake_dropout_duration = 0.3
        self._handshake_dropout_started_at = time.monotonic()
        self.mismatch_badge = tk.Label(
            self,
            text="마스터키 불일치 · 인증 실패",
            bg="#7a1018",
            fg="white",
            font=("Malgun Gothic", 11, "bold"),
            padx=11,
            pady=6,
            highlightthickness=1,
            highlightbackground="#ff5661",
        )
        
        self.after(50, self._update)

    def _is_render_active(self) -> bool:
        if not self.winfo_ismapped():
            return False
        if self.active_check is None:
            return True
        try:
            return bool(self.active_check())
        except (AttributeError, tk.TclError):
            return False

    def _schedule_update(self, delay: int | None = None) -> None:
        self.after(self.frame_interval_ms if delay is None else delay, self._update)

    def enable_handshake_dropout(
        self, period_seconds: float = 15.0, duration_seconds: float = 0.3
    ) -> None:
        """Enable a clearly labelled intermittent handshake-retry visual."""
        self.handshake_dropout_enabled = True
        self.handshake_dropout_period = max(5.0, float(period_seconds))
        self.handshake_dropout_duration = max(0.1, float(duration_seconds))
        self._handshake_dropout_started_at = time.monotonic()

    @staticmethod
    def _apply_key_mismatch_effect(frame: np.ndarray, tick: int) -> np.ndarray:
        """Simulate severe analogue-TV static caused by a wrong session key."""
        height, width = frame.shape[:2]
        if height < 4 or width < 4:
            return frame

        rng = np.random.default_rng(0xA1615 + tick)
        yy, xx = np.indices((height, width), dtype=np.float32)
        # Lost horizontal sync: every scan line shakes independently while a
        # larger wave bends the entire picture from side to side.
        row_jitter = rng.normal(0.0, max(3.0, width * 0.010), (height, 1))
        wave = (
            np.sin(yy / 13.0 + tick * 0.75) * max(5.0, width * 0.018)
            + row_jitter
        ).astype(np.float32)
        warped = cv2.remap(
            frame,
            xx + wave,
            yy,
            interpolation=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_REFLECT,
        )
        warped = np.roll(warped, (tick * 9) % height, axis=0)

        blue, green, red = cv2.split(warped)
        channel_shift = max(5, width // 45)
        blue = np.roll(blue, channel_shift, axis=1)
        red = np.roll(red, -channel_shift, axis=1)
        distorted = cv2.merge((blue, green, red))

        # Large moving tear bands imitate a television losing horizontal hold.
        for index in range(7):
            band_height = int(rng.integers(max(3, height // 70), max(5, height // 18)))
            y0 = int((tick * (7 + index * 4) + index * height / 7) % height)
            y1 = min(height, y0 + band_height)
            shift = int(rng.integers(-max(8, width // 4), max(9, width // 4)))
            distorted[y0:y1] = np.roll(distorted[y0:y1], shift, axis=1)

        # Dense monochrome snow; brief bursts almost completely bury the image.
        snow = rng.integers(0, 256, (height, width), dtype=np.uint8)
        snow_bgr = cv2.cvtColor(snow, cv2.COLOR_GRAY2BGR)
        snow_strength = 0.78 if tick % 17 in (0, 1, 2) else 0.48
        distorted = cv2.addWeighted(
            distorted, 1.0 - snow_strength, snow_bgr, snow_strength, 0
        )

        # Salt-and-pepper sparks, dark scanlines and a rolling bright tracking bar.
        spark_mask = rng.random((height, width)) < 0.075
        spark_value = rng.choice(np.array([0, 255], dtype=np.uint8), (height, width))
        distorted[spark_mask] = spark_value[spark_mask, None]
        distorted[1::3] = (
            distorted[1::3].astype(np.float32) * 0.35
        ).astype(np.uint8)
        tracking_y = (tick * 19) % height
        tracking_h = max(4, height // 40)
        tracking_end = min(height, tracking_y + tracking_h)
        distorted[tracking_y:tracking_end] = cv2.addWeighted(
            distorted[tracking_y:tracking_end], 0.25,
            snow_bgr[tracking_y:tracking_end], 0.75, 35,
        )
        return distorted

    def _update(self) -> None:
        if not self._is_render_active():
            self._schedule_update(180)
            return

        # Once per cycle, hold a plain black frame long enough for the signal
        # interruption to be clearly visible.
        dropout_active = False
        if self.handshake_dropout_enabled:
            elapsed = time.monotonic() - self._handshake_dropout_started_at
            cycle_phase = elapsed % self.handshake_dropout_period
            dropout_active = (
                elapsed >= self.handshake_dropout_period
                and cycle_phase < self.handshake_dropout_duration
            )
        if dropout_active:
            if self.mismatch_badge.winfo_ismapped():
                self.mismatch_badge.place_forget()
            self.video.config(
                image="",
                text="",
                bg="#000000",
            )
            self.video.image = None
            self.health.config(text="", bg=PANEL)
            self._render_signature = None
            self._last_error_text = None
            self._schedule_update(80)
            return
            
        distortion_active = bool(getattr(self, "jpeg_error_sim", False))
        if distortion_active:
            if not self.mismatch_badge.winfo_ismapped():
                self.mismatch_badge.place(
                    in_=self.video, relx=0.98, rely=0.04, anchor="ne"
                )
                self.mismatch_badge.lift()
        elif self.mismatch_badge.winfo_ismapped():
            self.mismatch_badge.place_forget()
            self.health.config(bg=PANEL)
            
        anim_frame = getattr(self, 'animation_frame', None)
        if anim_frame is not None:
            frame = anim_frame
        else:
            frame = self.stream.read()
        if frame is None and distortion_active:
            frame = self.last_frame
            if frame is None:
                fallback = getattr(self, "distortion_fallback", None)
                if callable(fallback):
                    frame = fallback()
            
        if frame is not None:
            if frame is not self._last_source_frame:
                self._last_source_frame = frame
                self.last_frame = frame

            available_width = self.video.winfo_width()
            available_height = self.video.winfo_height()
            if available_width < 16 or available_height < 16:
                self._schedule_update(80)
                return
            orig_h, orig_w = frame.shape[:2]
            scale_ratio = min(available_width / orig_w, available_height / orig_h)
            target_width = max(2, int(orig_w * scale_ratio))
            target_height = max(2, int(orig_h * scale_ratio))
            tint = getattr(self, 'face_tint', None)
            tint_signature = tuple(tint) if tint else None
            signature = (
                id(frame),
                target_width,
                target_height,
                tint_signature,
                self._distortion_tick if distortion_active else 0,
            )
            if signature == self._render_signature:
                self._schedule_update()
                return

            interpolation = cv2.INTER_AREA if scale_ratio < 1.0 else cv2.INTER_LINEAR
            resized_bgr = cv2.resize(frame, (target_width, target_height), interpolation=interpolation)
            if distortion_active:
                self._distortion_tick += 1
                resized_bgr = self._apply_key_mismatch_effect(
                    resized_bgr, self._distortion_tick
                )
            resized_rgb = cv2.cvtColor(resized_bgr, cv2.COLOR_BGR2RGB)
            if tint:
                h, w = resized_rgb.shape[:2]
                if not hasattr(self, '_vignette_mask') or self._vignette_mask.shape[:2] != (h, w):
                    x = np.linspace(0, 1, w, dtype=np.float32)
                    y = np.linspace(0, 1, h, dtype=np.float32)
                    dist_x = np.minimum(x, 1 - x)[np.newaxis, :]
                    dist_y = np.minimum(y, 1 - y)[:, np.newaxis]
                    mask = 1.0 - np.clip(dist_x / 0.15, 0, 1) * np.clip(dist_y / 0.15, 0, 1)
                    self._vignette_mask = mask[..., np.newaxis]
                resized_rgb = (
                    resized_rgb * (1.0 - self._vignette_mask * 0.9)
                    + np.asarray(tint, dtype=np.float32) * (self._vignette_mask * 0.9)
                ).astype(np.uint8)
            image = Image.fromarray(resized_rgb)
            photo = ImageTk.PhotoImage(image)
            self.video.config(image=photo, text="")
            self.video.image = photo
            expected_health = "인증 실패" if distortion_active else "LIVE"
            if self.health.cget("text") != expected_health:
                self.health.config(
                    text=expected_health,
                    fg="white" if distortion_active else GREEN,
                    bg=RED if distortion_active else PANEL,
                )
            self._render_signature = signature
            self._last_error_text = None
        else:
            err_text = "JPEG 해독 실패\n(잘못된 세션키 혹은 데이터 손상)"
            if self.custom_error_msg:
                err_text += f"\n\n[ {self.custom_error_msg} ]"
            if err_text != self._last_error_text:
                self.video.config(image="", text=err_text, fg="#ff343f")
                self.video.image = None
                self.health.config(text="DECRYPT FAIL", fg="#ff343f", bg=PANEL)
                self._last_error_text = err_text
                self._render_signature = None
        self._schedule_update()

    def save_snapshot(self, destination: Path) -> bool:
        if self.last_frame is None:
            return False
        destination.parent.mkdir(parents=True, exist_ok=True)
        return bool(cv2.imwrite(str(destination), self.last_frame))

    def invalidate(self) -> None:
        """Force one fresh render after a page or overlay becomes visible."""
        self._render_signature = None


class EventLog(tk.Frame):
    def __init__(self, parent, title="실시간 장비 · AES-GCM 보안 이벤트") -> None:
        super().__init__(parent, bg=PANEL, height=245, highlightthickness=1, highlightbackground=BORDER)
        self.pack_propagate(False)
        head = tk.Frame(self, bg=PANEL)
        head.pack(fill="x", padx=12, pady=(6, 4))
        tk.Label(head, text=title, bg=PANEL, fg=TEXT, font=("Malgun Gothic", 14, "bold")).pack(side="left")
        tk.Label(head, text="실제 KEY · IV · 평문 · 암호문 · GCM TAG", bg=PANEL, fg=MUTED, font=("Malgun Gothic", 9)).pack(side="right")
        log_body = tk.Frame(self, bg="#020914")
        log_body.pack(fill="both", expand=True, padx=9, pady=(0, 8))
        self.text = tk.Text(
            log_body,
            bg="#020914",
            fg="#dcecff",
            selectbackground="#123c5e",
            relief="flat",
            borderwidth=0,
            font=("Consolas", 10),
            width=1,
            height=8,
            wrap="none",
            state="disabled",
        )
        scrollbar = ttk.Scrollbar(log_body, orient="horizontal", command=self.text.xview)
        self.text.configure(xscrollcommand=scrollbar.set)
        self.text.pack(fill="both", expand=True)
        scrollbar.pack(fill="x")
        self._line_count = 0

    def add(self, message: str, demo: bool = False, color: str | None = None) -> None:
        prefix = "[DEMO] " if demo else ""
        tag = color or "default"
        self.text.configure(state="normal")
        self.text.tag_configure(tag, foreground=color or "#dcecff")
        self.text.insert("1.0", f"{datetime.now():%H:%M:%S}   {prefix}{message}\n", tag)
        self._line_count += 1
        if self._line_count > 120:
            self.text.delete("121.0", tk.END)
            self._line_count = 120
        self.text.configure(state="disabled")


class SecurityFlowPanel(tk.Frame):
    """Live Jetson/PC/ZYBO/Basys3 diagram used only by the rack page."""

    def __init__(self, parent, active_check=None) -> None:
        super().__init__(parent, bg=PANEL, height=310, highlightthickness=1, highlightbackground=BORDER)
        self.pack_propagate(False)
        self.active_check = active_check
        self._redraw_pending = False
        self.master_key = "대기"
        self.random_key = "대기"
        self.session_key = "대기"
        self.state = "KEY EXCHANGE WAIT"
        self.packet = "-"
        self.active_stage = ""
        self.flow_label = "대기"
        self.flow_enabled = True
        self.attack_comparison = None
        self._attack_clear_job = None
        self._animation_jobs = []

        head = tk.Frame(self, bg=PANEL, height=43)
        head.pack(fill="x")
        head.pack_propagate(False)
        tk.Label(head, text="실시간 암호 통신 블록다이어그램", bg=PANEL, fg=TEXT, font=("Malgun Gothic", 20, "bold")).pack(expand=True)

        self.body = tk.Frame(self, bg="#020914")
        self.body.pack(fill="both", expand=True, padx=8, pady=(0, 8))
        self.canvas = tk.Canvas(self.body, bg="#020914", highlightthickness=0)
        self.canvas.bind("<Configure>", lambda _event: self._redraw())
        self.canvas.pack(fill="both", expand=True)
        # Keep collecting diagnostic lines for internal verification, but the
        # operator UI intentionally exposes only the live diagram.
        self.log = EventLog(self.body, title="실제 장비 · AES-GCM 상세 로그")

    @staticmethod
    def _short(value: str, length: int = 12) -> str:
        if not value or value == "대기":
            return "대기"
        return value if len(value) <= length else f"{value[:length]}…"

    @staticmethod
    def _wrap_key(value: str) -> str:
        if not value or value == "대기":
            return "대기"
        # A 128-bit key is 32 hexadecimal characters.  The fullscreen
        # monitoring layout has enough horizontal room, so keep the complete
        # value on one line for quicker visual comparison between devices.
        return value[:32]

    def show_flow(self) -> None:
        self.log.pack_forget()
        self.canvas.pack(fill="both", expand=True)
        self._redraw()

    def show_log(self) -> None:
        self.show_flow()

    def set_flow_enabled(self, enabled: bool) -> None:
        self.flow_enabled = enabled
        if not enabled:
            for job in self._animation_jobs:
                try:
                    self.after_cancel(job)
                except tk.TclError:
                    pass
            self._animation_jobs.clear()
            self.active_stage = ""
            self.flow_label = "통신 불가"
        else:
            self.flow_label = "대기"
        self._redraw()

    def update_security(self, state: str, master: str = "", random_key: str = "", session: str = "") -> None:
        self.state = state
        if master:
            self.master_key = master
        if random_key:
            self.random_key = random_key
        if session:
            self.session_key = session
        self._redraw()

    def update_crypto(self, event: dict) -> None:
        self.packet = event.get("packet_name", "UNKNOWN")
        if event.get("attack"):
            self.state = "INVALID MASTER KEY · TAG FAIL"
            self.attack_comparison = {
                "correct_master": event.get("correct_master_key_hex", ""),
                "wrong_master": event.get("master_key_hex", ""),
                "correct_session": event.get("correct_key_hex", ""),
                "wrong_session": event.get("session_key_hex", ""),
            }
            if self._attack_clear_job:
                self.after_cancel(self._attack_clear_job)
            self._attack_clear_job = self.after(7000, self._clear_attack_comparison)
            self._redraw()
            return
        if event.get("direction") == "RX":
            self.state = "TAG PASS · DECRYPT OK" if event.get("authenticated") else "TAG FAIL · FRAME DROP"
        else:
            self.state = "ENCRYPTED · UART 전송"
        self.update_security(
            self.state,
            event.get("master_key_hex", ""),
            event.get("random_hex", ""),
            event.get("session_key_hex", ""),
        )

    def _clear_attack_comparison(self) -> None:
        self.attack_comparison = None
        self._attack_clear_job = None
        self._redraw()

    def animate_command(self, label: str, target: str = "basys") -> None:
        if not self.flow_enabled:
            return
        destination = ["jetson_door", "jetson_ack"] if target == "jetson" else ["basys_spi", "basys_return"]
        self._animate(
            label,
            ["pc_uart", "zybo_decrypt", "zybo_command", "zybo_encrypt", *destination, "pc_uart_up"],
        )

    def animate_face(self, label: str) -> None:
        if not self.flow_enabled:
            return
        self._animate(
            label,
            ["jetson_face", "zybo_decrypt", "zybo_command", "pc_uart_up"],
        )

    def _animate(self, label: str, stages: list[str]) -> None:
        if not self.flow_enabled:
            return
        for job in self._animation_jobs:
            try:
                self.after_cancel(job)
            except tk.TclError:
                pass
        self._animation_jobs.clear()
        self.flow_label = label
        step_ms = 450
        for index, stage in enumerate(stages):
            self._animation_jobs.append(self.after(index * step_ms, lambda value=stage: self._set_stage(value)))
        self._animation_jobs.append(self.after(len(stages) * step_ms + 800, lambda: self._set_stage("")))

    def _set_stage(self, stage: str) -> None:
        self.active_stage = stage
        self._redraw()

    def _device(self, box: tuple[float, float, float, float], title: str, color: str, active=False) -> None:
        x1, y1, x2, y2 = box
        outline = ORANGE if active else color
        self.canvas.create_rectangle(x1, y1, x2, y2, fill="#07172b", outline=outline, width=4 if active else 2)
        self.canvas.create_rectangle(x1, y1, x2, y1 + 38, fill="#0b2945", outline=outline, width=1)
        self.canvas.create_text((x1 + x2) / 2, y1 + 19, text=title, fill=TEXT, font=("Segoe UI", 16, "bold"))
        key = self._wrap_key(self.master_key)
        if "\n" in key:
            first, second = key.split("\n", 1)
            key = f"마스터키  {first}\n          {second}"
        else:
            key = f"마스터키  {key}"
        if title.startswith("관제 PC"):
            self.canvas.create_text(x2 + 55, y2 - 65, text=key, fill="#c9e4ff", font=("Malgun Gothic", 16, "bold"), anchor="nw", justify="left")
        else:
            self.canvas.create_text((x1 + x2) / 2, y2 + 7, text=key, fill="#c9e4ff", font=("Malgun Gothic", 12, "bold"), anchor="n", justify="left")

    def _inner_block(self, box: tuple[float, float, float, float], text: str, stage: str | tuple[str, ...]) -> None:
        x1, y1, x2, y2 = box
        active = self.active_stage in stage if isinstance(stage, tuple) else self.active_stage == stage
        color = ORANGE if active else CYAN
        self.canvas.create_rectangle(x1, y1, x2, y2, fill="#0a1d34", outline=color, width=3 if active else 1)
        block_height = y2 - y1
        block_width = x2 - x1
        font_size = 12 if block_width < 115 else (18 if block_height >= 62 else (15 if block_height >= 42 else 10))
        self.canvas.create_text((x1 + x2) / 2, (y1 + y2) / 2, text=text, fill=ORANGE if active else TEXT, font=("Malgun Gothic", font_size, "bold"), justify="center")

    def _line(self, points: tuple[float, ...], stage: str, label: str, label_at: tuple[float, float]) -> None:
        active = self.active_stage == stage
        color = ORANGE if active else "#39708e"
        self.canvas.create_line(*points, fill=color, width=7 if active else 4, arrow=tk.LAST, arrowshape=(13, 16, 6), smooth=False)
        self.canvas.create_text(*label_at, text=label, fill=ORANGE if active else MUTED, font=("Segoe UI", 11, "bold"))
        if active:
            coords = list(points)
            x1, y1, x2, y2 = coords[-4:]
            self.canvas.create_oval(x2 - 6, y2 - 6, x2 + 6, y2 + 6, fill=ORANGE, outline="#fff2c9", width=2)

    def _duplex_link(
        self,
        start: tuple[float, float],
        end: tuple[float, float],
        forward_stage: str | tuple[str, ...],
        reverse_stage: str | tuple[str, ...],
        label: str,
    ) -> None:
        x1, y1 = start
        x2, y2 = end
        offset = 65
        forward = self.active_stage in forward_stage if isinstance(forward_stage, tuple) else self.active_stage == forward_stage
        reverse = self.active_stage in reverse_stage if isinstance(reverse_stage, tuple) else self.active_stage == reverse_stage
        self.canvas.create_line(
            x1,
            y1 - offset,
            x2,
            y2 - offset,
            fill=ORANGE if forward else "#39708e",
            width=18 if forward else 12,
            arrow=tk.LAST,
            arrowshape=(18, 22, 9),
        )
        self.canvas.create_text(
            (x1 + x2) / 2,
            (y1 + y2) / 2,
            text=label,
            fill=ORANGE if forward or reverse else TEXT,
            font=("Segoe UI", 17, "bold"),
        )
        self.canvas.create_line(
            x2,
            y2 + offset,
            x1,
            y1 + offset,
            fill=ORANGE if reverse else "#39708e",
            width=18 if reverse else 12,
            arrow=tk.LAST,
            arrowshape=(18, 22, 9),
        )

    def _duplex_vertical(
        self,
        start: tuple[float, float],
        end: tuple[float, float],
        forward_stage: str,
        reverse_stage: str,
        label: str,
    ) -> None:
        x1, y1 = start
        x2, y2 = end
        offset = 80
        forward = self.active_stage == forward_stage
        reverse = self.active_stage == reverse_stage
        self.canvas.create_line(
            x1 - offset,
            y1,
            x2 - offset,
            y2,
            fill=ORANGE if forward else "#39708e",
            width=18 if forward else 12,
            arrow=tk.LAST,
            arrowshape=(18, 22, 9),
        )
        self.canvas.create_text(
            (x1 + x2) / 2,
            (y1 + y2) / 2,
            text=label,
            fill=ORANGE if forward or reverse else TEXT,
            font=("Segoe UI", 17, "bold"),
        )
        self.canvas.create_line(
            x2 + offset,
            y2,
            x1 + offset,
            y1,
            fill=ORANGE if reverse else "#39708e",
            width=18 if reverse else 12,
            arrow=tk.LAST,
            arrowshape=(18, 22, 9),
        )

    def _key_derivation(self, area: tuple[float, float, float, float]) -> None:
        x1, y1, x2, y2 = area
        values = (
            ("마스터키", self.master_key, CYAN),
            ("난수키", self.random_key, ORANGE),
            ("세션키", self.session_key, GREEN),
        )
        total_height = y2 - y1
        symbol_space = 18.0 if total_height >= 170 else 8.0
        row_height = (total_height - symbol_space * 2) / 3
        label_font = 14 if row_height >= 46 else 10
        value_font = 10 if row_height >= 46 else 8
        positions = []
        for index, (label, value, color) in enumerate(values):
            row_y1 = y1 + index * (row_height + symbol_space)
            row_y2 = row_y1 + row_height
            display_value = self._wrap_key(value)
            self.canvas.create_rectangle(x1, row_y1, x2, row_y2, fill="#061425", outline=color, width=2)
            self.canvas.create_text(x1 + 12, (row_y1 + row_y2) / 2, text=label, fill=color, font=("Malgun Gothic", label_font, "bold"), anchor="w")
            self.canvas.create_text(
                x1 + 82,
                (row_y1 + row_y2) / 2,
                text=display_value,
                fill=color,
                font=("Consolas", value_font, "bold"),
                justify="left",
                anchor="w",
            )
            positions.append((row_y1, row_y2))
        self.canvas.create_text((x1 + x2) / 2, positions[0][1] + symbol_space / 2, text="⊕", fill=TEXT, font=("Segoe UI Symbol", 19, "bold"))
        self.canvas.create_text((x1 + x2) / 2, positions[1][1] + symbol_space / 2, text="=", fill=TEXT, font=("Segoe UI", 18, "bold"))

    def _stacked_blocks(
        self,
        area: tuple[float, float, float, float],
        items: tuple[tuple[str, str | tuple[str, ...]], ...],
    ) -> None:
        x1, y1, x2, y2 = area
        gap = 16.0 if y2 - y1 >= 170 else 7.0
        row_height = (y2 - y1 - gap * (len(items) - 1)) / len(items)
        for index, (text, stage) in enumerate(items):
            row_y1 = y1 + index * (row_height + gap)
            row_y2 = row_y1 + row_height
            self._inner_block((x1, row_y1, x2, row_y2), text, stage)
            if index < len(items) - 1:
                active = self.active_stage in stage if isinstance(stage, tuple) else self.active_stage == stage
                self.canvas.create_line(
                    (x1 + x2) / 2,
                    row_y2 + 2,
                    (x1 + x2) / 2,
                    row_y2 + gap - 2,
                    fill=ORANGE if active else "#39708e",
                    width=5,
                    arrow=tk.LAST,
                    arrowshape=(10, 12, 5),
                )

    def _horizontal_blocks(
        self,
        area: tuple[float, float, float, float],
        items: tuple[tuple[str, str | tuple[str, ...]], ...],
    ) -> None:
        x1, y1, x2, y2 = area
        gap = 18.0
        column_width = (x2 - x1 - gap * (len(items) - 1)) / len(items)
        for index, (text, stage) in enumerate(items):
            column_x1 = x1 + index * (column_width + gap)
            column_x2 = column_x1 + column_width
            self._inner_block((column_x1, y1, column_x2, y2), text, stage)
            if index < len(items) - 1:
                active = self.active_stage in stage if isinstance(stage, tuple) else self.active_stage == stage
                self.canvas.create_line(
                    column_x2 + 2,
                    (y1 + y2) / 2,
                    column_x2 + gap - 2,
                    (y1 + y2) / 2,
                    fill=ORANGE if active else "#39708e",
                    width=5,
                    arrow=tk.LAST,
                    arrowshape=(10, 12, 5),
                )

    def _redraw(self) -> None:
        if not self.canvas.winfo_exists():
            return
        if self.active_check is not None:
            try:
                if not self.active_check():
                    self._redraw_pending = True
                    return
            except (AttributeError, tk.TclError):
                self._redraw_pending = True
                return
        self._redraw_pending = False
        self.canvas.delete("all")
        width = max(self.canvas.winfo_width(), 1050)
        height = max(self.canvas.winfo_height(), 250)
        sx = width / 1530.0
        box = lambda x1, y1, x2, y2: (x1 * sx, y1, x2 * sx, y2)

        # Keep the formula card compact even in fullscreen; scale its typography,
        # not its empty background.
        kx1, ky1, kx2, ky2 = box(15, 10, 535, 182)
        self.canvas.create_rectangle(kx1, ky1, kx2, ky2, fill="#061425", outline=CYAN, width=2)
        self.canvas.create_text(kx1 + 16, ky1 + 12, text="CURRENT SESSION KEY 생성", anchor="nw", fill=CYAN, font=("Malgun Gothic", 18, "bold"))
        formulas = [
            ("마스터키", self.master_key, TEXT),
            ("난수키", self.random_key, ORANGE),
            ("세션키", self.session_key, GREEN),
        ]
        for index, (label, value, color) in enumerate(formulas):
            row_y = ky1 + 45 + index * 40
            self.canvas.create_text(kx1 + 16, row_y, text=label, anchor="nw", fill=color, font=("Malgun Gothic", 14, "bold"))
            self.canvas.create_text(kx1 + 105, row_y, text=self._wrap_key(value), anchor="nw", fill=color, font=("Consolas", 12, "bold"), justify="left")

        # Fullscreen-first layout. Device crypto/control processing flows from
        # top to bottom, leaving wide corridors for the two physical link lines.
        device_top = max(330.0, min(height * 0.46, height - 330.0))
        device_bottom = height - 72.0
        pc_bottom = min(310.0, device_top - 72.0)
        pc = box(575, 10, 955, pc_bottom)
        jetson = box(10, device_top, 380, device_bottom)
        zybo = box(580, device_top, 950, device_bottom)
        basys = box(1150, device_top, 1520, device_bottom)
        self._device(jetson, "JETSON · FACE ID / 출입문", GREEN, self.active_stage in ("jetson_face", "jetson_door"))
        self._device(pc, "관제 PC · PYTHON UI", CYAN, self.active_stage in ("pc_uart", "pc_uart_up"))
        self._device(zybo, "ZYBO · SECURITY CORE", "#3d80b7", self.active_stage.startswith("zybo_"))
        self._device(basys, "BASYS3 · RACK/SERVO", GREEN, self.active_stage == "basys_spi")

        # Device-specific horizontal operation flow at the top and vertical key
        # derivation at the bottom.
        jx1, jy1, jx2, jy2 = jetson
        jetson_inner_y1, jetson_inner_y2 = jy1 + 47, jy2 - 14
        jetson_available = jetson_inner_y2 - jetson_inner_y1
        jetson_flow_height = max(82.0, min(155.0, jetson_available * 0.38))
        self._horizontal_blocks(
            (jx1 + 16, jetson_inner_y1, jx2 - 16, jetson_inner_y1 + jetson_flow_height),
            (
                ("AES-GCM\n암호화", ("jetson_face", "jetson_ack")),
                ("FACE ID\n출입문 제어", ("jetson_face", "jetson_door")),
                ("AES-GCM\n복호화", "jetson_door"),
            ),
        )
        self._key_derivation((jx1 + 16, jetson_inner_y1 + jetson_flow_height + 18, jx2 - 16, jetson_inner_y2))

        px1, py1, px2, py2 = pc
        pc_inner_y1, pc_inner_y2 = py1 + 47, py2 - 14
        pc_available = pc_inner_y2 - pc_inner_y1
        pc_flow_height = max(72.0, min(96.0, pc_available * 0.36))
        self._horizontal_blocks(
            (px1 + 16, pc_inner_y1, px2 - 16, pc_inner_y1 + pc_flow_height),
            (
                ("OPEN/CLOSE\n사용자 정보", "pc_uart"),
                ("AES-GCM FRAME\n생성/해석", ("pc_uart", "pc_uart_up")),
                ("UART\n송수신", "pc_uart_up"),
            ),
        )
        self._key_derivation((px1 + 16, pc_inner_y1 + pc_flow_height + 14, px2 - 16, pc_inner_y2))

        zx1, zy1, zx2, zy2 = zybo
        inner_y1, inner_y2 = zy1 + 47, zy2 - 14
        zybo_available = inner_y2 - inner_y1
        zybo_flow_height = max(82.0, min(155.0, zybo_available * 0.38))
        self._horizontal_blocks(
            (zx1 + 16, inner_y1, zx2 - 16, inner_y1 + zybo_flow_height),
            (
                ("AES-GCM 복호화\nGCM TAG 검증", "zybo_decrypt"),
                ("명령/Face ID\n세션키 관리", "zybo_command"),
                ("AES-GCM 암호화\nUART/SPI 송신", "zybo_encrypt"),
            ),
        )
        self._key_derivation((zx1 + 16, inner_y1 + zybo_flow_height + 18, zx2 - 16, inner_y2))

        bx1, by1, bx2, by2 = basys
        basys_inner_y1, basys_inner_y2 = by1 + 47, by2 - 14
        basys_available = basys_inner_y2 - basys_inner_y1
        basys_flow_height = max(82.0, min(155.0, basys_available * 0.38))
        self._horizontal_blocks(
            (bx1 + 16, basys_inner_y1, bx2 - 16, basys_inner_y1 + basys_flow_height),
            (
                ("AES-GCM\n복호화", "basys_spi"),
                ("RACK SERVO\n제어", "basys_spi"),
                ("AES-GCM\n암호화", "basys_return"),
            ),
        )
        self._key_derivation((bx1 + 16, basys_inner_y1 + basys_flow_height + 18, bx2 - 16, basys_inner_y2))

        # Inter-device physical links. Active commands illuminate one link/stage at a time.
        link_y = (jy1 + jy2) / 2
        zybo_link_y = (zy1 + zy2) / 2
        self._duplex_link((jx2, link_y), (zx1, zybo_link_y), ("jetson_face", "jetson_ack"), "jetson_door", "SPI")
        self._duplex_vertical(((px1 + px2) / 2, py2), ((zx1 + zx2) / 2, zy1), "pc_uart", "pc_uart_up", "UART")
        self._duplex_link((zx2, (zy1 + zy2) / 2), (bx1, (by1 + by2) / 2), "basys_spi", "basys_return", "SPI")

    def refresh(self) -> None:
        self._redraw_pending = False
        self._redraw()

class MonitorPage(tk.Frame):
    """Full CCTV at rest; centered Face ID card only while a person is detected."""

    def __init__(self, parent, app: "AigisApp") -> None:
        super().__init__(parent, bg=BG)
        self.pack_propagate(False)
        self.app = app
        self.header = Header(self, "A.I.G.I.S", app, "monitor")
        self.header.pack(fill="x")
        stage = tk.Frame(self, bg=BG)
        stage.pack(fill="both", expand=True, padx=15, pady=(8, 14))
        stage.pack_propagate(False)
        self.stage = stage
        channels = tk.Frame(stage, bg=BG)
        channels.place(relx=0, rely=0, relwidth=1, relheight=1)
        channels.grid_propagate(False)
        channels.grid_columnconfigure(0, weight=1, uniform="monitor")
        channels.grid_columnconfigure(1, weight=1, uniform="monitor")
        channels.grid_rowconfigure(0, weight=1)
        monitor_active = lambda: app.split_windows or app.current_page == "monitor"
        self.cctv = CameraPanel(
            channels,
            "PCAM CH-A · 정상 MASTER KEY · 복호화 성공",
            app.pcam_ch_a_stream,
            center_title=True,
            title_font_size=28,
            active_check=monitor_active,
        )
        self.cctv.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        self.secure_camera = CameraPanel(
            channels,
            "PCAM CH-B · MASTER KEY 전환 시험",
            app.pcam_ch_b_stream,
            center_title=True,
            title_font_size=28,
            active_check=monitor_active,
        )
        self.secure_camera.grid(row=0, column=1, sticky="nsew", padx=(6, 0))
        # If the wrong session key makes CH-B undecodable, keep the last normal
        # CH-A image as a visual source so the demonstration shows corruption
        # instead of an empty/hidden screen.
        self.secure_camera.distortion_fallback = lambda: self.cctv.last_frame
        self.normal_master_hex = MASTER_KEY.hex().upper()
        wrong_master = bytes((MASTER_KEY[0] ^ 0x01,)) + MASTER_KEY[1:]
        self.wrong_master_hex = wrong_master.hex().upper()
        
        # Persistent Key Panels for both channels
        self.ch_a_key_panel = tk.Frame(self.cctv.info_area, bg=PANEL, highlightthickness=1, highlightbackground=GREEN)
        ch_a_row = tk.Frame(self.ch_a_key_panel, bg="#011f15")
        ch_a_row.pack(fill="x")
        tk.Label(ch_a_row, text=self.normal_master_hex, bg="#011f15", fg=GREEN, font=("Consolas", 14, "bold")).pack(side="left", padx=15, pady=8)
        tk.Label(ch_a_row, text="[ 정상 마스터키 ]", bg="#011f15", fg=GREEN, font=("Malgun Gothic", 14, "bold")).pack(side="right", padx=15, pady=8)
        self.ch_a_key_panel.pack(fill="x", padx=30, expand=True)

        self.ch_b_key_panel = tk.Frame(self.secure_camera.info_area, bg=PANEL, highlightthickness=1, highlightbackground=GREEN)
        self.ch_b_normal_row = tk.Frame(self.ch_b_key_panel, bg="#011f15", cursor="hand2")
        self.ch_b_normal_row.pack(fill="x")
        lbl_norm_hex = tk.Label(self.ch_b_normal_row, text=self.normal_master_hex, bg="#011f15", fg=GREEN, font=("Consolas", 14, "bold"), cursor="hand2")
        lbl_norm_hex.pack(side="left", padx=15, pady=8)
        lbl_norm_text = tk.Label(self.ch_b_normal_row, text="[ 정상 마스터키 ]", bg="#011f15", fg=GREEN, font=("Malgun Gothic", 14, "bold"), cursor="hand2")
        lbl_norm_text.pack(side="right", padx=15, pady=8)
        
        self.ch_b_bad_row = tk.Frame(self.ch_b_key_panel, bg="#2b0a0a", cursor="hand2")
        self.ch_b_bad_row.pack(fill="x")
        self.bad_key_hex_label = tk.Label(self.ch_b_bad_row, text="마스터키 변경", bg="#2b0a0a", fg=RED, font=("Malgun Gothic", 14, "bold"), cursor="hand2")
        self.bad_key_hex_label.pack(side="left", padx=15, pady=8)
        lbl_bad_text = tk.Label(self.ch_b_bad_row, text="[ 비정상 키 ]", bg="#2b0a0a", fg=RED, font=("Malgun Gothic", 14, "bold"), cursor="hand2")
        lbl_bad_text.pack(side="right", padx=15, pady=8)
        self.ch_b_key_panel.pack(fill="x", padx=30, expand=True)
        
        # Bindings for selection
        def select_normal(e): self.set_video_key_mode(False)
        def select_bad(e): self.set_video_key_mode(True)
        
        for w in [self.ch_b_normal_row, lbl_norm_hex, lbl_norm_text]:
            w.bind("<Button-1>", select_normal)
        for w in [self.ch_b_bad_row, self.bad_key_hex_label, lbl_bad_text]:
            w.bind("<Button-1>", select_bad)
        self.good_block = tk.Frame(channels, bg="#08131f", highlightthickness=2, highlightbackground=ORANGE)
        self.good_block.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        tk.Label(self.good_block, text="🔐", bg="#08131f", fg=ORANGE, font=("Segoe UI Emoji", 45)).place(relx=0.5, rely=0.38, anchor="center")
        tk.Label(self.good_block, text="SECURE SESSION WAIT", bg="#08131f", fg=ORANGE, font=("Segoe UI", 23, "bold")).place(relx=0.5, rely=0.50, anchor="center")
        self.good_block_message = tk.Label(self.good_block, text="정상 마스터키 · 난수 교환 대기", bg="#08131f", fg="#ffd39b", font=("Malgun Gothic", 14, "bold"))
        self.good_block_message.place(relx=0.5, rely=0.57, anchor="center")
        
        self.video_invalid_mode = False
        self.session_invalid_mode = False
        # self.bad_block.grid_remove()

        self.cctv_badge = tk.Label(
            stage,
            text="● REC   |   CCTV 전체 감시 중",
            bg="#061325",
            fg=TEXT,
            font=("Malgun Gothic", 9, "bold"),
            padx=13,
            pady=7,
        )
        self.cctv_badge.place(relx=0.012, rely=0.965, anchor="sw")

        self.face_overlay = tk.Frame(stage, bg="#07182a", highlightthickness=3, highlightbackground=CYAN)
        self.face_overlay.pack_propagate(False)
        overlay_head = tk.Frame(self.face_overlay, bg="#07182a", height=48)
        overlay_head.pack(fill="x")
        overlay_head.pack_propagate(False)
        tk.Label(overlay_head, text="출입자 FACE ID", bg="#07182a", fg=CYAN, font=("Malgun Gothic", 16, "bold")).pack(side="left", padx=16)
        self.face_status = tk.Label(overlay_head, text="인증 확인 중", bg="#0a2943", fg=CYAN, font=("Malgun Gothic", 11, "bold"), padx=14, pady=6)
        self.face_status.pack(side="right", padx=12, pady=8)
        info = tk.Frame(self.face_overlay, bg="#061426", padx=15, pady=10)
        info.pack(side="bottom", fill="x", padx=12, pady=(0, 12))
        self.face_camera = CameraPanel(
            self.face_overlay,
            "FACE CAMERA LIVE",
            app.face_stream,
            compact=True,
            active_check=lambda: (app.split_windows or app.current_page == "monitor") and self.face_overlay.winfo_ismapped(),
            frame_interval_ms=40,
        )
        self.face_camera.info_area.pack_forget()
        self.face_camera.pack(side="top", fill="both", expand=True, padx=12, pady=(0, 8))
        self.info_labels = {}
        for column, (key, label) in enumerate((("name", "이름"), ("department", "부서"), ("position", "직책"), ("racks", "관리 RACK"))):
            item = tk.Frame(info, bg="#061426")
            item.grid(row=column // 2, column=column % 2, sticky="ew", padx=8, pady=5)
            info.grid_columnconfigure(column % 2, weight=1)
            tk.Label(item, text=label, width=9, anchor="w", bg="#061426", fg=MUTED, font=("Malgun Gothic", 10)).pack(side="left")
            value = tk.Label(item, text="-", anchor="w", bg="#061426", fg=TEXT, font=("Malgun Gothic", 11, "bold"))
            value.pack(side="left", fill="x", expand=True)
            self.info_labels[key] = value
        self._hide_job = None
        self._face_animation_job = None
        self._face_animation_generation = 0

    def set_security(self, text: str, color: str) -> None:
        self.header.set_security(text, color)

    def run_wrong_master_video_test(self) -> None:
        self.set_video_key_mode(True)

    def set_video_key_mode(self, invalid: bool) -> None:
        """Switch CH-B between the visible normal feed and wrong-key blocking."""
        self.video_invalid_mode = invalid
        # Static is exclusively a manual wrong-master-key effect.  Automatic
        # handshake/session state changes must never enable it.
        self.secure_camera.jpeg_error_sim = invalid
        
        if invalid:
            if self.secure_camera.last_frame is None:
                self.secure_camera.last_frame = self.cctv.last_frame
            self.app.tcp_stream.set_b_master_key(self.app.wrong_master_key)
            self.secure_camera.custom_error_msg = "마스터키 불일치 · 인증 실패"
            
            self.ch_b_key_panel.config(highlightbackground=RED)
            # Make normal row look inactive (muted)
            for w in self.ch_b_normal_row.winfo_children():
                if isinstance(w, tk.Label): w.config(fg="#234a38")
            # Make bad row look active
            for w in self.ch_b_bad_row.winfo_children():
                if isinstance(w, tk.Label): w.config(fg=RED)
        else:
            from secure_serial_client import MASTER_KEY
            self.app.tcp_stream.set_b_master_key(MASTER_KEY)
            self.secure_camera.custom_error_msg = ""
            
            self.ch_b_key_panel.config(highlightbackground=GREEN)
            # Make normal row look active
            for w in self.ch_b_normal_row.winfo_children():
                if isinstance(w, tk.Label): w.config(fg=GREEN)
            # Make bad row look inactive (muted)
            for w in self.ch_b_bad_row.winfo_children():
                if isinstance(w, tk.Label): w.config(fg="#4a1c1c")


    def set_secure_video_allowed(self, allowed: bool, message: str = "") -> None:
        # Session events do not alter the picture.  The separate 30-second
        # dropout owns the plain-black interruption, while static remains a
        # manual wrong-master-key effect only.
        self.session_invalid_mode = not allowed
        self.good_block.grid_remove()
        self.secure_camera.jpeg_error_sim = self.video_invalid_mode
        if self.video_invalid_mode:
            self.secure_camera.custom_error_msg = "마스터키 불일치 · 인증 실패"
        else:
            self.secure_camera.custom_error_msg = ""
        self.secure_camera.invalidate()

    @staticmethod
    def _normalized_face_meshes(live_points, db_points, target_span: float):
        """Return index-aligned, centered point clouds in one visual scale."""
        try:
            live = np.asarray(live_points, dtype=np.float32)
            db = np.asarray(db_points, dtype=np.float32)
            if live.ndim != 2 or db.ndim != 2 or live.shape[1] < 2 or db.shape[1] < 2:
                return None, None
            count = min(len(live), len(db), 468)
            if count < 3:
                return None, None
            live = live[:count, :3]
            db = db[:count, :3]
            if live.shape[1] == 2:
                live = np.column_stack((live, np.zeros(count, dtype=np.float32)))
            if db.shape[1] == 2:
                db = np.column_stack((db, np.zeros(count, dtype=np.float32)))
            if not np.isfinite(live).all() or not np.isfinite(db).all():
                return None, None

            nose_index = 1 if count > 1 else 0
            live = live - live[nose_index]
            db = db - db[nose_index]

            def scale_cloud(points):
                span = max(float(np.ptp(points[:, 0])), float(np.ptp(points[:, 1])), 1e-6)
                scaled = points * (target_span / span)
                depth_span = float(np.ptp(scaled[:, 2]))
                if depth_span > 1e-6:
                    scaled[:, 2] *= (target_span * 0.24) / depth_span
                scaled[:, 2] = np.clip(scaled[:, 2], -target_span * 0.35, target_span * 0.35)
                return scaled

            live = scale_cloud(live)
            db = scale_cloud(db)

            # Align screen-plane roll without tilting either model out of its
            # camera coordinate plane. A full 3D Kabsch rotation changed the
            # apparent size after perspective projection.
            covariance = live[:, :2].T @ db[:, :2]
            u, _, vt = np.linalg.svd(covariance)
            rotation = u @ vt
            if np.linalg.det(rotation) < 0:
                u[:, -1] *= -1
                rotation = u @ vt
            live[:, :2] = live[:, :2] @ rotation

            # Roll alignment can change the axis-aligned bounds slightly.
            # Normalize both once more so their displayed width/depth scale is
            # identical before the approach animation begins.
            live = scale_cloud(live)
            db = scale_cloud(db)

            # The server's 3D axes use the opposite orientation from the
            # corrected recognition snapshot. Rotate both point clouds 90
            # degrees in the required screen direction.
            live_x = live[:, 0].copy()
            db_x = db[:, 0].copy()
            live[:, 0] = live[:, 1]
            live[:, 1] = -live_x
            db[:, 0] = db[:, 1]
            db[:, 1] = -db_x
            return live, db
        except (TypeError, ValueError, np.linalg.LinAlgError):
            return None, None

    @staticmethod
    def _mesh_triangles(points: np.ndarray, width: int, height: int) -> list[tuple[int, int, int]]:
        """Build Delaunay topology once; animation frames reuse the indices."""
        if points is None or len(points) < 3:
            return []
        shifted = points[:, :2] + np.array((width / 2, height / 2), dtype=np.float32)
        subdivision = cv2.Subdiv2D((0, 0, width, height))
        for x, y in shifted:
            if 1 <= x < width - 1 and 1 <= y < height - 1:
                try:
                    subdivision.insert((float(x), float(y)))
                except cv2.error:
                    pass
        raw = subdivision.getTriangleList()
        if raw is None or len(raw) == 0:
            return []
        triangles = set()
        max_edge_sq = (min(width, height) * 0.34) ** 2
        for triangle in raw.reshape(-1, 3, 2):
            indices = []
            for vertex in triangle:
                distances = np.sum((shifted - vertex) ** 2, axis=1)
                index = int(np.argmin(distances))
                if distances[index] > 9.0:
                    indices = []
                    break
                indices.append(index)
            if len(set(indices)) != 3:
                continue
            vertices = shifted[indices]
            edge_sq = [
                float(np.sum((vertices[0] - vertices[1]) ** 2)),
                float(np.sum((vertices[1] - vertices[2]) ** 2)),
                float(np.sum((vertices[2] - vertices[0]) ** 2)),
            ]
            if max(edge_sq) <= max_edge_sq:
                triangles.add(tuple(indices))
        return list(triangles)

    @staticmethod
    def _project_face_mesh(points: np.ndarray, angle: float, center, offset_x: float, distance: float):
        cosine, sine = np.cos(angle), np.sin(angle)
        x = points[:, 0]
        y = points[:, 1]
        z = points[:, 2]
        rotated_x = x * cosine + z * sine
        rotated_z = -x * sine + z * cosine
        perspective = distance / np.maximum(distance + rotated_z, distance * 0.25)
        projected_x = center[0] + offset_x + rotated_x * perspective
        projected_y = center[1] + y * perspective
        return np.column_stack((projected_x, projected_y)).astype(np.int32)

    @staticmethod
    def _draw_projected_mesh(frame, projected, triangles, color):
        height, width = frame.shape[:2]
        if triangles:
            visible = []
            for triangle in triangles:
                polygon = projected[list(triangle)]
                if (
                    (polygon[:, 0] >= 0).all()
                    and (polygon[:, 0] < width).all()
                    and (polygon[:, 1] >= 0).all()
                    and (polygon[:, 1] < height).all()
                ):
                    visible.append(polygon)
            if visible:
                cv2.polylines(frame, np.asarray(visible, dtype=np.int32), True, color, 1, cv2.LINE_AA)
        for x, y in projected:
            if 0 <= x < width and 0 <= y < height:
                cv2.circle(frame, (int(x), int(y)), 1, color, -1, cv2.LINE_AA)

    def _stop_face_animation(self) -> None:
        self._face_animation_generation += 1
        if self._face_animation_job is not None:
            try:
                self.after_cancel(self._face_animation_job)
            except tk.TclError:
                pass
            self._face_animation_job = None
        self.face_camera.animation_frame = None

    def _start_face_animation(self, authorized: bool, tcp_json: dict) -> None:
        self._stop_face_animation()
        image_b64 = tcp_json.get("image_jpeg_b64", "")
        if not image_b64:
            return
        try:
            import base64
            image_data = base64.b64decode(image_b64, validate=True)
            base_frame = cv2.imdecode(np.frombuffer(image_data, np.uint8), cv2.IMREAD_COLOR)
        except (ValueError, TypeError):
            return
        if base_frame is None:
            return
        # The Lock System recognition JPEG uses the camera's native mounting
        # orientation. Match the live Face TCP stream, which is corrected the
        # same way in TCPFaceClient.
        base_frame = cv2.rotate(base_frame, cv2.ROTATE_90_CLOCKWISE)

        self.face_camera.face_tint = None if authorized else (255, 0, 0)
        if not authorized:
            self.face_camera.animation_frame = base_frame
            return

        info_3d = tcp_json.get("info_3d") or {}
        live, db = self._normalized_face_meshes(
            info_3d.get("landmarks_3d_pts", []),
            info_3d.get("db_registered_3d_pts", []),
            target_span=min(base_frame.shape[:2]) * 0.52,
        )
        if live is None or db is None:
            self.face_camera.animation_frame = base_frame
            return

        height, width = base_frame.shape[:2]
        triangles = self._mesh_triangles(db, width, height)
        center = (width / 2, height / 2)
        distance = max(width, height) * 1.6
        motion_frames = 40
        generation = self._face_animation_generation

        def render(step=0):
            if generation != self._face_animation_generation:
                return
            progress = min(step / max(motion_frames - 1, 1), 1.0)
            eased = 1.0 - (1.0 - progress) ** 3
            separation = width * 0.24 * (1.0 - eased)
            angle = np.deg2rad(38.0 * (1.0 - eased))
            frame = base_frame.copy()
            live_projected = self._project_face_mesh(live, angle, center, -separation, distance)
            db_projected = self._project_face_mesh(db, -angle, center, separation, distance)
            mesh_overlay = frame.copy()
            self._draw_projected_mesh(mesh_overlay, live_projected, triangles, (255, 230, 0))
            self._draw_projected_mesh(mesh_overlay, db_projected, triangles, (0, 255, 80))
            frame = cv2.addWeighted(mesh_overlay, 0.5, frame, 0.5, 0.0)
            cv2.putText(frame, "LIVE 3D", (18, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 230, 0), 2, cv2.LINE_AA)
            cv2.putText(frame, "DB 3D", (width - 105, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 255, 80), 2, cv2.LINE_AA)
            if progress >= 1.0:
                cv2.putText(frame, "3D CONTOUR MATCH", (max(12, width // 2 - 115), height - 22), cv2.FONT_HERSHEY_SIMPLEX, 0.68, (80, 255, 120), 2, cv2.LINE_AA)
            self.face_camera.animation_frame = frame
            if step + 1 < motion_frames:
                self._face_animation_job = self.after(35, render, step + 1)
            else:
                # Keep the final overlap visible until the Face ID card closes.
                self._face_animation_job = None

        render()

    def show_face(self, authorized: bool, user_id: str, information: dict | None, tcp_json: dict | None = None) -> None:
        information = information or {}
        self.face_status.config(
            text="인가 사용자" if authorized and information else "비인가 사용자",
            bg="#073523" if authorized and information else "#4a1218",
            fg=GREEN if authorized and information else RED,
        )
        self.info_labels["name"].config(text=information.get("name", user_id or "UNKNOWN"))
        self.info_labels["department"].config(text=information.get("department", "-"))
        self.info_labels["position"].config(text=information.get("position", "-"))
        racks = [name.replace("RACK-0", "") for name, allowed in information.get("rack_control", {}).items() if allowed]
        self.info_labels["racks"].config(text=", ".join(racks) if racks else "-")
        if tcp_json:
            self._start_face_animation(authorized, tcp_json)
        else:
            self._stop_face_animation()

        stage_width = max(640, self.stage.winfo_width())
        stage_height = max(520, self.stage.winfo_height())
        overlay_width = min(760, stage_width - 24)
        overlay_height = min(610, stage_height - 24)
        self.face_overlay.place(
            relx=0.5,
            rely=0.5,
            width=overlay_width,
            height=overlay_height,
            anchor="center",
        )
        self.face_overlay.lift()
        if self._hide_job:
            self.after_cancel(self._hide_job)
        seconds = int(self.app.config.get("face_overlay_seconds", 8))
        self._hide_job = self.after(seconds * 1000, self.hide_face)

    def hide_face(self) -> None:
        self._stop_face_animation()
        self.face_camera.animation_frame = None
        self.face_overlay.place_forget()
        self._hide_job = None

    def on_show(self) -> None:
        self.cctv.invalidate()
        self.secure_camera.invalidate()
        if self.face_overlay.winfo_ismapped():
            self.face_camera.invalidate()


class RackCard(tk.Frame):
    def __init__(self, parent, rack_number: int, image: Image.Image, command, compact: bool = False) -> None:
        super().__init__(parent, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        self.rack_number = rack_number
        self.command = command
        self.compact = compact
        self.base_image = image
        self.alarm_level = 0
        self.fire_active = False
        self.opened = False
        self._open_fraction = 0.0
        self._animation_job = None
        self._pulse_on = False

        head = tk.Frame(self, bg=PANEL)
        head.pack(fill="x", padx=11, pady=(7, 3))
        tk.Label(head, text=f"RACK {rack_number}", bg=PANEL, fg=TEXT, font=("Segoe UI", 17 if compact else 14, "bold")).pack(side="left")
        self.health = tk.Label(head, text="● 정상", bg=PANEL, fg=GREEN, font=("Malgun Gothic", 10 if compact else 8, "bold"))
        self.health.pack(side="right")
        self.image_label = tk.Label(self, bg="#010711", height=180 if compact else 185)
        self.image_label.pack(fill="x", padx=8, pady=3)
        self.image_label.pack_propagate(False)

        readings = tk.Frame(self, bg=PANEL)
        readings.pack(fill="x", padx=8, pady=(3, 0))
        self.temperature = self._reading(readings, "온도", "--℃", compact)
        self.humidity = self._reading(readings, "습도", "--%", compact)
        self.state = tk.Label(self, text="CLOSE", bg="#10243d", fg=CYAN, font=("Segoe UI", 20 if compact else 17, "bold"), pady=5 if compact else 3)
        self.state.pack(fill="x", padx=8, pady=4)
        controls = tk.Frame(self, bg=PANEL)
        controls.pack(pady=(0, 7))
        button(controls, "OPEN", lambda: command(rack_number, True), "#0d6b3d", 8, 11 if compact else 9, 7 if compact else 5).pack(side="left", padx=4)
        button(controls, "CLOSE", lambda: command(rack_number, False), "#8c1f29", 8, 11 if compact else 9, 7 if compact else 5).pack(side="left", padx=4)
        self._render_image()

    @staticmethod
    def _reading(parent, label: str, initial: str, compact: bool = False):
        box = tk.Frame(parent, bg=PANEL)
        box.pack(side="left", fill="x", expand=True)
        value = tk.Label(box, text=initial, bg=PANEL, fg=CYAN, font=("Segoe UI", 24 if compact else 19, "bold"))
        value.pack()
        tk.Label(box, text=label, bg=PANEL, fg=MUTED, font=("Malgun Gothic", 11 if compact else 8)).pack()
        return value

    def _render_image(self, open_fraction: float | None = None) -> None:
        fraction = self._open_fraction if open_fraction is None else open_fraction
        if self.compact:
            size = (150, 190) if self.alarm_level else (136, 176)
            canvas_width, canvas_height = 225, 185
            rack_x = 36 if self.alarm_level else 42
        else:
            size = (155, 195) if self.alarm_level else (138, 180)
            canvas_width, canvas_height = 225, 195
            rack_x = 39 if self.alarm_level else 44
        image = self.base_image.copy()
        image.thumbnail(size, Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (canvas_width, canvas_height), (0, 0, 0, 0))
        rack_y = max(0, (canvas_height - image.height) // 2)
        canvas.alpha_composite(image, (rack_x, rack_y))
        if fraction > 0.02:
            draw = ImageDraw.Draw(canvas, "RGBA")
            # The hinge follows the left edge of the rack's front face.  The
            # door therefore swings toward the viewer/left instead of looking
            # like a removable side panel.
            hinge_x = rack_x + int(image.width * 0.37)
            top_y = rack_y + int(image.height * 0.10)
            bottom_y = rack_y + int(image.height * 0.91)
            swing = int((48 if self.compact else 68) * fraction)
            far_x = hinge_x - swing
            perspective = int(8 * fraction)
            draw.polygon(
                ((hinge_x, top_y), (far_x, top_y + perspective), (far_x, bottom_y - perspective), (hinge_x, bottom_y)),
                fill=(5, 20, 33, 150),
                outline=(48, 184, 232, 220),
                width=2,
            )
            for ratio in (0.25, 0.5, 0.75):
                y_left = top_y + (bottom_y - top_y) * ratio
                y_far = top_y + perspective + (bottom_y - top_y - perspective * 2) * ratio
                draw.line((hinge_x, y_left, far_x, y_far), fill=(25, 103, 139, 150), width=1)
            draw.line((far_x + 4, top_y + perspective + 10, far_x + 4, bottom_y - perspective - 10), fill=(110, 205, 238, 210), width=2)
        photo = ImageTk.PhotoImage(canvas)
        self.image_label.config(image=photo, bg="#2a0710" if self.alarm_level else "#010711")
        self.image_label.image = photo

    def set_open(self, opened: bool) -> None:
        if self.opened == opened and self._open_fraction in (0.0, 1.0):
            return
        self.opened = opened
        if self.alarm_level or self.fire_active:
            return
        if self._animation_job:
            self.after_cancel(self._animation_job)
        self.state.config(text="OPENING..." if opened else "CLOSING...", bg="#0b3150", fg=ORANGE)
        target = 1.0 if opened else 0.0
        start = self._open_fraction
        steps = 10

        def animate(step: int = 1) -> None:
            progress = step / steps
            self._open_fraction = start + (target - start) * progress
            self._render_image()
            if step < steps:
                self._animation_job = self.after(45, lambda: animate(step + 1))
            else:
                self._animation_job = None
                self._open_fraction = target
                self.state.config(
                    text="OPEN" if opened else "CLOSE",
                    bg="#073b27" if opened else "#10243d",
                    fg=GREEN if opened else CYAN,
                )

        animate()

    def set_sensor(self, temperature: int, humidity: int, fire: bool) -> None:
        self.fire_active = fire
        self.temperature.config(text=f"{temperature}℃", fg=RED if fire else CYAN)
        self.humidity.config(text=f"{humidity}%", fg=RED if fire else CYAN)
        if fire:
            self.health.config(text="● 화재 발생", fg=RED)
            self.state.config(text="화재 발생", bg="#a41428", fg="white")
        elif self.alarm_level:
            self.health.config(text="▲ 비전 이상 감지", fg=RED)
            self.state.config(text="비전 이상", bg="#7d111b", fg="white")
        else:
            self.health.config(text="● 정상", fg=GREEN)
            self.state.config(
                text="OPEN" if self.opened else "CLOSE",
                bg="#073b27" if self.opened else "#10243d",
                fg=GREEN if self.opened else CYAN,
            )

    def set_alarm(self, level: int) -> None:
        if self.alarm_level == level:
            return
        self.alarm_level = level
        if level:
            if not self.fire_active:
                self.health.config(text="▲ 비전 이상 감지", fg=RED)
                self.state.config(text="비전 이상", bg="#7d111b", fg="white")
            self.config(highlightthickness=4, highlightbackground=RED)
            self._pulse_alarm()
        else:
            if not self.fire_active:
                self.health.config(text="● 정상", fg=GREEN)
                self.state.config(
                    text="OPEN" if self.opened else "CLOSE",
                    bg="#073b27" if self.opened else "#10243d",
                    fg=GREEN if self.opened else CYAN,
                )
            self.config(highlightthickness=1, highlightbackground=BORDER)
        self._render_image()

    def _pulse_alarm(self) -> None:
        if not self.alarm_level:
            return
        self._pulse_on = not self._pulse_on
        self.config(highlightbackground="#ff7b82" if self._pulse_on else RED)
        self.after(480, self._pulse_alarm)


class RackPage(tk.Frame):
    def __init__(self, parent, app: "AigisApp") -> None:
        super().__init__(parent, bg=BG)
        self.app = app
        self._vision_alert_active = False
        self._alert_job = None
        self.header = Header(self, "A.I.G.I.S", app, "racks")
        self.header.pack(fill="x")

        body = tk.Frame(self, bg=BG)
        body.pack(fill="both", expand=True, padx=14, pady=(8, 12))
        body.grid_columnconfigure(0, weight=1, uniform="rack_page")
        body.grid_columnconfigure(1, weight=2, uniform="rack_page")
        body.grid_rowconfigure(0, weight=1)

        control_panel = tk.Frame(body, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        control_panel.grid(row=0, column=0, sticky="nsew", padx=(0, 7))
        tk.Label(control_panel, text="RACK CONTROL", bg=PANEL, fg=CYAN, font=("Segoe UI", 36, "bold")).pack(fill="x", pady=(10, 7))

        rack_grid = tk.Frame(control_panel, bg=PANEL)
        rack_grid.pack(fill="both", expand=True, padx=8, pady=(0, 7))
        for index in range(2):
            rack_grid.grid_columnconfigure(index, weight=1, uniform="rack_control")
            rack_grid.grid_rowconfigure(index, weight=1, uniform="rack_control")
        source = Image.open(ASSET_DIR / "server_rack_v2.png").convert("RGBA")
        self.cards = []
        for index in range(4):
            card = RackCard(rack_grid, index + 1, source, app.set_rack, compact=True)
            card.grid(row=index // 2, column=index % 2, sticky="nsew", padx=4, pady=4)
            self.cards.append(card)

        controls = tk.Frame(control_panel, bg=PANEL, padx=8, pady=6)
        controls.pack(fill="x")

        def control_row(label: str, open_text: str, open_command, close_text: str, close_command) -> None:
            row = tk.Frame(controls, bg="#091d34", highlightthickness=1, highlightbackground=BORDER)
            row.pack(fill="x", pady=3)
            tk.Label(row, text=label, width=11, anchor="w", bg="#091d34", fg=TEXT, font=("Malgun Gothic", 13, "bold")).pack(side="left", padx=10)
            button(row, open_text, open_command, "#0d6b3d", 10, 11, 6).pack(side="left", padx=4, pady=5, expand=True, fill="x")
            button(row, close_text, close_command, "#8c1f29", 10, 11, 6).pack(side="left", padx=4, pady=5, expand=True, fill="x")

        control_row("출입문", "OPEN", lambda: app.set_door(True), "CLOSE", lambda: app.set_door(False))
        control_row("전체 RACK", "ALL OPEN", lambda: app.set_all_racks(True), "ALL CLOSE", lambda: app.set_all_racks(False))
        
        monitoring = tk.Frame(body, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        monitoring.grid(row=0, column=1, sticky="nsew", padx=(7, 0))
        tk.Label(monitoring, text="MONITORING", bg=PANEL, fg=CYAN, font=("Segoe UI", 36, "bold")).pack(fill="x", pady=(10, 4))
        
        bottom_controls = tk.Frame(monitoring, bg=PANEL)
        bottom_controls.pack(side="bottom", fill="x", padx=8, pady=(0, 8))

        control_bar = tk.Frame(bottom_controls, bg="#061425", highlightthickness=1, highlightbackground=BORDER)
        control_bar.pack(fill="x")

        key_select = tk.Frame(control_bar, bg="#071d31")
        key_select.pack(side="left", fill="y", padx=10, pady=5)
        tk.Label(key_select, text="MASTER KEY 선택", bg="#071d31", fg=CYAN, font=("Malgun Gothic", 16, "bold")).pack(side="left", padx=15)
        self.normal_key_button = button(key_select, "현재 마스터키", lambda: app.set_command_key_mode(False), "#0d6b3d", 13, 16, 7)
        self.normal_key_button.pack(side="left", padx=5, pady=5)
        self.fake_key_button = button(key_select, "가짜 마스터키", lambda: app.set_command_key_mode(True), "#4b2230", 13, 16, 7)
        self.fake_key_button.pack(side="left", padx=5, pady=5)

        self.key_mode_value = tk.Label(
            control_bar,
            text=f"현재 마스터키  {MASTER_KEY.hex().upper()}",
            bg="#061425",
            fg=GREEN,
            font=("Consolas", 15, "bold")
        )
        self.key_mode_value.pack(side="left", expand=True)

        attack = tk.Frame(control_bar, bg="#2a0b14")
        attack.pack(side="right", fill="y", padx=10, pady=5)
        tk.Label(attack, text="보안 공격 시험", bg="#2a0b14", fg=RED, font=("Malgun Gothic", 16, "bold")).pack(side="left", padx=15)
        button(attack, "INVALID KEY 전송", app.run_invalid_key_test, "#a41428", 16, 16, 7).pack(side="right", padx=7, pady=5)

        self.security_flow = SecurityFlowPanel(
            monitoring,
            active_check=lambda: app.split_windows or app.current_page == "racks",
        )
        self.security_flow.pack(fill="both", expand=True, padx=8, pady=(0, 8))
        self.log = self.security_flow.log

        self.alert = tk.Frame(self, bg="#3b0a12", highlightthickness=4, highlightbackground=RED)
        self.alert_title = tk.Label(self.alert, text="", bg="#3b0a12", fg=RED, font=("Malgun Gothic", 25, "bold"))
        self.alert_title.pack(padx=30, pady=(22, 7))
        self.alert_message = tk.Label(self.alert, text="", bg="#3b0a12", fg="white", font=("Malgun Gothic", 17, "bold"))
        self.alert_message.pack(padx=30, pady=(0, 22))

    def on_show(self) -> None:
        self.after_idle(self.security_flow.refresh)

    def set_security(self, text: str, color: str) -> None:
        self.header.set_security(text, color)

    def set_key_mode(self, invalid: bool, key_hex: str) -> None:
        self.normal_key_button.config(bg="#0d6b3d" if not invalid else "#173047")
        self.fake_key_button.config(bg="#a41428" if invalid else "#4b2230")
        self.key_mode_value.config(
            text=f"{'가짜' if invalid else '현재'} 마스터키  {key_hex}",
            fg=RED if invalid else GREEN,
        )

    def update_rack_mask(self, mask: int) -> None:
        for index, card in enumerate(self.cards):
            card.set_open(bool(mask & (1 << index)))

    def update_sensors(self, event: dict) -> None:
        threshold = int(self.app.config.get("fire_threshold", 30))
        for index, card in enumerate(self.cards):
            temperature = event["temperatures"][index]
            fire = bool(event["fire_mask"] & (1 << index)) or temperature >= threshold
            card.set_sensor(temperature, event["humidities"][index], fire)
        alarm_level = max(event["camera_states"])
        self.cards[3].set_alarm(alarm_level if alarm_level >= 2 else 0)
        abnormal = alarm_level >= 2
        if abnormal and not self._vision_alert_active:
            self.show_alert("4번 RACK 비전 이상 감지", "OV7670 영상에서 비정상 상태가 감지되었습니다.", RED, 5000)
        self._vision_alert_active = abnormal

    def show_alert(self, title: str, message: str, color: str = RED, duration_ms: int = 4000) -> None:
        if self._alert_job:
            self.after_cancel(self._alert_job)
        self.alert.config(highlightbackground=color)
        self.alert_title.config(text=title, fg=color)
        self.alert_message.config(text=message, wraplength=740 if message else 0, justify="center")
        popup_height = 120 if not message else 165
        popup_width = 520 if not message else 820
        self.alert.place(relx=0.5, rely=0.52, anchor="center", width=popup_width, height=popup_height)
        self.alert.lift()
        self._alert_job = self.after(duration_ms, self.hide_alert)

    def hide_alert(self) -> None:
        self.alert.place_forget()
        self._alert_job = None


class RackSelector(tk.Frame):
    def __init__(self, parent, number: int, variable: tk.BooleanVar) -> None:
        super().__init__(parent, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        self.variable = variable
        self.number = number
        self.control = tk.Checkbutton(
            self,
            text=f"RACK {number}",
            variable=variable,
            indicatoron=False,
            command=self._refresh,
            bg="#0a1b30",
            activebackground="#0d4568",
            selectcolor="#0d4568",
            fg=TEXT,
            activeforeground=TEXT,
            font=("Segoe UI", 18, "bold"),
            relief="flat",
            padx=15,
            pady=18,
            cursor="hand2",
        )
        self.control.pack(fill="both", expand=True)

    def _refresh(self) -> None:
        self.config(highlightbackground=CYAN if self.variable.get() else BORDER, highlightthickness=2 if self.variable.get() else 1)


class RegistrationPage(tk.Frame):
    def __init__(self, parent, app: "AigisApp") -> None:
        super().__init__(parent, bg=BG)
        self.app = app
        self.registration_active = False
        self.registration_generation = 0
        self.capture_after_id = None
        self.registration_socket = None
        self.registration_results: Queue = Queue()
        self.success_after_id = None
        self.user_id = ""
        self.current_real_contour = None
        self._contour_mesh_cache = None
        self._contour_animation_job = None
        self._contour_angle = 0.0
        self._contour_photo = None
        self.after(100, self._poll_registration_results)
        self.header = Header(self, "FACE REGISTRATION", app, "register")
        self.header.pack(fill="x")
        body = tk.Frame(self, bg=BG)
        body.pack(fill="both", expand=True, padx=22, pady=(8, 13))
        body.grid_columnconfigure(0, weight=2, uniform="registration")
        body.grid_columnconfigure(1, weight=1, uniform="registration")
        body.grid_columnconfigure(2, weight=2, uniform="registration")
        body.grid_rowconfigure(0, weight=1)
        self.camera = CameraPanel(
            body,
            "CAM 입력 · 얼굴을 정면에 맞춰주세요",
            app.face_stream,
            title_font_size=20,
            center_title=True,
            active_check=lambda: app.split_windows or app.current_page == "register" or self.registration_active,
        )
        self.camera.grid(row=0, column=0, sticky="nsew", padx=(0, 7))

        form = tk.Frame(body, bg=PANEL, padx=16, pady=14, highlightthickness=1, highlightbackground=BORDER)
        form.grid(row=0, column=1, sticky="nsew", padx=7)
        tk.Label(form, text="INFORMATION", bg=PANEL, fg=CYAN, font=("Segoe UI", 27, "bold")).pack(anchor="center", pady=(0, 12))
        self.entries = {}
        fields = tk.Frame(form, bg=PANEL)
        fields.pack(fill="x")
        for row_index, (key, label) in enumerate((("name", "이름"), ("department", "부서"), ("position", "직책"))):
            tk.Label(fields, text=label, width=5, anchor="w", bg=PANEL, fg=TEXT, font=("Malgun Gothic", 18, "bold")).grid(row=row_index, column=0, sticky="w", pady=9)
            entry = tk.Entry(fields, bg="#020c1a", fg=TEXT, insertbackground=TEXT, relief="flat", font=("Malgun Gothic", 18))
            entry.grid(row=row_index, column=1, sticky="ew", pady=9, ipady=10)
            fields.grid_columnconfigure(1, weight=1)
            self.entries[key] = entry

        separator = tk.Frame(form, height=1, bg=BORDER)
        separator.pack(fill="x", pady=(12, 11))
        tk.Label(form, text="관리 책임 RACK", bg=PANEL, fg=CYAN, font=("Malgun Gothic", 20, "bold")).pack(anchor="center", pady=(0, 10))
        rack_grid = tk.Frame(form, bg=PANEL)
        rack_grid.pack(fill="x")
        rack_grid.grid_columnconfigure(0, weight=1, uniform="rack_selector")
        rack_grid.grid_columnconfigure(1, weight=1, uniform="rack_selector")
        self.rack_vars = []
        self.rack_selectors = []
        for number in range(1, 5):
            var = tk.BooleanVar()
            selector = RackSelector(rack_grid, number, var)
            selector.grid(row=(number - 1) // 2, column=(number - 1) % 2, sticky="nsew", padx=4, pady=4)
            self.rack_vars.append(var)
            self.rack_selectors.append(selector)

        permission = tk.Frame(form, bg="#091d34", highlightthickness=1, highlightbackground=BORDER)
        permission.pack(fill="x", pady=12)
        self.entrance_var = tk.BooleanVar(value=True)
        tk.Checkbutton(
            permission,
            text="출입문 접근 허용",
            variable=self.entrance_var,
            bg="#091d34",
            activebackground="#091d34",
            fg=TEXT,
            activeforeground=TEXT,
            selectcolor=PANEL_3,
            font=("Malgun Gothic", 18, "bold"),
            padx=13,
            pady=9,
        ).pack(anchor="w")
        actions = tk.Frame(form, bg=PANEL)
        actions.pack(fill="x")
        self.submit_btn = button(actions, "등록", self.register, "#0d7a43", 9, 17, 11)
        self.submit_btn.pack(side="left", padx=(0, 8), expand=True, fill="x")
        button(actions, "취소", self.cancel_registration, "#9b2029", 9, 17, 11).pack(side="left", expand=True, fill="x")
        self.note = tk.Label(form, text="얼굴 프레임과 사용자 권한을 등록합니다.", bg=PANEL, fg=MUTED, font=("Malgun Gothic", 13), wraplength=300)
        self.note.pack(anchor="center", pady=(12, 0))

        self.contour = tk.Frame(body, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        self.contour.grid(row=0, column=2, sticky="nsew", padx=(7, 0))
        
        self.contour_inner = tk.Frame(self.contour, bg=PANEL)
        self.contour_inner.pack(fill="both", expand=True)
        
        tk.Label(self.contour_inner, text="3D 윤곽 DATA", bg=PANEL, fg=CYAN, font=("Segoe UI", 28, "bold")).pack(anchor="center", padx=17, pady=(14, 5))
        self.guide_label = tk.Label(self.contour_inner, text="FACE GEOMETRY / DEPTH MAP", bg=PANEL, fg=MUTED, font=("Segoe UI", 15, "bold"))
        self.guide_label.pack(anchor="center", padx=18)
        self.contour_canvas = tk.Canvas(self.contour_inner, bg="#020914", highlightthickness=0)
        self.contour_canvas.pack(fill="both", expand=True, padx=14, pady=12)
        self.contour_canvas.bind("<Configure>", self._draw_contour)
        self.assigned_id = tk.Label(self.contour_inner, text="ASSIGNED FACE ID · 대기", bg="#091d34", fg=GREEN, font=("Consolas", 17, "bold"), pady=13)
        self.assigned_id.pack(fill="x", padx=14, pady=(0, 14))

        self.overlay = tk.Frame(self, bg="#0b7d45", highlightthickness=2, highlightbackground="#7fffc0", height=72)
        self.overlay.pack_propagate(False)
        tk.Label(self.overlay, text="✓  등록이 완료되었습니다.", bg="#0b7d45", fg="white", font=("Malgun Gothic", 24, "bold")).pack(expand=True)

    def _stop_contour_animation(self) -> None:
        if self._contour_animation_job is not None:
            try:
                self.after_cancel(self._contour_animation_job)
            except tk.TclError:
                pass
            self._contour_animation_job = None

    def _start_contour_animation(self) -> None:
        self._stop_contour_animation()
        if not self.current_real_contour:
            return

        def tick():
            if not self.current_real_contour or not self.winfo_exists():
                self._contour_animation_job = None
                return
            visible = self.app.split_windows or self.app.current_page == "register"
            if visible:
                self._contour_angle = (self._contour_angle + 0.028) % (2 * np.pi)
                self._draw_contour()
            self._contour_animation_job = self.after(50 if visible else 220, tick)

        tick()

    def _prepare_contour_wireframe(self, coords, width: int, height: int):
        cache_key = (id(coords), width, height)
        if self._contour_mesh_cache and self._contour_mesh_cache[0] == cache_key:
            return self._contour_mesh_cache[1], self._contour_mesh_cache[2]
        try:
            points = np.asarray(coords, dtype=np.float32)
            if points.ndim != 2 or points.shape[1] < 2 or len(points) < 3:
                return None, []
            points = points[:468, :3]
            if points.shape[1] == 2:
                points = np.column_stack((points, np.zeros(len(points), dtype=np.float32)))
            if not np.isfinite(points).all():
                return None, []

            nose_index = 1 if len(points) > 1 else 0
            points = points - points[nose_index]
            target_span = min(width, height) * 0.68
            xy_span = max(float(np.ptp(points[:, 0])), float(np.ptp(points[:, 1])), 1e-6)
            points *= target_span / xy_span
            depth_span = float(np.ptp(points[:, 2]))
            if depth_span > 1e-6:
                points[:, 2] *= (target_span * 0.34) / depth_span

            triangles = MonitorPage._mesh_triangles(points, width, height)
            edges = set()
            for a, b, c in triangles:
                edges.add(tuple(sorted((a, b))))
                edges.add(tuple(sorted((b, c))))
                edges.add(tuple(sorted((c, a))))
            edges = list(edges)
            self._contour_mesh_cache = (cache_key, points, edges)
            return points, edges
        except (TypeError, ValueError):
            return None, []

    def _render_contour_wireframe(self, coords, width: int, height: int) -> bool:
        points, edges = self._prepare_contour_wireframe(coords, width, height)
        if points is None or not edges:
            return False

        background = np.zeros((height, width, 3), dtype=np.uint8)
        background[:] = (20, 9, 2)
        center = (width / 2, height * 0.50)
        yaw = self._contour_angle
        pitch = np.deg2rad(-9.0)

        cos_y, sin_y = np.cos(yaw), np.sin(yaw)
        x = points[:, 0] * cos_y + points[:, 2] * sin_y
        z = -points[:, 0] * sin_y + points[:, 2] * cos_y
        cos_p, sin_p = np.cos(pitch), np.sin(pitch)
        y = points[:, 1] * cos_p - z * sin_p
        z = points[:, 1] * sin_p + z * cos_p

        distance = max(width, height) * 1.75
        perspective = distance / np.maximum(distance + z, distance * 0.3)
        projected = np.column_stack(
            (center[0] + x * perspective, center[1] + y * perspective)
        ).astype(np.int32)

        # A subtle floor grid makes depth and rotation easier to read.
        grid_color = (46, 33, 18)
        for ratio in (0.66, 0.75, 0.84, 0.93):
            grid_y = int(height * ratio)
            cv2.line(background, (int(width * 0.12), grid_y), (int(width * 0.88), grid_y), grid_color, 1, cv2.LINE_AA)
        for ratio in np.linspace(0.2, 0.8, 7):
            cv2.line(background, (width // 2, int(height * 0.60)), (int(width * ratio), int(height * 0.96)), grid_color, 1, cv2.LINE_AA)

        min_z, max_z = float(np.min(z)), float(np.max(z))
        depth_range = max(max_z - min_z, 1e-6)
        for a, b in edges:
            p1, p2 = projected[a], projected[b]
            if not (
                0 <= p1[0] < width and 0 <= p1[1] < height
                and 0 <= p2[0] < width and 0 <= p2[1] < height
            ):
                continue
            depth = ((float(z[a] + z[b]) * 0.5) - min_z) / depth_range
            brightness = 0.35 + 0.65 * (1.0 - depth)
            color = (
                int(255 * brightness),
                int(220 * brightness),
                int(35 * brightness),
            )
            cv2.line(background, tuple(p1), tuple(p2), color, 1, cv2.LINE_AA)

        for index in range(0, len(projected), 3):
            px, py = projected[index]
            if 0 <= px < width and 0 <= py < height:
                cv2.circle(background, (int(px), int(py)), 1, (70, 255, 150), -1, cv2.LINE_AA)

        cv2.putText(background, "REGISTERED 3D WIREFRAME", (16, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.58, (255, 220, 55), 1, cv2.LINE_AA)
        image = Image.fromarray(cv2.cvtColor(background, cv2.COLOR_BGR2RGB))
        self._contour_photo = ImageTk.PhotoImage(image)
        self.contour_canvas.create_image(width // 2, height // 2, image=self._contour_photo, tags="contour")
        return True

    def _draw_contour(self, event=None) -> None:
        canvas = self.contour_canvas
        canvas.delete("contour")
        width = canvas.winfo_width()
        height = canvas.winfo_height()
        if width <= 1 or height <= 1:
            return
            
        if getattr(self, 'current_real_contour', None):
            # RegistrationDaemon returns the enrollment engine's
            # ``contour_points`` field. Keep ``coords`` support for older
            # servers that used the original UI contract.
            coords = (
                self.current_real_contour.get("contour_points")
                or self.current_real_contour.get("coords")
                or []
            )
            if coords and self._render_contour_wireframe(coords, width, height):
                return
                
        cx, cy = width / 2, height * 0.48
        rx, ry = width * 0.27, height * 0.34
        color = "#19c7ff"
        dim = "#0d5f84"
        canvas.create_oval(cx - rx, cy - ry, cx + rx, cy + ry, outline=color, width=2, tags="contour")
        for scale in (0.72, 0.45):
            canvas.create_oval(cx - rx, cy - ry * scale, cx + rx, cy + ry * scale, outline=dim, tags="contour")
        canvas.create_line(cx, cy - ry, cx, cy + ry, fill=dim, tags="contour")
        canvas.create_line(cx - rx, cy, cx + rx, cy, fill=dim, tags="contour")
        canvas.create_arc(cx - rx * 0.58, cy - ry * 0.08, cx - rx * 0.08, cy + ry * 0.20, start=20, extent=140, style="arc", outline=color, width=2, tags="contour")
        canvas.create_arc(cx + rx * 0.08, cy - ry * 0.08, cx + rx * 0.58, cy + ry * 0.20, start=20, extent=140, style="arc", outline=color, width=2, tags="contour")
        canvas.create_line(cx, cy - ry * 0.05, cx - rx * 0.08, cy + ry * 0.30, cx + rx * 0.10, cy + ry * 0.31, fill=color, width=2, tags="contour")
        canvas.create_arc(cx - rx * 0.36, cy + ry * 0.28, cx + rx * 0.36, cy + ry * 0.64, start=200, extent=140, style="arc", outline=color, width=2, tags="contour")
        for x_factor, y_factor in ((-0.55, -0.3), (0.55, -0.3), (-0.35, 0.48), (0.35, 0.48), (0, 0.02)):
            x, y = cx + rx * x_factor, cy + ry * y_factor
            canvas.create_oval(x - 3, y - 3, x + 3, y + 3, fill=GREEN, outline="", tags="contour")

    def set_security(self, text: str, color: str) -> None:
        self.header.set_security(text, color)

    def register(self) -> None:
        if self.registration_active:
            return
        if self.success_after_id is not None:
            try:
                self.after_cancel(self.success_after_id)
            except tk.TclError:
                pass
            self.success_after_id = None
            self.overlay.place_forget()
            self.current_real_contour = None
            self.assigned_id.config(text="ASSIGNED FACE ID · 대기")
            self.after_idle(self._draw_contour)
        values = {key: entry.get().strip() for key, entry in self.entries.items()}
        if not values["name"]:
            messagebox.showwarning("입력 확인", "이름을 입력해 주세요.")
            return
        self._stop_contour_animation()
        self.current_real_contour = None
        self._contour_mesh_cache = None
        self.assigned_id.config(text="ASSIGNED FACE ID · 대기")
        self.after_idle(self._draw_contour)
        user_id = f"U{datetime.now():%m%d%H%M%S}"
        rack_control = {f"RACK-{index + 1:02d}": variable.get() for index, variable in enumerate(self.rack_vars)}
        self.information = {
            "name": values["name"],
            "department": values["department"],
            "position": values["position"],
            "open_entrance": self.entrance_var.get(),
            "rack_control": rack_control,
        }
        self.user_id = user_id
        self.registration_generation += 1
        self.registration_active = True
        
        self.submit_btn.config(state="disabled", text="촬영 준비 중...")
        self.capture_count = 0
        self.captured_b64 = []
        
        self.angle_prompts = [
            "정면을 보세요",
            "정면을 보세요",
            "정면을 보세요",
            "정면을 보세요",
            "고개를 살짝 위로 올리세요",
            "고개를 살짝 위로 올리세요",
            "고개를 살짝 아래로 내리세요",
            "고개를 살짝 아래로 내리세요",
            "자연스럽게 미소 지어주세요",
            "마지막 정면을 보세요"
        ]
        
        # Start capture loop
        capture_delay = self.app.config.get("capture_delay_ms", 1000)
        self.capture_after_id = self.after(500, self._capture_step, capture_delay)
        
    def _capture_step(self, delay: int) -> None:
        self.capture_after_id = None
        if not self.registration_active:
            return
        if self.capture_count >= 10:
            self._finish_registration()
            return
            
        prompt = self.angle_prompts[self.capture_count]
        self.guide_label.config(text=f"[{self.capture_count + 1}/10] {prompt}", fg=ORANGE)
        self.submit_btn.config(text=f"촬영 중 ({self.capture_count + 1}/10)")
        
        snapshot_path = FACE_REGISTRY_DIR / self.user_id / f"capture_{self.capture_count + 1:02d}.jpg"
        captured = self.camera.save_snapshot(snapshot_path)
        
        if captured:
            import base64
            with open(snapshot_path, "rb") as f:
                self.captured_b64.append(base64.b64encode(f.read()).decode('utf-8'))
            self.capture_count += 1
            self.app.add_event(f"사용자 등록 캡처 진행 중... [{self.capture_count}/10]")
            self.capture_after_id = self.after(delay, self._capture_step, delay)
        else:
            self.app.add_event(f"사진 캡처 실패. 재시도 중...")
            self.capture_after_id = self.after(500, self._capture_step, delay)
            
    def _finish_registration(self) -> None:
        if not self.registration_active:
            return
        registration_generation = self.registration_generation
        registration_user_id = self.user_id
        registration_information = dict(self.information)
        registration_images = list(self.captured_b64)
        self.guide_label.config(text="데이터 전송 중...", fg=CYAN)
        self.submit_btn.config(text="전송 중...")
        self.note.config(text="얼굴 특징과 3D 윤곽을 서버에서 분석하고 있습니다.", fg=ORANGE)
        self.app.update_idletasks()
        
        def send_data():
            try:
                import socket
                import struct
                import json
                
                daemon_host = getattr(self.app.face_client, 'host', '127.0.0.1')
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.registration_socket = s
                s.settimeout(float(self.app.config.get("registration_timeout_seconds", 180)))
                s.connect((daemon_host, 9998))
                
                payload = json.dumps({
                    "user_id": registration_user_id,
                    "images_jpeg_b64": registration_images
                }).encode('utf-8')
                
                s.sendall(struct.pack('<I', len(payload)) + payload)
                response_chunks = []
                response_size = 0
                while True:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    response_chunks.append(chunk)
                    response_size += len(chunk)
                    if response_size > 4 * 1024 * 1024:
                        raise ValueError("등록 서버 응답이 제한 크기(4MB)를 초과했습니다.")
                resp = b"".join(response_chunks)
                s.close()
                if self.registration_socket is s:
                    self.registration_socket = None
                
                resp_str = resp.decode('utf-8', errors='ignore')
                resp_data = {}
                try:
                    resp_data = json.loads(resp_str)
                except json.JSONDecodeError:
                    if '"success"' in resp_str:
                        resp_data = {"status": "success"}
                if not resp:
                    raise ConnectionError("등록 서버가 빈 응답을 반환했습니다.")
                self.registration_results.put(
                    {
                        "generation": registration_generation,
                        "user_id": registration_user_id,
                        "information": registration_information,
                        "response": resp_data,
                        "raw_response": resp_str,
                        "error": "",
                    }
                )
                
            except Exception as e:
                if 's' in locals() and self.registration_socket is s:
                    self.registration_socket = None
                if 's' in locals():
                    try:
                        s.close()
                    except OSError:
                        pass
                self.registration_results.put(
                    {
                        "generation": registration_generation,
                        "user_id": registration_user_id,
                        "information": registration_information,
                        "response": {},
                        "raw_response": "",
                        "error": str(e),
                    }
                )

        import threading
        threading.Thread(target=send_data, daemon=True).start()

    def _poll_registration_results(self) -> None:
        try:
            while True:
                result = self.registration_results.get_nowait()
                if (
                    not self.registration_active
                    or result.get("generation") != self.registration_generation
                ):
                    continue

                error_text = result.get("error", "")
                response = result.get("response") or {}
                if error_text:
                    self.app.add_event(f"원격 등록 서버 연결/처리 오류: {error_text}")
                    messagebox.showerror("등록 실패", f"서버 연동 오류: {error_text}")
                elif response.get("status") != "success":
                    detail = response.get("message") or result.get("raw_response") or "알 수 없는 서버 오류"
                    self.app.add_event(f"원격 등록 서버 처리 실패: {detail}")
                    messagebox.showerror("등록 실패", f"서버 처리 실패: {detail}")
                else:
                    user_id = result["user_id"]
                    try:
                        self.app.users.save(user_id, result["information"])
                    except Exception as save_error:
                        self.app.add_event(f"사용자 정보 로컬 저장 오류: {save_error}")
                        messagebox.showerror("등록 실패", f"로컬 DB 저장 중 오류가 발생했습니다: {save_error}")
                    else:
                        contour_data = response.get("contour_data")
                        if contour_data:
                            self.current_real_contour = contour_data
                            self._contour_mesh_cache = None
                            self._contour_angle = 0.0
                            self._draw_contour()
                            self._start_contour_animation()
                        self.assigned_id.config(text=f"ASSIGNED FACE ID · {user_id}")
                        self.app.add_event(f"사용자 다중 사진(10장) 등록 완료: {user_id}")
                        self.show_success()

                self.registration_active = False
                self.submit_btn.config(state="normal", text="등록")
                self.guide_label.config(text="FACE GEOMETRY / DEPTH MAP", fg=MUTED)
                self.note.config(text="얼굴 프레임과 사용자 권한을 등록합니다.", fg=MUTED)
        except Empty:
            pass
        if self.winfo_exists():
            self.after(100, self._poll_registration_results)

    def show_success(self) -> None:
        self.contour_inner.pack(fill="both", expand=True)
        self.overlay.place(relx=0.5, rely=0.985, relwidth=0.72, height=72, anchor="s")
        self.overlay.lift()
        self.success_after_id = self.after(5000, self._finish_success)

    def _finish_success(self) -> None:
        self.success_after_id = None
        self.overlay.place_forget()
        self.clear(preserve_contour=True)
        self.after_idle(self._draw_contour)

    def cancel_registration(self) -> None:
        was_active = self.registration_active
        self.registration_active = False
        self.registration_generation += 1
        if self.capture_after_id is not None:
            try:
                self.after_cancel(self.capture_after_id)
            except tk.TclError:
                pass
            self.capture_after_id = None

        active_socket = self.registration_socket
        self.registration_socket = None
        if active_socket is not None:
            try:
                active_socket.shutdown(2)
            except OSError:
                pass
            try:
                active_socket.close()
            except OSError:
                pass

        # Captures belong only to the in-progress registration. Remove that
        # exact generated user directory when the operator cancels.
        if was_active and self.user_id:
            capture_dir = FACE_REGISTRY_DIR / self.user_id
            if capture_dir.is_dir() and capture_dir.parent == FACE_REGISTRY_DIR:
                shutil.rmtree(capture_dir, ignore_errors=True)
            self.app.add_event(f"사용자 등록 취소: {self.user_id}", color=ORANGE)

        self.submit_btn.config(state="normal", text="등록")
        self.guide_label.config(text="FACE GEOMETRY / DEPTH MAP", fg=MUTED)
        self.note.config(text="얼굴 프레임과 사용자 권한을 등록합니다.", fg=MUTED)
        self.overlay.place_forget()
        self.clear()
        self.after_idle(self._draw_contour)

    def clear(self, preserve_contour: bool = False) -> None:
        for entry in self.entries.values():
            entry.delete(0, tk.END)
        for variable, selector in zip(self.rack_vars, self.rack_selectors):
            variable.set(False)
            selector._refresh()
        self.entrance_var.set(True)
        self.capture_count = 0
        self.captured_b64 = []
        if not preserve_contour:
            self._stop_contour_animation()
            self.current_real_contour = None
            self._contour_mesh_cache = None
            self.assigned_id.config(text="ASSIGNED FACE ID · 대기")
        self.user_id = ""

    def on_show(self) -> None:
        self.camera.invalidate()
        if not self.contour_inner.winfo_manager():
            self.contour_inner.pack(fill="both", expand=True)
        if self.current_real_contour:
            self._start_contour_animation()
        else:
            self.after_idle(self._draw_contour)


class AigisApp(tk.Tk):
    def __init__(
        self,
        simulate: bool = False,
        port: str | None = None,
        screenshot: Path | None = None,
        initial_page: str = "monitor",
        screenshot_delay_ms: int = 1400,
        show_registration_overlay: bool = False,
        show_face_overlay: bool = False,
        start_fullscreen: bool = False,
        show_wrong_key: bool = False,
        random_key: bool = False,
        split_windows: bool = False,
    ) -> None:
        super().__init__()
        self.title("A.I.G.I.S 통합 관제 시스템")
        window_width = min(1600, self.winfo_screenwidth() - 60)
        window_height = min(900, self.winfo_screenheight() - 80)
        self.geometry(f"{window_width}x{window_height}+8+8")
        self.minsize(1120, 680)
        self.maxsize(window_width, window_height)
        self.configure(bg=BG)
        self._fullscreen = False
        self._windowed_geometry = f"{window_width}x{window_height}+8+8"
        self._windowed_maxsize = (window_width, window_height)
        self.config = load_config()
        self.simulate = simulate
        if port:
            self.config["serial_port"] = port
        source_a = self.config.get("pcam_ch_a_source")
        if source_a is None:
            source_a = self.config.get("cctv_source")
        source_b = self.config.get("pcam_ch_b_source")
        if source_b is None:
            source_b = source_a
        self.tcp_stream = TCPCameraStream(host=self.config.get("cctv_server_ip", "10.10.15.133"))
        self.pcam_ch_a_stream = self.tcp_stream.get_adapter('A')
        self.pcam_ch_b_stream = self.tcp_stream.get_adapter('B')
        self.cctv_stream = self.pcam_ch_a_stream
        self.face_client = TCPFaceClient(self.config.get("face_server_ip", "127.0.0.1"), 9999, MASTER_KEY)
        self.face_stream = self.face_client
        self._face_match_job = None
        self._face_match_generation = 0
        self.users = UserRepository()
        self.event_queue: Queue = Queue()
        self.client = SecureSerialClient(
            self.event_queue,
            port=self.config["serial_port"],
            baud_rate=int(self.config["baud_rate"]),
            simulate=simulate,
        )
        self.invalid_command_key = False
        self.wrong_master_key = bytes((MASTER_KEY[0] ^ 0x01,)) + MASTER_KEY[1:]
        self.split_windows = split_windows
        self.page_windows = {}

        if self.split_windows:
            self.pages = {"monitor": MonitorPage(self, self)}
            self.pages["monitor"].place(relx=0, rely=0, relwidth=1, relheight=1)
            self.page_windows["monitor"] = self
            
            rack_win = tk.Toplevel(self)
            rack_win.title("A.I.G.I.S - RACK CONTROL")
            rack_win.geometry(f"{window_width}x{window_height}+100+100")
            rack_win.configure(bg=BG)
            rack_win.minsize(1120, 680)
            self.pages["racks"] = RackPage(rack_win, self)
            self.pages["racks"].place(relx=0, rely=0, relwidth=1, relheight=1)
            self.page_windows["racks"] = rack_win
            
            reg_win = tk.Toplevel(self)
            reg_win.title("A.I.G.I.S - REGISTRATION")
            reg_win.geometry(f"{window_width}x{window_height}+200+200")
            reg_win.configure(bg=BG)
            reg_win.minsize(1120, 680)
            self.pages["register"] = RegistrationPage(reg_win, self)
            self.pages["register"].place(relx=0, rely=0, relwidth=1, relheight=1)
            self.page_windows["register"] = reg_win
            
            for win in [rack_win, reg_win]:
                win.bind("<F11>", lambda e, w=win: self.toggle_fullscreen(e, w))
                win.bind("<Escape>", lambda e, w=win: self.exit_fullscreen(e, w))
                win.protocol("WM_DELETE_WINDOW", self.close)
        else:
            self.pages = {
                "monitor": MonitorPage(self, self),
                "racks": RackPage(self, self),
                "register": RegistrationPage(self, self),
            }
            for page in self.pages.values():
                page.place(relx=0, rely=0, relwidth=1, relheight=1)
                
        self.update_idletasks()
        self.geometry(f"{window_width}x{window_height}+8+8")
        self.resizable(False, False)
        self.bind("<F11>", lambda e: self.toggle_fullscreen(e, self))
        self.bind("<Escape>", lambda e: self.exit_fullscreen(e, self))
        self.bind("<F5>", lambda e: self._handle_face({"event": "face", "user_id": "U0810153108", "authorized": True}, demo=True))
        self.bind("<F6>", lambda e: self._handle_face({"event": "face", "user_id": "UNKNOWN_123", "authorized": False}, demo=True))
        self.last_camera_states = [None, None, None]
        self.last_fire_mask = 0
        self.current_page = initial_page
        self.show_page(initial_page)
        if start_fullscreen:
            self.after(50, self.toggle_fullscreen)
        if show_registration_overlay:
            self.after(250, self.pages["register"].show_success)
        if show_face_overlay:
            self.after(
                250,
                lambda: self.pages["monitor"].show_face(
                    True,
                    "jjm",
                    self.users.get("jjm")
                    or {
                        "name": "사용자",
                        "department": "AIGIS",
                        "position": "Engineer",
                        "rack_control": {"RACK-01": True},
                    },
                ),
            )
        if show_wrong_key:
            self.after(250, lambda: self.pages["racks"].fake_key_button.invoke())
            
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.after(60, self._drain_events)
        self.client.start()
        self.face_client.start()
        if screenshot:
            self.after(screenshot_delay_ms, lambda: self._save_screenshot(screenshot))
            
        self.local_random_mode = random_key
        if self.local_random_mode:
            self._local_random_loop()

    def _local_random_loop(self) -> None:
        import os
        new_R = os.urandom(16)
        if hasattr(self, "tcp_stream"):
            self.tcp_stream.update_random(new_R)
        if hasattr(self, "face_client"):
            self.face_client.update_random(new_R)
        
        self.pages["monitor"].set_secure_video_allowed(True, "PC 내부 난수로 세션 연결 완료")
        self.add_event_block(
            [
                f"[LOCAL RNG] PC 내부 생성 세션 키(R) 발급",
                f"R = {new_R.hex().upper()}"
            ],
            demo=self.simulate,
            color=GREEN
        )
        self.after(30000, self._local_random_loop)

    def show_page(self, name: str) -> None:
        self.current_page = name
        page = self.pages[name]
        if self.split_windows:
            self.page_windows[name].lift()
            self.page_windows[name].focus_force()
        else:
            page.tkraise()
        on_show = getattr(page, "on_show", None)
        if on_show is not None:
            self.after_idle(on_show)
        self.after_idle(page.update_idletasks)

    def toggle_fullscreen(self, _event=None, window=None) -> None:
        win = window or self
        if getattr(win, '_fullscreen', False):
            self.exit_fullscreen(None, win)
            return
        win._windowed_geometry = win.geometry()
        win._fullscreen = True
        win.resizable(True, True)
        win.maxsize(win.winfo_screenwidth(), win.winfo_screenheight())
        win.attributes("-fullscreen", True)

    def exit_fullscreen(self, _event=None, window=None) -> None:
        win = window or self
        if not getattr(win, '_fullscreen', False):
            return
        win._fullscreen = False
        win.attributes("-fullscreen", False)
        if hasattr(self, '_windowed_maxsize'):
            win.maxsize(*self._windowed_maxsize)
        win.resizable(False, False)
        win.geometry(win._windowed_geometry)

    def set_security(self, text: str, color: str) -> None:
        for page in self.pages.values():
            page.set_security(text, color)

    def add_event(self, message: str, demo: bool | None = None, color: str | None = None) -> None:
        self.pages["racks"].log.add(message, self.simulate if demo is None else demo, color=color)

    def add_event_block(self, messages: list[str], demo: bool = False, color: str | None = None) -> None:
        for message in reversed(messages):
            self.add_event(message, demo=demo, color=color)

    def set_command_key_mode(self, invalid: bool) -> None:
        self.invalid_command_key = invalid
        key = self.wrong_master_key if invalid else MASTER_KEY
        self.pages["racks"].set_key_mode(invalid, key.hex().upper())
        self.pages["racks"].security_flow.set_flow_enabled(not invalid)
        if invalid:
            self.pages["racks"].show_alert(
                "가짜 마스터키",
                "",
                ORANGE,
                3000,
            )

    def _reject_fake_key_control(self, label: str) -> None:
        # A wrong-key frame is indistinguishable from an attack to ZYBO and can
        # trigger the hardware fail-safe. Fake-key demonstrations are therefore
        # rejected locally and never placed on UART. Only the dedicated attack
        # button is allowed to transmit a deliberately invalid GCM frame.
        self.pages["racks"].show_alert(
            "명령 인증 실패",
            "",
            RED,
            3500,
        )
        self.add_event(f"가짜 마스터키: {label} · PC 로컬 차단 · UART 미전송", color=RED)

    def set_door(self, opened: bool) -> None:
        if self.invalid_command_key:
            self._reject_fake_key_control(f"출입문 {'OPEN' if opened else 'CLOSE'}")
            return
        self.client.set_door(opened)
        self.pages["racks"].security_flow.animate_command(f"출입문 {'OPEN' if opened else 'CLOSE'}", target="jetson")
        self.add_event(f"메인 출입문 {'OPEN' if opened else 'CLOSE'} 명령")

    def set_rack(self, rack_number: int, opened: bool) -> None:
        if self.invalid_command_key:
            self._reject_fake_key_control(f"RACK {rack_number} {'OPEN' if opened else 'CLOSE'}")
            return
        self.client.set_rack(rack_number, opened)
        self.pages["racks"].security_flow.animate_command(f"RACK {rack_number} {'OPEN' if opened else 'CLOSE'}", target="basys")
        self.add_event(f"{rack_number}번 랙 {'OPEN' if opened else 'CLOSE'} 명령")

    def set_all_racks(self, opened: bool) -> None:
        if self.invalid_command_key:
            self._reject_fake_key_control(f"ALL RACK {'OPEN' if opened else 'CLOSE'}")
            return
        self.client.set_all_racks(opened)
        self.pages["racks"].security_flow.animate_command(f"ALL RACK {'OPEN' if opened else 'CLOSE'}", target="basys")
        self.add_event(f"전체 랙 {'OPEN' if opened else 'CLOSE'} 명령")

    def run_invalid_key_test(self) -> None:
        self.client.send_invalid_key_all_open()
        # The current hardware demonstration enters its fail-safe state and
        # physically closes every rack after the invalid-key attempt.
        self.client.rack_mask = 0
        self.pages["racks"].update_rack_mask(0)
        self.pages["racks"].show_alert(
            "보안 공격 감지 · 모든 문 폐쇄",
            "Fail-safe 작동 · 출입문과 모든 RACK 문을 안전 상태로 닫습니다.",
            RED,
            5000,
        )

    def _drain_events(self) -> None:
        processed = 0
        max_events_per_tick = 32
        try:
            while processed < max_events_per_tick:
                self._handle_event(self.event_queue.get_nowait())
                processed += 1
        except Empty:
            pass
        # Yield to painting and input when a burst arrives instead of locking
        # the Tk event loop until the producer queue becomes empty.
        self.after(8 if not self.event_queue.empty() else 60, self._drain_events)

    def _handle_event(self, event: dict) -> None:
        event_type = event["type"]
        demo = bool(event.get("simulated", False) or (self.simulate and event_type in ("sensor", "face")))
        if event_type == "connection":
            if event.get("connected"):
                self.pages["monitor"].set_secure_video_allowed(False, "마스터키 인증 및 세션 연결 대기")
                self.pages["racks"].security_flow.update_security("UART CONNECTED · KEY EXCHANGE WAIT")
                if event.get("mode") == "SIMULATION":
                    self.set_security("DEMO 모드", CYAN)
                else:
                    self.set_security("UART 연결 · 키 교환 대기", ORANGE)
            else:
                self.set_security("UART 연결 실패", RED)
                self.pages["monitor"].set_secure_video_allowed(False, "UART 연결 실패 · 영상 수신 차단")
                self.pages["racks"].security_flow.update_security("UART CONNECTION FAIL")
                self.add_event(f"UART 연결 실패: {event.get('error', '')}", demo=False)
        elif event_type == "security":
            secure = event["state"] == "SECURE"
            self.pages["monitor"].set_secure_video_allowed(secure, "마스터키 XOR 검증 중 · 영상 대기")
            self.pages["racks"].security_flow.update_security(
                "SECURE · CH-A VIDEO READY" if secure else "REKEY · MASTER XOR RANDOM",
                event.get("master_key_hex", ""),
                event.get("random_hex", ""),
                event.get("session_key_hex", ""),
            )
            secure_text = "DEMO AES-GCM 연결" if secure and demo else ("보안 통신 연결됨" if secure else "세션키 갱신 중")
            self.set_security(secure_text, GREEN if secure else ORANGE)
            random_hex = event.get("random_hex")
            if random_hex and not getattr(self, "local_random_mode", False):
                new_R = bytes.fromhex(random_hex)
                if hasattr(self, "tcp_stream"):
                    self.tcp_stream.update_random(new_R)
                if hasattr(self, "face_client"):
                    self.face_client.update_random(new_R)
            
            if not secure and random_hex and self.config.get("show_security_random", True):
                self.add_event_block(
                    [
                        f"[REKEY 1/3] MASTER KEY = {event.get('master_key_hex', '')}",
                        f"[REKEY 2/3] ZYBO RANDOM R = {random_hex}",
                        f"[REKEY 3/3] MASTER KEY XOR R = SESSION KEY = {event.get('session_key_hex', '')}",
                    ],
                    demo=demo,
                    color=ORANGE,
                )
            if secure:
                self.add_event("[REKEY] AES-GCM 보안 세션 연결 완료", demo=demo)
        elif event_type == "crypto":
            self._handle_crypto_event(event)
            self.pages["racks"].security_flow.update_crypto(event)
            if event.get("direction") == "RX" and not event.get("authenticated", False):
                self.pages["monitor"].set_secure_video_allowed(False, "MASTER KEY 불일치 · GCM TAG 인증 실패")
        elif event_type == "attack_test":
            status = "변조 패킷 UART 전송 완료 · 장비의 TAG 검증 실패/명령 폐기 예상" if event.get("delivered") else "변조 패킷 전송 실패 · UART/보안 세션 확인 필요"
            self.add_event(f"[INVALID KEY TEST] {status}", demo=demo, color=RED)
            self.pages["racks"].security_flow.update_security("INVALID KEY TEST · TAG FAIL")
        elif event_type == "sensor":
            self.pages["racks"].update_sensors(event)
            self._log_sensor_transitions(event, demo=demo)
        elif event_type == "rack_state":
            self.pages["racks"].update_rack_mask(event["mask"])
        elif event_type == "face":
            self._handle_face(event, demo=demo)
        elif event_type == "security_error":
            self.pages["monitor"].set_secure_video_allowed(False, "MASTER KEY 불일치 · 영상 복호화 실패")
            self.pages["racks"].security_flow.update_security("SECURITY ERROR · TAG FAIL")
            self.add_event(f"보안 패킷 폐기: {event['message']}", demo=False)

    def _request_matching_face_overlay(
        self,
        user_id: str,
        uart_authorized: bool,
        display_authorized: bool,
        information: dict | None,
    ) -> None:
        self._face_match_generation += 1
        generation = self._face_match_generation
        if self._face_match_job is not None:
            try:
                self.after_cancel(self._face_match_job)
            except tk.TclError:
                pass
            self._face_match_job = None
        deadline = time.monotonic() + 3.0

        def poll_for_match():
            if generation != self._face_match_generation:
                return
            if self.current_page != "monitor":
                self._face_match_job = None
                return
            tcp_json = self.face_client.get_matching_event(user_id, uart_authorized)
            if tcp_json is not None:
                self._face_match_job = None
                self.pages["monitor"].show_face(display_authorized, user_id, information, tcp_json)
                return
            if time.monotonic() < deadline:
                self._face_match_job = self.after(100, poll_for_match)
            else:
                self._face_match_job = None
                self.add_event(
                    f"FACE 표시 생략: UART 결과와 일치하는 TCP 데이터 없음 ({user_id or 'UNKNOWN'})",
                    color=ORANGE,
                )

        poll_for_match()

    def _handle_face(self, event: dict, demo=False) -> None:
        user_id = event.get("user_id", "")
        uart_authorized = bool(event.get("authorized"))
        information = self.users.get(user_id) if uart_authorized else None
        authorized = bool(uart_authorized and information)
        self.pages["racks"].security_flow.animate_face(
            f"FACE ID {user_id or 'UNKNOWN'} · {'AUTHORIZED' if authorized else 'DENIED'}"
        )
        # Face ID must never pull an operator away from the rack or registration
        # page. The overlay is presented only while the monitor page is active.
        if self.current_page == "monitor" and not demo:
            self._request_matching_face_overlay(user_id, uart_authorized, authorized, information)
        if self.current_page == "monitor" and demo:
            tcp_json = self.face_client.get_latest_event()
            if demo and tcp_json is None:
                import base64, numpy as np, cv2
                img = np.zeros((480, 640, 3), dtype=np.uint8)
                cv2.circle(img, (320, 240), 120, (200, 200, 200), 2)
                cv2.ellipse(img, (320, 420), (140, 100), 0, 180, 360, (200, 200, 200), 2)
                _, buf = cv2.imencode('.jpg', img)
                import random
                live_pts = []
                import math
                # Jaw (17 points)
                for i in range(17):
                    a = math.pi * i / 16
                    live_pts.append([-60 * math.cos(a), 80 * math.sin(a)])
                # Right eyebrow (5 pts)
                for i in range(5): live_pts.append([-40 + i*10, -60])
                # Left eyebrow (5 pts)
                for i in range(5): live_pts.append([40 - i*10, -60])
                # Nose (9 pts)
                for i in range(4): live_pts.append([0, -40 + i*15])
                for i in range(5): live_pts.append([-20 + i*10, 20])
                # Right eye (6 pts)
                for i in range(6):
                    a = 2 * math.pi * i / 6
                    live_pts.append([-30 + 10*math.cos(a), -35 + 5*math.sin(a)])
                # Left eye (6 pts)
                for i in range(6):
                    a = 2 * math.pi * i / 6
                    live_pts.append([30 + 10*math.cos(a), -35 + 5*math.sin(a)])
                # Mouth (20 pts)
                for i in range(20):
                    a = 2 * math.pi * i / 20
                    live_pts.append([25*math.cos(a), 50 + 10*math.sin(a)])
                    
                live_pts = [[int(x), int(y)] for x, y in live_pts]
                
                offset = 2 if authorized else 40
                db_pts = [[p[0] + random.randint(-offset, offset), p[1] + random.randint(-offset, offset)] for p in live_pts]
                
                tcp_json = {
                    "image_jpeg_b64": base64.b64encode(buf).decode('ascii'),
                    "info_3d": {
                        "landmarks_3d_pts": live_pts,
                        "db_registered_3d_pts": db_pts
                    }
                }
            self.pages["monitor"].show_face(authorized, user_id, information, tcp_json)
        if authorized and information:
            command = self.users.command_for(information)
            self.client.rack_mask = command & 0x0F
            self.client.send_command(command)
            self.pages["racks"].update_rack_mask(command & 0x0F)
            self.add_event(f"인가 사용자 {user_id}: 출입문/허용 랙 OPEN", demo=demo)
        else:
            self.client.rack_mask = 0
            self.client.send_command(DOOR_CLOSE_CMD)
            self.pages["racks"].update_rack_mask(0)
            self.add_event(f"비인가 사용자 감지: {user_id or 'UNKNOWN'} · 출입문/랙 CLOSE", demo=demo)

    def _handle_crypto_event(self, event: dict) -> None:
        demo = bool(event.get("simulated", False))
        direction = event.get("direction", "?")
        packet_name = event.get("packet_name", "UNKNOWN")
        attack = bool(event.get("attack"))
        authenticated = bool(event.get("authenticated", False))
        if direction == "TX":
            result = "암호화 + UART 전송 완료" if event.get("delivered") else "암호화 완료 · UART 미전송"
        else:
            result = "TAG 인증 + 복호화 성공" if authenticated else "TAG 인증 실패 · 폐기"
        heading = "[INVALID KEY TX]" if attack else f"[AES-GCM {direction}]"
        lines = [
            f"{heading} {packet_name} · COUNTER={event.get('counter')} · {result}",
            f"  MASTER={event.get('master_key_hex', '')} · R={event.get('random_hex') or '(초기키/대기)' }",
        ]
        if attack:
            lines.append(f"  정상 SESSION={event.get('correct_key_hex', '')}")
            lines.append(f"  변조 SESSION={event.get('session_key_hex', '')}  ← 첫 비트 반전")
        else:
            lines.append(f"  SESSION=MASTER XOR R={event.get('session_key_hex', '')}")
        lines.extend(
            [
                f"  PLAIN={event.get('plaintext_hex') or '(복호화 실패)'} · IV={event.get('iv_hex', '')}",
                f"  CIPHER={event.get('ciphertext_hex', '')} · TAG={event.get('tag_hex', '')}",
            ]
        )
        self.add_event_block(lines, demo=demo, color=RED if attack or not authenticated else GREEN)

    def _log_sensor_transitions(self, event: dict, demo=False) -> None:
        threshold = int(self.config.get("fire_threshold", 30))
        for index, (temperature, humidity) in enumerate(zip(event["temperatures"], event["humidities"])):
            bit = 1 << index
            fire = bool(event["fire_mask"] & bit) or temperature >= threshold
            previously = bool(self.last_fire_mask & bit)
            if fire and not previously:
                self.add_event(f"{index + 1}번 랙 화재 감지 · {temperature}℃ / {humidity}% · 진압 서보 작동", demo=demo)
                self.last_fire_mask |= bit
            elif not fire and previously:
                self.add_event(f"{index + 1}번 랙 화재 상태 해제", demo=demo)
                self.last_fire_mask &= ~bit
        for index, state in enumerate(event["camera_states"]):
            previous = self.last_camera_states[index]
            if state != previous:
                names = {0: "비활성", 1: "정상", 2: "이상", 3: "비상"}
                if previous is not None or state >= 2:
                    self.add_event(f"4번 랙 OV7670 유닛 {index + 1}: {names.get(state, '알 수 없음')}", demo=demo)
                self.last_camera_states[index] = state

    def close(self) -> None:
        self.client.stop()
        self.pcam_ch_a_stream.close()
        if self.pcam_ch_b_stream is not self.pcam_ch_a_stream:
            self.pcam_ch_b_stream.close()
        self.face_stream.close()
        self.destroy()

    def _save_screenshot(self, destination: Path) -> None:
        self.deiconify()
        self.lift()
        self.attributes("-topmost", True)
        self.update_idletasks()
        left, top = self.winfo_rootx(), self.winfo_rooty()
        width, height = self.winfo_width(), self.winfo_height()
        destination.parent.mkdir(parents=True, exist_ok=True)
        ImageGrab.grab(bbox=(left, top, left + width, top + height)).save(destination)
        self.attributes("-topmost", False)
        self.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="AIGIS three-screen control-room UI")
    parser.add_argument("--simulate", action="store_true", help="run without UART hardware")
    parser.add_argument("--port", help="override serial port, e.g. COM10")
    parser.add_argument("--screenshot", type=Path, help="save one UI screenshot and exit")
    parser.add_argument("--page", choices=("monitor", "racks", "register"), default="monitor")
    parser.add_argument("--screenshot-delay", type=int, default=1400, help="screenshot delay in milliseconds")
    parser.add_argument("--show-registration-overlay", action="store_true", help="show registration success overlay")
    parser.add_argument("--show-face-overlay", action="store_true", help="show monitor Face ID overlay")
    parser.add_argument("--fullscreen", action="store_true", help="start in fullscreen mode")
    parser.add_argument("--show-wrong-key", action="store_true", help="show CH-B wrong-master-key blocking state")
    parser.add_argument("--random-key", action="store_true", help="use local PC generated random key for TCP instead of UART")
    parser.add_argument("--split-windows", action="store_true", help="open pages in separate windows")
    args = parser.parse_args()
    app = AigisApp(
        simulate=args.simulate,
        port=args.port,
        screenshot=args.screenshot,
        initial_page=args.page,
        screenshot_delay_ms=args.screenshot_delay,
        show_registration_overlay=args.show_registration_overlay,
        show_face_overlay=args.show_face_overlay,
        start_fullscreen=args.fullscreen,
        show_wrong_key=args.show_wrong_key,
        random_key=args.random_key,
        split_windows=args.split_windows,
    )
    app.mainloop()


if __name__ == "__main__":
    main()
