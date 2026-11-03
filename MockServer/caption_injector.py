#!/usr/bin/env python3
"""Inject an ARIB STD-B24 caption stream into the mock MPEG-TS media.

The fixture media (media/sample.ts and media/hls/segment*.ts) was produced
without caption elementary streams. This module rewrites the PMT to advertise a
caption PID (0x0130, stream_type 0x06, stream_identifier_descriptor
component_tag 0x30) and inserts real caption PES packets so the iOS client can
exercise the ARIB caption decoder and renderer.

Python standard library only. Everything is generated in memory at server
start / on first request; no binary media is committed.
"""

from __future__ import annotations

import struct

TS_PACKET_SIZE = 188
TS_SYNC_BYTE = 0x47

CAPTION_PID = 0x0130
CAPTION_COMPONENT_TAG = 0x30

# Captions are inserted at these offsets (seconds) from the first video PTS.
DEFAULT_CAPTIONS: tuple[tuple[float, str], ...] = (
    (0.2, "テスト字幕"),
    (1.2, "二行目の字幕"),
    (3.2, "テスト字幕"),
    (4.2, "二行目の字幕"),
    (6.2, "テスト字幕"),
    (7.2, "二行目の字幕"),
    (9.2, "テスト字幕"),
    (10.2, "二行目の字幕"),
)

_CRC_TABLE: list[int] = []
for _index in range(256):
    _crc = _index << 24
    for _ in range(8):
        _crc = ((_crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if _crc & 0x80000000 else (_crc << 1) & 0xFFFFFFFF
    _CRC_TABLE.append(_crc)


def mpeg2_crc32(data: bytes) -> int:
    """CRC-32/MPEG-2 used by PSI sections."""
    crc = 0xFFFFFFFF
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) ^ byte) & 0xFF]
    return crc


def _u16(value: int) -> bytes:
    return bytes(((value >> 8) & 0xFF, value & 0xFF))


