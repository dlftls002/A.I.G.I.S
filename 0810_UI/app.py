"""AIGIS three-screen operational control-room UI."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
from queue import Empty, Que
import tkinter as tk
from tkinter import messagebox, ttk

import cv2
from PIL import Image, ImageDraw, ImageGrab, ImageTk

from secure_serial_client import DOOR_CLOSE_CMD, MASTER_KEY, SecureSerialClient
from user_repository import UserRepository


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
        tk.Label(self, text=title, bg=BG, fg=TEXT, font=("Segoe UI", 56, "bold")).place(relx=0.5, y=43, anchor="center")

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
    def __init__(self, parent, title: str, stream: CameraStream, compact=False, title_font_size: int | None = None, center_title: bool = False) -> None:
        super().__init__(parent, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        self.stream = stream
        self.last_frame = None
        header_height = 34 if compact else max(40, (title_font_size or 11) + 24)
        header = tk.Frame(self, bg=PANEL, height=header_height)
        header.pack(fill="x")
        header.pack_propagate(False)
        title_label = tk.Label(
            header,
            text=f"●  {title}",
            bg=PANEL,
            fg=CYAN,
            font=("Segoe UI", title_font_size or (10 if compact else 11), "bold"),
        )
        if center_title:
            title_label.place(relx=0.5, rely=0.5, anchor="center")
        else:
            title_label.pack(side="left", padx=12)
        self.health = tk.Label(header, text="CAMERA READY", bg=PANEL, fg=GREEN, font=("Segoe UI", 8, "bold"))
        self.health.pack(side="right", padx=12)
        self.video = tk.Label(self, text="영상 입력 대기", bg="#01050c", fg=MUTED, font=("Malgun Gothic", 14))
        self.video.pack(fill="both", expand=True, padx=7, pady=(0, 7))
        self.after(30, self._update)

    def _update(self) -> None:
        frame = self.stream.read()
        if frame is not None:
            self.last_frame = frame.copy()
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            image = Image.fromarray(rgb)
            width = max(320, self.video.winfo_width())
            height = max(220, self.video.winfo_height())
            image.thumbnail((width, height), Image.Resampling.LANCZOS)
            photo = ImageTk.PhotoImage(image)
            self.video.config(image=photo, text="")
            self.video.image = photo
            self.health.config(text="LIVE", fg=GREEN)
        self.after(33, self._update)

    def save_snapshot(self, destination: Path) -> bool:
        if self.last_frame is None:
            return False
        destination.parent.mkdir(parents=True, exist_ok=True)
        return bool(cv2.imwrite(str(destination), self.last_frame))


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

    def __init__(self, parent) -> None:
        super().__init__(parent, bg=PANEL, height=310, highlightthickness=1, highlightbackground=BORDER)
        self.pack_propagate(False)
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
        channels = tk.Frame(stage, bg=BG)
        channels.place(relx=0, rely=0, relwidth=1, relheight=1)
        channels.grid_propagate(False)
        channels.grid_columnconfigure(0, weight=1, uniform="monitor")
        channels.grid_columnconfigure(1, weight=1, uniform="monitor")
        channels.grid_rowconfigure(0, weight=1)
        self.cctv = CameraPanel(channels, "PCAM CH-A · 정상 MASTER KEY · 복호화 성공", app.pcam_ch_a_stream)
        self.cctv.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        self.secure_camera = CameraPanel(channels, "PCAM CH-B · MASTER KEY 전환 시험", app.pcam_ch_b_stream)
        self.secure_camera.grid(row=0, column=1, sticky="nsew", padx=(6, 0))
        self.normal_master_hex = MASTER_KEY.hex().upper()
        wrong_master = bytes((MASTER_KEY[0] ^ 0x01,)) + MASTER_KEY[1:]
        self.wrong_master_hex = wrong_master.hex().upper()
        tk.Label(
            self.cctv,
            text=f"정상 마스터키  {self.normal_master_hex}",
            bg="#061325",
            fg=GREEN,
            font=("Consolas", 12, "bold"),
            padx=12,
            pady=7,
        ).place(relx=0.5, rely=0.975, anchor="s")
        self.right_normal_key = tk.Label(
            self.secure_camera,
            text=f"현재 정상 마스터키  {self.normal_master_hex}",
            bg="#061325",
            fg=GREEN,
            font=("Consolas", 12, "bold"),
            padx=12,
            pady=7,
        )
        self.right_normal_key.place(relx=0.5, rely=0.975, anchor="s")
        self.video_key_button = button(
            self.secure_camera,
            "오류 MASTER KEY 적용",
            lambda: self.set_video_key_mode(True),
            "#a41428",
            23,
            13,
            9,
        )
        self.video_key_button.place(relx=0.5, rely=0.90, anchor="s")
        self.good_block = tk.Frame(channels, bg="#08131f", highlightthickness=2, highlightbackground=ORANGE)
        self.good_block.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        tk.Label(self.good_block, text="🔐", bg="#08131f", fg=ORANGE, font=("Segoe UI Emoji", 45)).place(relx=0.5, rely=0.38, anchor="center")
        tk.Label(self.good_block, text="SECURE SESSION WAIT", bg="#08131f", fg=ORANGE, font=("Segoe UI", 23, "bold")).place(relx=0.5, rely=0.50, anchor="center")
        self.good_block_message = tk.Label(self.good_block, text="정상 마스터키 · 난수 교환 대기", bg="#08131f", fg="#ffd39b", font=("Malgun Gothic", 14, "bold"))
        self.good_block_message.place(relx=0.5, rely=0.57, anchor="center")

        # CH-B is the deliberate negative-control channel: the camera input is the
        # same PCAM feed, but a different master key must always fail GCM auth.
        self.bad_block = tk.Frame(channels, bg="#120812", highlightthickness=2, highlightbackground=RED)
        self.bad_block.grid(row=0, column=1, sticky="nsew", padx=(6, 0))
        tk.Label(self.bad_block, text="🔒", bg="#120812", fg=RED, font=("Segoe UI Emoji", 45)).place(relx=0.5, rely=0.34, anchor="center")
        tk.Label(self.bad_block, text="DECRYPTION FAILED", bg="#120812", fg=RED, font=("Segoe UI", 24, "bold")).place(relx=0.5, rely=0.47, anchor="center")
        self.bad_block_message = tk.Label(
            self.bad_block,
            text="MASTER KEY 불일치\nSESSION KEY 불일치 → GCM TAG 인증 실패\n영상 프레임 폐기",
            bg="#120812",
            fg="#ff9ca3",
            justify="center",
            font=("Malgun Gothic", 14, "bold"),
        )
        self.bad_block_message.place(relx=0.5, rely=0.59, anchor="center")
        self.bad_key_label = tk.Label(
            self.bad_block,
            text=f"오류 마스터키  {self.wrong_master_hex}",
            bg="#210a12",
            fg=RED,
            font=("Consolas", 12, "bold"),
            padx=12,
            pady=7,
        )
        self.bad_key_label.place(relx=0.5, rely=0.72, anchor="center")
        self.bad_restore_button = button(
            self.bad_block,
            "정상 MASTER KEY 복구",
            lambda: self.set_video_key_mode(False),
            "#0d6b3d",
            23,
            13,
            9,
        )
        self.bad_restore_button.place(relx=0.5, rely=0.82, anchor="center")
        self.video_invalid_mode = False
        self.bad_block.grid_remove()

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
        self.face_camera = CameraPanel(self.face_overlay, "FACE CAMERA LIVE", app.face_stream, compact=True)
        self.face_camera.pack(fill="both", expand=True, padx=12, pady=(0, 8))
        info = tk.Frame(self.face_overlay, bg="#061426", padx=15, pady=10)
        info.pack(fill="x", padx=12, pady=(0, 12))
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

    def set_security(self, text: str, color: str) -> None:
        self.header.set_security(text, color)

    def run_wrong_master_video_test(self) -> None:
        self.set_video_key_mode(True)

    def set_video_key_mode(self, invalid: bool) -> None:
        """Switch CH-B between the visible normal feed and wrong-key blocking."""
        self.video_invalid_mode = invalid
        if invalid:
            self.bad_block_message.config(
                text="정상 키와 다른 MASTER KEY 적용\nSESSION KEY 불일치 → GCM TAG 인증 실패\n영상 프레임 출력 차단"
            )
            self.bad_key_label.config(text=f"오류 마스터키  {self.wrong_master_hex}", fg=RED)
            self.bad_block.grid()
            self.bad_block.lift()
        else:
            self.bad_block.grid_remove()
            self.secure_camera.lift()

    def set_secure_video_allowed(self, allowed: bool, message: str = "") -> None:
        if allowed:
            self.good_block.grid_remove()
        else:
            self.good_block_message.config(text=message or "정상 마스터키 · 보안 세션 연결 대기")
            self.good_block.grid()
            self.good_block.lift()
        if self.video_invalid_mode:
            self.bad_block.grid()
            self.bad_block.lift()
        else:
            self.bad_block.grid_remove()

    def show_face(self, authorized: bool, user_id: str, information: dict | None) -> None:
        information = information or {}
        if authorized and information:
            self.face_status.config(text="인가 사용자", bg="#073523", fg=GREEN)
        else:
            self.face_status.config(text="비인가 사용자", bg="#4a1218", fg=RED)
        self.info_labels["name"].config(text=information.get("name", user_id or "UNKNOWN"))
        self.info_labels["department"].config(text=information.get("department", "-"))
        self.info_labels["position"].config(text=information.get("position", "-"))
        racks = [name.replace("RACK-0", "") for name, allowed in information.get("rack_control", {}).items() if allowed]
        self.info_labels["racks"].config(text=", ".join(racks) if racks else "-")
        self.face_overlay.place(relx=0.5, rely=0.5, width=760, height=610, anchor="center")
        self.face_overlay.lift()
        if self._hide_job:
            self.after_cancel(self._hide_job)
        seconds = int(self.app.config.get("face_overlay_seconds", 8))
        self._hide_job = self.after(seconds * 1000, self.hide_face)

    def hide_face(self) -> None:
        self.face_overlay.place_forget()
        self._hide_job = None


class RackCard(tk.Frame):
    def __init__(self, parent, rack_number: int, image: Image.Image, command, compact: bool = False) -> None:
        super().__init__(parent, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        self.rack_number = rack_number
        self.command = command
        self.compact = compact
        self.base_image = image
        self.alarm_level = 0
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
        if self.alarm_level:
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
        self.temperature.config(text=f"{temperature}℃", fg=RED if fire else CYAN)
        self.humidity.config(text=f"{humidity}%", fg=RED if fire else CYAN)
        if fire:
            self.health.config(text="● 화재 감지", fg=RED)
        elif not self.alarm_level:
            self.health.config(text="● 정상", fg=GREEN)

    def set_alarm(self, level: int) -> None:
        if self.alarm_level == level:
            return
        self.alarm_level = level
        if level:
            self.health.config(text="▲ 비전 이상 감지", fg=RED)
            self.state.config(text="비전 이상", bg="#7d111b", fg="white")
            self.config(highlightthickness=4, highlightbackground=RED)
            self._pulse_alarm()
        else:
            self.health.config(text="● 정상", fg=GREEN)
            self.config(highlightthickness=1, highlightbackground=BORDER)
            self.state.config(
                text="OPEN" if self.opened else "CLOSE",
                bg="#073b27" if self.opened else "#10243d",
                fg=GREEN if self.opened else CYAN,
            )
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
        tk.Label(control_panel, text="RACK CONTROL", bg=PANEL, fg=CYAN, font=("Segoe UI", 27, "bold")).pack(fill="x", pady=(10, 7))

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

        key_select = tk.Frame(controls, bg="#071d31", highlightthickness=1, highlightbackground=CYAN)
        key_select.pack(fill="x", pady=3)
        tk.Label(key_select, text="MASTER KEY 선택", bg="#071d31", fg=CYAN, font=("Malgun Gothic", 13, "bold")).pack(side="left", padx=10)
        self.normal_key_button = button(key_select, "현재 마스터키", lambda: app.set_command_key_mode(False), "#0d6b3d", 13, 11, 6)
        self.normal_key_button.pack(side="left", padx=4, pady=5, expand=True, fill="x")
        self.fake_key_button = button(key_select, "가짜 마스터키", lambda: app.set_command_key_mode(True), "#4b2230", 13, 11, 6)
        self.fake_key_button.pack(side="left", padx=4, pady=5, expand=True, fill="x")
        self.key_mode_value = tk.Label(
            controls,
            text=f"현재 마스터키  {MASTER_KEY.hex().upper()}",
            bg="#061425",
            fg=GREEN,
            font=("Consolas", 10, "bold"),
            pady=5,
        )
        self.key_mode_value.pack(fill="x", pady=(0, 3))

        def control_row(label: str, open_text: str, open_command, close_text: str, close_command) -> None:
            row = tk.Frame(controls, bg="#091d34", highlightthickness=1, highlightbackground=BORDER)
            row.pack(fill="x", pady=3)
            tk.Label(row, text=label, width=11, anchor="w", bg="#091d34", fg=TEXT, font=("Malgun Gothic", 13, "bold")).pack(side="left", padx=10)
            button(row, open_text, open_command, "#0d6b3d", 10, 11, 6).pack(side="left", padx=4, pady=5, expand=True, fill="x")
            button(row, close_text, close_command, "#8c1f29", 10, 11, 6).pack(side="left", padx=4, pady=5, expand=True, fill="x")

        control_row("출입문", "OPEN", lambda: app.set_door(True), "CLOSE", lambda: app.set_door(False))
        control_row("전체 RACK", "ALL OPEN", lambda: app.set_all_racks(True), "ALL CLOSE", lambda: app.set_all_racks(False))
        attack = tk.Frame(controls, bg="#2a0b14", highlightthickness=1, highlightbackground=RED)
        attack.pack(fill="x", pady=3)
        tk.Label(attack, text="보안 공격 시험", bg="#2a0b14", fg=RED, font=("Malgun Gothic", 13, "bold")).pack(side="left", padx=10)
        button(attack, "INVALID KEY 전송", app.run_invalid_key_test, "#a41428", 17, 11, 7).pack(side="right", padx=7, pady=5, expand=True, fill="x")
        monitoring = tk.Frame(body, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        monitoring.grid(row=0, column=1, sticky="nsew", padx=(7, 0))
        tk.Label(monitoring, text="MONITORING", bg=PANEL, fg=CYAN, font=("Segoe UI", 27, "bold")).pack(fill="x", pady=(10, 4))
        self.security_flow = SecurityFlowPanel(monitoring)
        self.security_flow.pack(fill="both", expand=True, padx=8, pady=(0, 8))
        self.log = self.security_flow.log

        self.alert = tk.Frame(self, bg="#3b0a12", highlightthickness=4, highlightbackground=RED)
        self.alert_title = tk.Label(self.alert, text="", bg="#3b0a12", fg=RED, font=("Malgun Gothic", 25, "bold"))
        self.alert_title.pack(padx=30, pady=(22, 7))
        self.alert_message = tk.Label(self.alert, text="", bg="#3b0a12", fg="white", font=("Malgun Gothic", 17, "bold"))
        self.alert_message.pack(padx=30, pady=(0, 22))

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
        for index, card in enumerate(self.cards):
            card.set_sensor(event["temperatures"][index], event["humidities"][index], bool(event["fire_mask"] & (1 << index)))
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
        button(actions, "등록", self.register, "#0d7a43", 9, 17, 11).pack(side="left", padx=(0, 8), expand=True, fill="x")
        button(actions, "취소", self.clear, "#9b2029", 9, 17, 11).pack(side="left", expand=True, fill="x")
        self.note = tk.Label(form, text="얼굴 프레임과 사용자 권한을 등록합니다.", bg=PANEL, fg=MUTED, font=("Malgun Gothic", 13), wraplength=300)
        self.note.pack(anchor="center", pady=(12, 0))

        contour = tk.Frame(body, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        contour.grid(row=0, column=2, sticky="nsew", padx=(7, 0))
        tk.Label(contour, text="3D 윤곽 DATA", bg=PANEL, fg=CYAN, font=("Segoe UI", 28, "bold")).pack(anchor="center", padx=17, pady=(14, 5))
        tk.Label(contour, text="FACE GEOMETRY / DEPTH MAP", bg=PANEL, fg=MUTED, font=("Segoe UI", 15, "bold")).pack(anchor="center", padx=18)
        self.contour_canvas = tk.Canvas(contour, bg="#020914", highlightthickness=0)
        self.contour_canvas.pack(fill="both", expand=True, padx=14, pady=12)
        self.contour_canvas.bind("<Configure>", self._draw_contour)
        self.assigned_id = tk.Label(contour, text="ASSIGNED FACE ID · 대기", bg="#091d34", fg=GREEN, font=("Consolas", 17, "bold"), pady=13)
        self.assigned_id.pack(fill="x", padx=14, pady=(0, 14))

        self.overlay = tk.Frame(self, bg="#0b7d45", highlightthickness=2, highlightbackground="#7fffc0", height=72)
        self.overlay.pack_propagate(False)
        tk.Label(self.overlay, text="✓  등록이 완료되었습니다.", bg="#0b7d45", fg="white", font=("Malgun Gothic", 24, "bold")).pack(expand=True)

    def _draw_contour(self, event=None) -> None:
        canvas = self.contour_canvas
        canvas.delete("contour")
        width = max(240, canvas.winfo_width())
        height = max(300, canvas.winfo_height())
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
        values = {key: entry.get().strip() for key, entry in self.entries.items()}
        if not values["name"]:
            messagebox.showwarning("입력 확인", "이름을 입력해 주세요.")
            return
        user_id = f"U{datetime.now():%m%d%H%M%S}"
        rack_control = {f"RACK-{index + 1:02d}": variable.get() for index, variable in enumerate(self.rack_vars)}
        information = {
            "name": values["name"],
            "department": values["department"],
            "position": values["position"],
            "open_entrance": self.entrance_var.get(),
            "rack_control": rack_control,
        }
        try:
            self.app.users.save(user_id, information)
            snapshot_path = FACE_REGISTRY_DIR / f"{user_id}.jpg"
            captured = self.camera.save_snapshot(snapshot_path)
            self.assigned_id.config(text=f"ASSIGNED FACE ID · {user_id}")
            self.app.add_event(f"사용자 등록 완료: {user_id} / 얼굴 이미지 {'저장' if captured else '미저장'}")
            self.show_success()
        except OSError as error:
            messagebox.showerror("등록 실패", str(error))

    def show_success(self) -> None:
        self.overlay.place(relx=0.5, rely=0.985, relwidth=0.72, height=72, anchor="s")
        self.overlay.lift()
        self.after(2200, self._finish_success)

    def _finish_success(self) -> None:
        self.overlay.place_forget()
        self.clear()

    def clear(self) -> None:
        for entry in self.entries.values():
            entry.delete(0, tk.END)
        for variable, selector in zip(self.rack_vars, self.rack_selectors):
            variable.set(False)
            selector._refresh()
        self.entrance_var.set(True)


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
        self.pcam_ch_a_stream = CameraStream(None if simulate else source_a)
        self.pcam_ch_b_stream = self.pcam_ch_a_stream if source_b == source_a else CameraStream(None if simulate else source_b)
        self.cctv_stream = self.pcam_ch_a_stream
        self.face_stream = CameraStream(None if simulate else self.config.get("face_camera_source"))
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
        self.bind("<F11>", self.toggle_fullscreen)
        self.bind("<Escape>", self.exit_fullscreen)
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
            self.after(300, lambda: self.pages["monitor"].set_video_key_mode(True))
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.after(60, self._drain_events)
        self.client.start()
        if screenshot:
            self.after(screenshot_delay_ms, lambda: self._save_screenshot(screenshot))

    def show_page(self, name: str) -> None:
        self.current_page = name
        self.pages[name].lift()

    def toggle_fullscreen(self, _event=None) -> None:
        if self._fullscreen:
            self.exit_fullscreen()
            return
        self._windowed_geometry = self.geometry()
        self._fullscreen = True
        self.resizable(True, True)
        self.maxsize(self.winfo_screenwidth(), self.winfo_screenheight())
        self.attributes("-fullscreen", True)

    def exit_fullscreen(self, _event=None) -> None:
        if not self._fullscreen:
            return
        self._fullscreen = False
        self.attributes("-fullscreen", False)
        self.maxsize(*self._windowed_maxsize)
        self.resizable(False, False)
        self.geometry(self._windowed_geometry)

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
        try:
            while True:
                self._handle_event(self.event_queue.get_nowait())
        except Empty:
            pass
        self.after(60, self._drain_events)

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
            self.pages["monitor"].bad_block_message.config(text="INVALID MASTER KEY 시험\nSESSION KEY 불일치 → GCM TAG 인증 실패\n명령/영상 프레임 폐기")
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

    def _handle_face(self, event: dict, demo=False) -> None:
        user_id = event.get("user_id", "")
        information = self.users.get(user_id) if event.get("authorized") else None
        authorized = bool(event.get("authorized") and information)
        self.pages["racks"].security_flow.animate_face(
            f"FACE ID {user_id or 'UNKNOWN'} · {'AUTHORIZED' if authorized else 'DENIED'}"
        )
        # Face ID must never pull an operator away from the rack or registration
        # page. The overlay is presented only while the monitor page is active.
        if self.current_page == "monitor":
            self.pages["monitor"].show_face(authorized, user_id, information)
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
    )
    app.mainloop()


if __name__ == "__main__":
    main()
