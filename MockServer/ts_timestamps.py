"""Shift the timestamps of an MPEG-TS so a looped sample plays as one stream.

The mock repeats a 12 s sample for the recorded HLS (60 segments made from 6
files) and for the pseudo live stream. Played as is, every repetition starts
over at the same PTS, which a real KonomiTV stream never does: libVLC resets
its clock at each repetition (to a bogus value and then back to the start),
and the app's position, comments and captions follow that clock. Adding the
loop length times the repetition index to every PCR, PTS and DTS makes the
repetitions continue each other instead. The continuity counters are moved
the same way (`repeat`), so the demuxer reports no TS discontinuity at the
seam either.
"""

from __future__ import annotations

TS_PACKET_SIZE = 188
TS_SYNC_BYTE = 0x47
CLOCK_MASK = (1 << 33) - 1

# PES stream ids without the optional PES header (ISO/IEC 13818-1 2.4.3.7).
_NO_PES_HEADER = {0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF}


def _read_timestamp(data: bytearray, offset: int) -> int:
    return (
        (((data[offset] >> 1) & 0x07) << 30)
        | (data[offset + 1] << 22)
        | (((data[offset + 2] >> 1) & 0x7F) << 15)
        | (data[offset + 3] << 7)
        | ((data[offset + 4] >> 1) & 0x7F)
    )


def _write_timestamp(data: bytearray, offset: int, value: int) -> None:
    value &= CLOCK_MASK
    prefix = data[offset] & 0xF0
    data[offset] = prefix | (((value >> 30) & 0x07) << 1) | 0x01
    data[offset + 1] = (value >> 22) & 0xFF
    data[offset + 2] = (((value >> 15) & 0x7F) << 1) | 0x01
    data[offset + 3] = (value >> 7) & 0xFF
    data[offset + 4] = ((value & 0x7F) << 1) | 0x01


def _shift_pcr(data: bytearray, offset: int, ticks: int) -> None:
    base = (
        (data[offset] << 25)
        | (data[offset + 1] << 17)
        | (data[offset + 2] << 9)
        | (data[offset + 3] << 1)
        | (data[offset + 4] >> 7)
    )
    extension = ((data[offset + 4] & 0x01) << 8) | data[offset + 5]
    base = (base + ticks) & CLOCK_MASK
    data[offset] = (base >> 25) & 0xFF
    data[offset + 1] = (base >> 17) & 0xFF
    data[offset + 2] = (base >> 9) & 0xFF
    data[offset + 3] = (base >> 1) & 0xFF
    data[offset + 4] = ((base & 0x01) << 7) | 0x7E | ((extension >> 8) & 0x01)
    data[offset + 5] = extension & 0xFF


def _pes_header_offset(data: bytearray, packet: int) -> tuple[int, int] | None:
    """(payload offset, end of packet) of a packet, or None without payload."""
    adaptation_field_control = (data[packet + 3] >> 4) & 0x03
    offset = packet + 4
    if adaptation_field_control in (2, 3):
        offset += 1 + data[offset]
    if adaptation_field_control not in (1, 3):
        return None
    return offset, packet + TS_PACKET_SIZE


def shift_timestamps(data: bytes, ticks: int) -> bytes:
    """Returns `data` with every PCR, PTS and DTS moved by `ticks` (90 kHz)."""
    if ticks == 0:
        return data
    out = bytearray(data)
    for packet in range(0, len(out) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE):
        if out[packet] != TS_SYNC_BYTE:
            raise ValueError(f"lost TS sync at byte {packet}")

        adaptation_field_control = (out[packet + 3] >> 4) & 0x03
        if adaptation_field_control in (2, 3):
            length = out[packet + 4]
            # PCR_flag; the PCR follows the flags byte.
            if length >= 7 and out[packet + 5] & 0x10:
                _shift_pcr(out, packet + 6, ticks)

        payload_unit_start = out[packet + 1] & 0x40
        located = _pes_header_offset(out, packet)
        if not payload_unit_start or located is None:
            continue
        offset, end = located
        if offset + 9 > end or out[offset:offset + 3] != b"\x00\x00\x01":
            continue
        if out[offset + 3] in _NO_PES_HEADER:
            continue
        flags = (out[offset + 7] >> 6) & 0x03
        if flags & 0x02 and offset + 14 <= end:
            _write_timestamp(out, offset + 9, _read_timestamp(out, offset + 9) + ticks)
        if flags == 0x03 and offset + 19 <= end:
            _write_timestamp(out, offset + 14, _read_timestamp(out, offset + 14) + ticks)
    return bytes(out)


