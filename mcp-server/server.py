import hashlib
import re
import tempfile
from pathlib import Path
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("flashguard-chaos")
SANDBOX_ROOT = Path(tempfile.gettempdir()) / "flashguard_virtual_drives"
SANDBOX_ROOT.mkdir(parents=True, exist_ok=True)


def _drive_path(name: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", name):
        raise ValueError("Drive name must contain only letters, digits, _ or -")
    return SANDBOX_ROOT / name


def _sandbox_file(path: str) -> Path:
    candidate = Path(path).resolve()
    if candidate.parent.parent != SANDBOX_ROOT.resolve() or not candidate.is_file():
        raise ValueError("Expected a file inside a virtual drive")
    return candidate


def _box(kind: bytes, payload: bytes) -> bytes:
    return (len(payload) + 8).to_bytes(4, "big") + kind + payload


def _mp4_valid(raw: bytes) -> bool:
    offset = 0
    saw_moov = False
    while offset < len(raw):
        if len(raw) - offset < 8:
            return False
        size = int.from_bytes(raw[offset:offset + 4], "big")
        kind = raw[offset + 4:offset + 8]
        if offset == 0 and kind != b"ftyp":
            return False
        if size < 8 or size > len(raw) - offset:
            return False
        saw_moov |= kind == b"moov"
        offset += size
    return saw_moov


@mcp.tool()
def create_virtual_drive(drive_name: str = "sandisk_extreme_ssd") -> str:
    """Creates a simulated external SSD mount with valid, duplicate, and corrupted media fixtures."""
    drive_path = _drive_path(drive_name)
    drive_path.mkdir(parents=True, exist_ok=True)

    # 1. Valid minimal JPEG (SOI + payload + EOI)
    valid_jpg = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" + (b"\xaa" * 2048) + b"\xff\xd9"
    (drive_path / "IMG_001_original.jpg").write_bytes(valid_jpg)
    # 2. Exact byte-for-byte duplicate under a different filename
    (drive_path / "IMG_001_copy.jpg").write_bytes(valid_jpg)

    # 3. Valid MP4 skeleton (ftyp + moov atoms)
    ftyp = _box(b"ftyp", b"mp42\x00\x00\x00\x00mp42isom")
    valid_mp4 = ftyp + _box(b"moov", b"\x11" * 4096)
    (drive_path / "VID_4K_valid.mp4").write_bytes(valid_mp4)

    # 4. Corrupted/Truncated MP4 (ftyp present, moov atom missing due to sudden disconnect)
    corrupt_mp4 = ftyp + _box(b"mdat", b"\x22" * 1024)
    (drive_path / "VID_4K_corrupt_disconnect.mp4").write_bytes(corrupt_mp4)

    return f"Virtual drive mounted at: {drive_path}"


@mcp.tool()
def simulate_mid_transfer_disconnect(target_file_path: str) -> str:
    """Truncates a file mid-stream to simulate an accidental USB-C cable yank during transfer."""
    path = _sandbox_file(target_file_path)
    data = path.read_bytes()
    truncated = data[: max(1, len(data) // 3)]
    path.write_bytes(truncated)
    return f"Simulated disconnect: truncated {path.name} from {len(data)}B to {len(truncated)}B."


@mcp.tool()
def verify_drive_ground_truth(drive_path: str) -> dict:
    """Computes ground-truth SHA-256 hashes and structural validity for test assertions."""
    root = _drive_path(Path(drive_path).name)
    if root.resolve() != Path(drive_path).resolve() or not root.is_dir():
        raise ValueError("Expected an existing virtual drive")
    report = {}
    for file in sorted(root.iterdir()):
        if file.is_file():
            raw = file.read_bytes()
            sha = hashlib.sha256(raw).hexdigest()
            is_valid = True
            if file.suffix.lower() == ".jpg":
                is_valid = raw.startswith(b"\xff\xd8") and raw.endswith(b"\xff\xd9")
            elif file.suffix.lower() == ".mp4":
                is_valid = _mp4_valid(raw)
            report[file.name] = {"bytes": len(raw), "sha256": sha, "structurally_valid": is_valid}
    return report


if __name__ == "__main__":
    mcp.run()
