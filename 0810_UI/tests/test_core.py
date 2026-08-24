from pathlib import Path
from queue import Queue
import tempfile
import unittest

from secure_serial_client import MASTER_KEY, SecureSerialClient
from user_repository import UserRepository


class RackCommandTests(unittest.TestCase):
    def setUp(self):
        self.client = SecureSerialClient(Queue(), simulate=True)

    def test_individual_open_and_close_preserve_other_bits(self):
        self.client.set_rack(1, True)
        self.client.set_rack(3, True)
        self.assertEqual(self.client.rack_mask, 0b0101)
        self.client.set_rack(1, False)
        self.assertEqual(self.client.rack_mask, 0b0100)

    def test_all_open_and_close(self):
        self.client.set_all_racks(True)
        self.assertEqual(self.client.rack_mask, 0b1111)
        self.client.set_all_racks(False)
        self.assertEqual(self.client.rack_mask, 0)

    def test_secure_command_emits_real_frame_details(self):
        self.client.send_command(0x11)
        events = []
        while not self.client.events.empty():
            events.append(self.client.events.get_nowait())
        crypto = next(event for event in events if event["type"] == "crypto")
        self.assertEqual(crypto["plaintext_hex"], "11" + "00" * 15)
        self.assertEqual(len(crypto["iv_hex"]), 24)
        self.assertEqual(len(crypto["ciphertext_hex"]), 32)
        self.assertEqual(len(crypto["tag_hex"]), 32)
        self.assertNotEqual(crypto["plaintext_hex"], crypto["ciphertext_hex"])

    def test_invalid_key_test_never_changes_rack_state(self):
        self.client.rack_mask = 0b0101
        self.client.send_invalid_key_all_open()
        self.assertEqual(self.client.rack_mask, 0b0101)
        events = []
        while not self.client.events.empty():
            events.append(self.client.events.get_nowait())
        crypto = next(event for event in events if event["type"] == "crypto")
        self.assertTrue(crypto["attack"])
        self.assertNotEqual(crypto["master_key_hex"], MASTER_KEY.hex().upper())
        self.assertNotEqual(crypto["session_key_hex"], crypto["correct_key_hex"])

    def test_invalid_key_command_preserves_state_and_payload(self):
        self.client.rack_mask = 0b0011
        self.client.send_invalid_key_command(0x1F)
        self.assertEqual(self.client.rack_mask, 0b0011)
        events = []
        while not self.client.events.empty():
            events.append(self.client.events.get_nowait())
        crypto = next(event for event in events if event["type"] == "crypto")
        attack = next(event for event in events if event["type"] == "attack_test")
        self.assertEqual(crypto["plaintext_hex"], "1F" + "00" * 15)
        self.assertEqual(attack["command"], 0x1F)


class UserRepositoryTests(unittest.TestCase):
    def test_save_load_and_command(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = UserRepository(Path(directory) / "users.json")
            information = {
                "name": "Tester",
                "department": "AIGIS",
                "position": "Engineer",
                "open_entrance": True,
                "rack_control": {
                    "RACK-01": True,
                    "RACK-02": False,
                    "RACK-03": True,
                    "RACK-04": False,
                },
            }
            repository.save("tester", information)
            self.assertEqual(repository.get("tester"), information)
            self.assertEqual(repository.command_for(information), 0x15)


if __name__ == "__main__":
    unittest.main()