def _pts_by_pid(data: bytes) -> dict[int, list[int]]:
    """Every PES PTS of `data` per PID, in stream order."""
    buffer = bytearray(data)
    values: dict[int, list[int]] = {}
    for packet in range(0, len(buffer) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE):
        if not buffer[packet + 1] & 0x40:
            continue
        located = _pes_header_offset(buffer, packet)
        if located is None:
            continue
        offset, end = located
        if offset + 14 > end or buffer[offset:offset + 3] != b"\x00\x00\x01":
            continue
        if buffer[offset + 3] in _NO_PES_HEADER:
            continue
        if (buffer[offset + 7] >> 6) & 0x02:
            pid = ((buffer[packet + 1] & 0x1F) << 8) | buffer[packet + 2]
            values.setdefault(pid, []).append(_read_timestamp(buffer, offset + 9))
    return values


def pts_values(data: bytes) -> list[int]:
    """Every PES PTS of `data`, in stream order per PID."""
    return [value for values in _pts_by_pid(data).values() for value in values]


def loop_length_ticks(data: bytes) -> int:
    """Length of one repetition of `data`: its PTS span plus one frame.

    The frame is the PTS step of the elementary stream with the most PES
    packets, so the next repetition starts one frame after this one ends.
    """
    by_pid = _pts_by_pid(data)
    if not by_pid:
        return 0
    everything = [value for values in by_pid.values() for value in values]
    busiest = sorted(set(max(by_pid.values(), key=len)))
    steps = [b - a for a, b in zip(busiest, busiest[1:]) if b > a]
    step = min(steps) if steps else 0
    return max(everything) - min(everything) + step


def continuity_counts(data: bytes) -> dict[int, int]:
    """Packets that advance the continuity counter, per PID.

    The counter goes up by one for every packet that carries a payload
    (adaptation_field_control 1 or 3); null packets are left out.
    """
    counts: dict[int, int] = {}
    for packet in range(0, len(data) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE):
        pid = ((data[packet + 1] & 0x1F) << 8) | data[packet + 2]
        if pid == 0x1FFF:
            continue
        if (data[packet + 3] >> 4) & 0x01:
            counts[pid] = counts.get(pid, 0) + 1
    return counts


def shift_continuity(data: bytes, steps: dict[int, int]) -> bytes:
    """Returns `data` with each PID's continuity counter advanced by `steps`.

    A repetition of a looped sample advanced by the counts of the whole loop
    (`continuity_counts`) times its index continues the counters of the one
    before, so a demuxer sees no TS discontinuity at the seam.
    """
    if not any(step % 16 for step in steps.values()):
        return data
    out = bytearray(data)
    for packet in range(0, len(out) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE):
        pid = ((out[packet + 1] & 0x1F) << 8) | out[packet + 2]
        step = steps.get(pid, 0) % 16
        if step == 0:
            continue
        counter = out[packet + 3] & 0x0F
        out[packet + 3] = (out[packet + 3] & 0xF0) | ((counter + step) & 0x0F)
    return bytes(out)


def repeat(data: bytes, repetition: int, ticks: int, counts: dict[int, int]) -> bytes:
    """`data` as repetition `repetition` of a loop: timestamps moved by
    `repetition * ticks`, continuity counters by `repetition * counts`."""
    if repetition == 0:
        return data
    shifted = shift_timestamps(data, repetition * ticks)
    return shift_continuity(shifted, {pid: repetition * count for pid, count in counts.items()})
