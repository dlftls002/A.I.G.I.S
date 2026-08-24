"""User metadata and rack authorization persistence."""

from __future__ import annotations

import json
from pathlib import Path


DEFAULT_DB_PATH = Path(__file__).resolve().parent / "users.json"


class UserRepository:
    def __init__(self, path: Path = DEFAULT_DB_PATH) -> None:
        self.path = path

    def load_all(self) -> dict:
        if not self.path.exists():
            return {}
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {}

    def get(self, user_id: str) -> dict | None:
        return self.load_all().get(user_id)

    def save(self, user_id: str, information: dict) -> None:
        users = self.load_all()
        users[user_id] = information
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(users, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(self.path)

    @staticmethod
    def command_for(information: dict) -> int:
        command = 0x10 if information.get("open_entrance", False) else 0x20
        rack_control = information.get("rack_control", {})
        for rack_number in range(1, 5):
            if rack_control.get(f"RACK-{rack_number:02d}", False):
                command |= 1 << (rack_number - 1)
        return command
