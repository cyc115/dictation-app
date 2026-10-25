"""Tests for procstats: reading a process's memory, CPU and GPU time. Run: uv run --with pytest pytest bench"""
import os

import procstats


def test_reads_this_process():
    pid = os.getpid()
    assert procstats.cpu_seconds(pid) > 0
    assert procstats.gpu_seconds(pid) >= 0
    memory = procstats.memory_mb(pid)
    assert memory["resident"] > 0 and memory["footprint"] > 0 and memory["footprint_peak"] >= memory["footprint"]


def test_energy_is_busy_time_times_watts():
    assert procstats.energy_joules(0.1, 0.01, cpu_watts=5, gpu_watts=40) == 0.9
