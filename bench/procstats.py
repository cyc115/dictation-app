"""What a local server process costs this Mac, read without root: memory (footprint, resident),
CPU time (ps) and GPU time (the GPU driver's per-process count in ioreg). Energy is an estimate from
those times, since the real meter (powermetrics) needs sudo."""
from __future__ import annotations

import plistlib
import re
import subprocess

# Rough watts while busy on an M1 Max (AnandTech's measurements: ~4–5 W per busy performance core,
# ~40 W with the 32-core GPU fully loaded). A small model rarely fills the GPU, so energy from these
# is an upper bound; powermetrics measures it.
CPU_WATTS = 5.0
GPU_WATTS = 40.0


def _out(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout


def pid_on_port(port: int) -> int | None:
    """The process listening on localhost:`port`."""
    found = _out(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"]).split()
    return int(found[0]) if found else None


def cpu_seconds(pid: int) -> float:
    """User + system CPU time so far (ps's cputime: [[h:]m:]s.cc)."""
    parts = _out(["ps", "-o", "cputime=", "-p", str(pid)]).strip().split(":")
    return sum(float(p) * 60 ** i for i, p in enumerate(reversed(parts))) if parts != [""] else 0.0


def gpu_seconds(pid: int) -> float:
    """GPU time so far, summed over the process's Metal clients (AppUsage accumulatedGPUTime, ns)."""
    raw = subprocess.run(["ioreg", "-a", "-r", "-c", "AGXDeviceUserClient"], capture_output=True, timeout=30).stdout
    clients = plistlib.loads(raw) if raw.strip() else []
    total = 0
    for client in clients:
        if re.match(rf"pid {pid},", client.get("IOUserClientCreator", "")):
            total += sum(u.get("accumulatedGPUTime", 0) for u in client.get("AppUsage", []))
    return total / 1e9


def memory_mb(pid: int) -> dict:
    """footprint: the memory the process owns (dirty; what Activity Monitor's Memory column shows);
    footprint_peak: the most it has owned since it started; resident: also counts the model file pages
    it has mapped in, which macOS can drop under pressure but must read back on the next decision."""
    text = _out(["footprint", "-p", str(pid)])
    mb = lambda name: _mb(re.search(rf"{name}:\s*([\d.]+\s*[KMG]?B)", text))  # noqa: E731
    rss_kb = _out(["ps", "-o", "rss=", "-p", str(pid)]).strip()
    return {"footprint": mb("phys_footprint"), "footprint_peak": mb("phys_footprint_peak"),
            "resident": round(int(rss_kb) / 1024) if rss_kb else None}


def _mb(found: re.Match | None) -> float | None:
    if not found:
        return None
    number, unit = re.match(r"([\d.]+)\s*([KMG]?B)", found.group(1)).groups()
    return round(float(number) * {"B": 1 / 2**20, "KB": 1 / 1024, "MB": 1, "GB": 1024}[unit])


def battery_wh() -> float | None:
    """This Mac's battery when full, in watt-hours (None on a Mac without one)."""
    raw = subprocess.run(["ioreg", "-a", "-r", "-c", "AppleSmartBattery"], capture_output=True, timeout=30).stdout
    found = plistlib.loads(raw) if raw.strip() else []
    if not found:
        return None
    b = found[0] | found[0].get("BatteryData", {})
    mah = b.get("FullChargeCapacity") or b.get("NominalChargeCapacity") or b.get("DesignCapacity")
    volts = (b.get("Voltage") or 0) / 1000  # the voltage now, not the nominal one: within a few %
    return round(mah * volts / 1000, 1) if mah and volts else None


def energy_joules(cpu: float, gpu: float, cpu_watts: float = CPU_WATTS, gpu_watts: float = GPU_WATTS) -> float:
    return cpu * cpu_watts + gpu * gpu_watts