def _u24(value: int) -> bytes:
    return bytes(((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF))


def _packet_payload(packet: bytes) -> bytes:
    """Payload bytes of a 188-byte TS packet, without adaptation-field stuffing."""
    if len(packet) != TS_PACKET_SIZE or packet[0] != TS_SYNC_BYTE:
        return b""
    adaptation_field_control = (packet[3] >> 4) & 0x03
    offset = 4
    if adaptation_field_control in (2, 3):
        offset += 1 + packet[4]
    if adaptation_field_control not in (1, 3) or offset >= TS_PACKET_SIZE:
        return b""
    return packet[offset:]


def _packet_pid(packet: bytes) -> int:
    return ((packet[1] & 0x1F) << 8) | packet[2]


def _iter_packets(data: bytes):
    for offset in range(0, len(data) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE):
        packet = data[offset:offset + TS_PACKET_SIZE]
        if packet[0] != TS_SYNC_BYTE:
            raise ValueError(f"lost TS sync at byte {offset}")
        yield packet


def _section_from_payload(payload: bytes) -> bytes | None:
    if len(payload) < 4:
        return None
    pointer = payload[0]
    start = 1 + pointer
    if start + 3 > len(payload):
        return None
    section_length = ((payload[start + 1] & 0x0F) << 8) | payload[start + 2]
    total = 3 + section_length
    if start + total > len(payload):
        return None
    return payload[start:start + total]


def _pat_pmt_pid(data: bytes) -> int | None:
    for packet in _iter_packets(data):
        if _packet_pid(packet) != 0 or not (packet[1] & 0x40):
            continue
        section = _section_from_payload(_packet_payload(packet))
        if section is None or section[0] != 0x00 or len(section) < 12:
            continue
        section_end = 3 + (((section[1] & 0x0F) << 8) | section[2])
        offset = 8
        while offset + 4 <= min(section_end - 4, len(section)):
            program_number = (section[offset] << 8) | section[offset + 1]
            pid = ((section[offset + 2] & 0x1F) << 8) | section[offset + 3]
            if program_number != 0:
                return pid
            offset += 4
    return None


def _pmt_section(data: bytes, pmt_pid: int) -> bytes | None:
    for packet in _iter_packets(data):
        if _packet_pid(packet) != pmt_pid or not (packet[1] & 0x40):
            continue
        section = _section_from_payload(_packet_payload(packet))
        if section is not None and section[0] == 0x02:
            return section
    return None


def _video_pid(data: bytes, pmt_pid: int) -> int | None:
    section = _pmt_section(data, pmt_pid)
    if section is None:
        return None
    section_end = 3 + (((section[1] & 0x0F) << 8) | section[2]) - 4
    program_info_length = ((section[10] & 0x0F) << 8) | section[11]
    offset = 12 + program_info_length
    while offset + 5 <= section_end:
        stream_type = section[offset]
        pid = ((section[offset + 1] & 0x1F) << 8) | section[offset + 2]
        es_info_length = ((section[offset + 3] & 0x0F) << 8) | section[offset + 4]
        if stream_type in (0x1B, 0x24):
            return pid
        offset += 5 + es_info_length
    return None


def _pmt_has_caption(section: bytes) -> bool:
    section_end = 3 + (((section[1] & 0x0F) << 8) | section[2]) - 4
    program_info_length = ((section[10] & 0x0F) << 8) | section[11]
    offset = 12 + program_info_length
    while offset + 5 <= section_end:
        stream_type = section[offset]
        pid = ((section[offset + 1] & 0x1F) << 8) | section[offset + 2]
        es_info_length = ((section[offset + 3] & 0x0F) << 8) | section[offset + 4]
        cursor = offset + 5
        end = cursor + es_info_length
        while cursor + 2 <= end:
            tag = section[cursor]
            length = section[cursor + 1]
            value = section[cursor + 2:cursor + 2 + length]
            if stream_type == 0x06 and tag == 0x52 and len(value) == 1 and 0x30 <= value[0] <= 0x37:
                return True
            cursor += 2 + length
        offset = end
    return False


def _rewrite_pmt_section(section: bytes) -> bytes:
    """Append the caption ES entry and recompute section_length + CRC."""
    if _pmt_has_caption(section):
        return section

    section_length = ((section[1] & 0x0F) << 8) | section[2]
    section_end = 3 + section_length - 4  # excluding CRC
    program_info_length = ((section[10] & 0x0F) << 8) | section[11]
    insertion = 12 + program_info_length
    # Walk the existing ES loop to find its end (equals section_end).
    offset = insertion
    while offset + 5 <= section_end:
        es_info_length = ((section[offset + 3] & 0x0F) << 8) | section[offset + 4]
        offset += 5 + es_info_length
    insertion = offset

    entry = bytes((
        0x06,
        0xE0 | ((CAPTION_PID >> 8) & 0x1F),
        CAPTION_PID & 0xFF,
        0xF0, 0x04,
        0x52, 0x01, CAPTION_COMPONENT_TAG,
    ))
    body = section[:insertion] + entry + section[insertion:section_end]
    new_section_length = len(body) - 3 + 4
    if new_section_length > 0x3FD:
        raise ValueError("PMT section too long after adding the caption stream")
    body = bytes((
        0x02,
        (section[1] & 0xF0) | ((new_section_length >> 8) & 0x0F),
        new_section_length & 0xFF,
    )) + body[3:]
    return body + struct.pack(">I", mpeg2_crc32(body))


def _make_ts_packet(pid: int, payload_unit_start: bool, payload: bytes, continuity: int) -> bytes:
    """Build a packet whose payload is exactly payload (adaptation stuffing)."""
    if len(payload) > 184:
        raise ValueError("payload does not fit in one TS packet")
    if len(payload) == 184:
        header = bytes((
            TS_SYNC_BYTE,
            (0x40 if payload_unit_start else 0x00) | ((pid >> 8) & 0x1F),
            pid & 0xFF,
            0x10 | (continuity & 0x0F),
        ))
        return header + payload

    header = bytearray([
        TS_SYNC_BYTE,
        (0x40 if payload_unit_start else 0x00) | ((pid >> 8) & 0x1F),
        pid & 0xFF,
        0x30 | (continuity & 0x0F),
    ])
    adaptation_length = 183 - len(payload)
    packet = header + bytes((adaptation_length,))
    if adaptation_length:
        packet += b"\x00" + b"\xFF" * (adaptation_length - 1)
    packet += payload
    assert len(packet) == TS_PACKET_SIZE
    return bytes(packet)


def _rewrite_pmt(data: bytes, pmt_pid: int, section: bytes) -> bytes:
    rewritten = _rewrite_pmt_section(section)
    if rewritten == section:
        return data
    # Every PMT in the segment must advertise the caption stream: a later PMT
    # without it (same version) tells the demuxer the stream vanished, and
    # AVPlayer rejects the segment.
    out = bytearray()
    replaced = False
    for packet in _iter_packets(data):
        if _packet_pid(packet) == pmt_pid and (packet[1] & 0x40):
            continuity = packet[3] & 0x0F
            payload = b"\x00" + rewritten
            if len(payload) > 184:
                raise ValueError("rewritten PMT does not fit in one TS packet")
            payload += b"\xFF" * (184 - len(payload))
            out += _make_ts_packet(pmt_pid, True, payload, continuity)
            replaced = True
        else:
            out += packet
    if not replaced:
        raise ValueError("PMT packet not found")
    return bytes(out)


def _encode_pts(pts: int) -> bytes:
    pts &= (1 << 33) - 1
    return bytes((
        0x21 | (((pts >> 30) & 0x07) << 1),
        (pts >> 22) & 0xFF,
        0x01 | (((pts >> 15) & 0x7F) << 1),
        (pts >> 7) & 0xFF,
        0x01 | ((pts & 0x7F) << 1),
    ))


def _decode_pts(field: bytes) -> int:
    return (
        (((field[0] >> 1) & 0x07) << 30)
        | (field[1] << 22)
        | (((field[2] >> 1) & 0x7F) << 15)
        | (field[3] << 7)
        | ((field[4] >> 1) & 0x7F)
    )


def _euc_jp_to_arib_gl(text: str) -> bytes:
    """Encode text for a Profile A statement using GL (G0 = Kanji).

    EUC-JP maps JIS X 0208 cells to 0xA1...0xFE; subtracting 0x80 gives the GL
    bytes 0x21...0x7E that ARIB STD-B24 uses for the same cells. ASCII is
    switched to the alphanumeric G set with LS1 / LS0.
    """
    out = bytearray()
    for character in text:
        if character == " ":
            out.append(0x20)
            continue
        encoded = character.encode("euc_jp")
        if len(encoded) == 2 and all(0xA1 <= byte <= 0xFE for byte in encoded):
            out += bytes((encoded[0] - 0x80, encoded[1] - 0x80))
        elif len(encoded) == 1 and 0x20 <= encoded[0] <= 0x7E:
            out += bytes((0x0E, encoded[0], 0x0F))  # LS1, char, LS0
        else:
            out += bytes((0x0E, 0x3F, 0x0F))  # '?'
    return bytes(out)


def make_caption_pes(
    text: str,
    pts: int,
    *,
    clear_screen: bool = True,
    data_identifier: int = 0x80,
) -> bytes:
    """Build a PES packet whose payload is a valid ARIB caption statement."""
    body = bytearray()
    if clear_screen:
        body.append(0x0C)  # CS: clear screen
    body += _euc_jp_to_arib_gl(text)

    data_unit = b"\x1f\x20" + _u24(len(body)) + bytes(body)
    content = b"\x00" + _u24(len(data_unit)) + data_unit
    # data_group_id 0x04 = caption statement, language 1, TMD 0.
    data_group = bytes((0x04, 0x00, 0x00)) + _u16(len(content)) + content
    payload = bytes((data_identifier, 0xFF, 0xF0)) + data_group

    header_data = _encode_pts(pts)
    packet_length = 3 + len(header_data) + len(payload)
    return (
        b"\x00\x00\x01\xbd"
        + _u16(packet_length)
        + bytes((0x80, 0x80, len(header_data)))
        + header_data
        + payload
    )


def _packetize_pes(pid: int, pes: bytes, continuity: int = 0) -> list[bytes]:
    packets: list[bytes] = []
    offset = 0
    while offset < len(pes):
        chunk = pes[offset:offset + 184]
        packets.append(_make_ts_packet(pid, offset == 0, chunk, continuity))
        offset += len(chunk)
        continuity = (continuity + 1) & 0x0F
    return packets


def _video_pts_by_packet(data: bytes, video_pid: int) -> list[tuple[int, int]]:
    """(packet index, PTS) for every video PES header, in stream order."""
    result: list[tuple[int, int]] = []
    for index, packet in enumerate(_iter_packets(data)):
        if _packet_pid(packet) != video_pid or not (packet[1] & 0x40):
            continue
        payload = _packet_payload(packet)
        if len(payload) < 14 or payload[0:3] != b"\x00\x00\x01":
            continue
        flags = payload[7]
        if (flags >> 6) not in (2, 3):
            continue
        result.append((index, _decode_pts(payload[9:14])))
    return result


def inject_captions(
    data: bytes,
    captions: tuple[tuple[float, str], ...] = DEFAULT_CAPTIONS,
) -> bytes:
    """Return data with the PMT rewritten and caption PES packets inserted.

    Media without a video elementary stream, or media that already carries the
    caption PID, is returned unchanged.
    """
    pmt_pid = _pat_pmt_pid(data)
    if pmt_pid is None:
        return data
    pmt = _pmt_section(data, pmt_pid)
    if pmt is None:
        return data
    if _pmt_has_caption(pmt):
        return data
    video_pid = _video_pid(data, pmt_pid)
    if video_pid is None:
        return data

    rewritten = _rewrite_pmt(data, pmt_pid, pmt)
    pts_entries = _video_pts_by_packet(rewritten, video_pid)
    if not pts_entries:
        return rewritten
    first_pts = pts_entries[0][1]
    last_index = pts_entries[-1][0]

    insertions: dict[int, list[bytes]] = {}
    for sequence, (offset_seconds, text) in enumerate(captions):
        target = (first_pts + round(offset_seconds * 90_000)) & ((1 << 33) - 1)
        insertion_index = None
        for packet_index, pts in pts_entries:
            if pts >= target:
                insertion_index = packet_index
                break
        if insertion_index is None:
            insertion_index = last_index + 1
        pes = make_caption_pes(text, target)
        insertions.setdefault(insertion_index, []).extend(
            _packetize_pes(CAPTION_PID, pes, sequence & 0x0F)
        )

    out = bytearray()
    packet_count = len(rewritten) // TS_PACKET_SIZE
    for index, packet in enumerate(_iter_packets(rewritten)):
        out += b"".join(insertions.get(index, ()))
        out += packet
    out += b"".join(insertions.get(packet_count, ()))
    return bytes(out)


# -- Test / inspection helpers ------------------------------------------------


def caption_pid_in_pmt(data: bytes) -> int | None:
    """Return the caption PID advertised by the first PMT, using the same rules
    as the Swift client (stream_type 0x06 + component tag 0x30...0x37)."""
    pmt_pid = _pat_pmt_pid(data)
    if pmt_pid is None:
        return None
    section = _pmt_section(data, pmt_pid)
    if section is None:
        return None
    section_end = 3 + (((section[1] & 0x0F) << 8) | section[2]) - 4
    program_info_length = ((section[10] & 0x0F) << 8) | section[11]
    offset = 12 + program_info_length
    while offset + 5 <= section_end:
        stream_type = section[offset]
        pid = ((section[offset + 1] & 0x1F) << 8) | section[offset + 2]
        es_info_length = ((section[offset + 3] & 0x0F) << 8) | section[offset + 4]
        cursor = offset + 5
        end = cursor + es_info_length
        while cursor + 2 <= end:
            tag = section[cursor]
            length = section[cursor + 1]
            value = section[cursor + 2:cursor + 2 + length]
            if stream_type == 0x06 and tag == 0x52 and len(value) == 1 and 0x30 <= value[0] <= 0x37:
                return pid
            cursor += 2 + length
        offset = end
    return None


def first_video_pts(data: bytes) -> int | None:
    """PTS of the first video frame, or None when the media has no video."""
    pmt_pid = _pat_pmt_pid(data)
    if pmt_pid is None:
        return None
    video_pid = _video_pid(data, pmt_pid)
    if video_pid is None:
        return None
    entries = _video_pts_by_packet(data, video_pid)
    return entries[0][1] if entries else None


def caption_pts_in_pes(data: bytes) -> list[int]:
    """PTS values of all caption PES headers, in stream order."""
    values: list[int] = []
    for payload in caption_pes_packets(data):
        if len(payload) >= 14 and payload[0:3] == b"\x00\x00\x01" and (payload[7] & 0x80):
            values.append(_decode_pts(payload[9:14]))
    return values


def caption_data_payloads(data: bytes) -> list[bytes]:
    """PES payloads (starting at data_identifier 0x80) of caption PES headers."""
    result: list[bytes] = []
    for pes in caption_pes_packets(data):
        if len(pes) < 9:
            continue
        start = 9 + pes[8]
        if start <= len(pes):
            result.append(pes[start:])
    return result


def caption_pes_packets(data: bytes) -> list[bytes]:
    """Payloads of packets carrying the caption PID (PES start packets only)."""
    return [
        _packet_payload(packet)
        for packet in _iter_packets(data)
        if _packet_pid(packet) == CAPTION_PID and (packet[1] & 0x40)
    ]
