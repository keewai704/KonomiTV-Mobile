"""データ放送 (BML) 用の PSI/SI アーカイブデータ (psisiarc) の生成と解析。

KonomiTV のライブ PSI/SI アーカイブデータストリーミング API は、PSI/SI の
セクションを EDCB の psisiarc 形式でまとめて流し続ける。このモジュールは
モックサーバー用に、その形式のデータを合成し (encode_psi_archived_data)、
テスト用に同じ形式を読み直す (decode_psi_archived_data)。

形式は Web クライアント側の LivePSIArchivedDataDecoder.ts (EDCB Legacy WebUI の
util.lua / script.js の移植) に合わせている:

* 32 バイトのヘッダ (マジック 0x50737363 / 0x0d0a9a0a、各リストの長さ)
* タイムリスト (4 バイト × time_list_len): 1 件目は絶対時刻 (0x80000000 | t)、
  2 件目以降は (差分, コード数 - 1)
* 辞書 (新規セクションは 4 バイト = セクション長 - 1 と PID、再利用は 2 バイト)
* セクション本体 (偶数バイト境界までパディング)
* コードリスト (辞書のインデックス + 4096)
* 4 バイト境界までのトレーラー
"""

from __future__ import annotations

import datetime
import struct
import time

# EDCB の psisiarc のマジック (リトルエンディアンで読む)
PSISIARC_MAGIC = 0x50737363
PSISIARC_MAGIC2 = 0x0D0A9A0A

# タイムリストの 1 秒あたりの単位 (クライアント側の sec 計算に合わせる)
TIME_UNITS_PER_SECOND = 11250

# データ放送のコンポーネント PID (モックが合成する PMT で使う)
DATA_COMPONENT_PID = 0x0120

# 映像と音声の PID (sample.ts と同じ)
VIDEO_PID = 0x0100
AUDIO_PID = 0x0101


# ---------------------------------------------------------------------------
# CRC-32 (MPEG-2, 非反転)
# ---------------------------------------------------------------------------

def _build_crc_table() -> list[int]:
    table = []
    for index in range(256):
        crc = index << 24
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
        table.append(crc)
    return table


_CRC_TABLE = _build_crc_table()


def crc32_mpeg(data: bytes) -> int:
    """MPEG-2 の CRC-32 (セクションの末尾に付けると全体の CRC が 0 になる)。"""
    crc = 0xFFFFFFFF
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) ^ byte) & 0xFF]
    return crc


# ---------------------------------------------------------------------------
# MJD / BCD
# ---------------------------------------------------------------------------

def mjd_bcd_time(unix_seconds: float) -> bytes:
    """UNIX 時刻を ARIB の MJD + BCD 時刻 (5 バイト) にする (JST)。"""
    jst = datetime.datetime.fromtimestamp(
        unix_seconds, datetime.timezone(datetime.timedelta(hours=9))
    )
    # MJD = ユリウス日 - 2400001
    mjd = jst.date().toordinal() + 1721425 - 2400001
    return struct.pack(">H", mjd) + bytes([
        ((jst.hour // 10) << 4) | (jst.hour % 10),
        ((jst.minute // 10) << 4) | (jst.minute % 10),
        ((jst.second // 10) << 4) | (jst.second % 10),
    ])


def bcd_duration(seconds: int) -> bytes:
    """秒数を ARIB の BCD 番組長 (3 バイト) にする。"""
    hours, remainder = divmod(max(seconds, 0), 3600)
    minutes, secs = divmod(remainder, 60)
    return bytes([
        ((hours // 10) << 4) | (hours % 10),
        ((minutes // 10) << 4) | (minutes % 10),
        ((secs // 10) << 4) | (secs % 10),
    ])


# ---------------------------------------------------------------------------
# セクション
# ---------------------------------------------------------------------------

def build_long_section(
    table_id: int,
    table_id_extension: int,
    body: bytes,
    version: int = 0,
    current_next: bool = True,
    section_number: int = 0,
    last_section_number: int = 0,
) -> bytes:
    """ロング形式 (section_syntax_indicator = 1) のセクションを組み立てる。"""
    section_length = 5 + len(body) + 4
    header = bytes([
        table_id,
        0xB0 | ((section_length >> 8) & 0x0F),
        section_length & 0xFF,
        (table_id_extension >> 8) & 0xFF,
        table_id_extension & 0xFF,
        0xC0 | ((version & 0x1F) << 1) | (1 if current_next else 0),
        section_number & 0xFF,
        last_section_number & 0xFF,
    ])
    section = header + body
    return section + struct.pack(">I", crc32_mpeg(section))


def descriptor(tag: int, payload: bytes) -> bytes:
    return bytes([tag, len(payload)]) + payload


def build_pat(service_id: int, pmt_pid: int, transport_stream_id: int = 1) -> bytes:
    """PAT。1 サービス 1 番組 (program_number == service_id)。"""
    body = struct.pack(">H", service_id & 0xFFFF)
    body += struct.pack(">H", 0xE000 | (pmt_pid & 0x1FFF))
    return build_long_section(0x00, transport_stream_id, body)


def data_component_descriptor(data_component_id: int = 0x000C) -> bytes:
    """データ符号化方式記述子 (タグ 0xFD)。

    data_component_id は地上波の BML (0x000C)。additional_data_component_info は
    データカルーセル伝送方式・エントリコンポーネント・960x540 を表す
    (STD-B24 第二分冊 2.1.4 表 2-3)。
    """
    additional = bytes([
        0x33,  # transmission_format=00, entry_point_flag=1, auto_start=1, 960x540
        0x30,  # use_xml=0, default_version_flag=0, independent=1, style_for_TV=1
        0x00, 0x03,  # BML メジャーバージョン 3 (地上波)
        0x00, 0x00,  # BML マイナーバージョン 0
        0xF8,  # data_event_id=0xF, event_section_flag=1
        0xA0,  # ondemand_retrieval=1, file_storable=0, start_priority=1
    ])
    return descriptor(0xFD, struct.pack(">H", data_component_id) + additional)


def build_pmt(
    service_id: int,
    pcr_pid: int = VIDEO_PID,
    video_pid: int = VIDEO_PID,
    audio_pid: int = AUDIO_PID,
    data_pid: int | None = None,
) -> bytes:
    """PMT。data_pid を渡すとデータ放送のコンポーネントを 1 本足す。

    Web クライアントはコンポーネントに stream identifier 記述子
    (component_tag) がないとそのストリームを無視するので、必ず付ける。
    """
    streams = b""

    video_descriptors = descriptor(0x52, bytes([0x00]))
    streams += bytes([0x02]) + struct.pack(">H", 0xE000 | (video_pid & 0x1FFF))
    streams += struct.pack(">H", 0xF000 | len(video_descriptors)) + video_descriptors

    audio_descriptors = descriptor(0x52, bytes([0x01]))
    streams += bytes([0x0F]) + struct.pack(">H", 0xE000 | (audio_pid & 0x1FFF))
    streams += struct.pack(">H", 0xF000 | len(audio_descriptors)) + audio_descriptors

    if data_pid is not None:
        data_descriptors = descriptor(0x52, bytes([0x40])) + data_component_descriptor()
        streams += bytes([0x0D]) + struct.pack(">H", 0xE000 | (data_pid & 0x1FFF))
        streams += struct.pack(">H", 0xF000 | len(data_descriptors)) + data_descriptors

    body = struct.pack(">H", 0xE000 | (pcr_pid & 0x1FFF))
    body += struct.pack(">H", 0xF000)  # program_info_length
    body += streams
    return build_long_section(0x02, service_id, body)


def arib_text(text: str) -> bytes:
    """ARIB STD-B24 の文字列 (7 ビット符号化)。

    英数だけの文字列は英数集合 (ESC ( J で G0 に指定) で、それ以外は
    漢字集合 (初期状態の G0) の 2 バイトで符号化する。日本語の文字列に
    混ざった半角英数は全角に直して漢字集合側に寄せる。
    """
    if all(ord(character) < 0x80 for character in text):
        return b"\x1b(J" + bytes(ord(character) for character in text)

    encoded = bytearray()
    for character in text:
        code = ord(character)
        if 0x21 <= code <= 0x7E:
            character = chr(code + 0xFEE0)  # 半角 → 全角
        elif code == 0x20:
            character = "\u3000"
        jis = character.encode("iso2022_jp")
        body = jis.replace(b"\x1b$B", b"").replace(b"\x1b(B", b"")
        if len(body) == 2:
            encoded.extend(body)
        else:
            encoded.extend(b"??")
    return bytes(encoded)


def build_sdt(
    service_id: int,
    original_network_id: int,
    service_name: str = "KonomiTV Mock",
    provider_name: str = "KonomiTV",
) -> bytes:
    """SDT (自局)。サービス名だけを持つ最小構成。"""
    name = arib_text(service_name)
    provider = arib_text(provider_name)
    service_descriptor = descriptor(
        0x48,
        bytes([0x01]) + bytes([len(provider)]) + provider + bytes([len(name)]) + name,
    )
    service = struct.pack(">H", service_id)
    service += bytes([0xFC])  # EIT_schedule_flag=1, EIT_present_following_flag=1
    service += struct.pack(">H", 0x8000 | len(service_descriptor)) + service_descriptor

    body = struct.pack(">H", original_network_id) + bytes([0xFF])
    body += struct.pack(">H", 0xF000 | len(service)) + service
    return build_long_section(0x42, 1, body)


def build_eit_present_following(
    service_id: int,
    original_network_id: int,
    present: dict | None = None,
    following: dict | None = None,
    transport_stream_id: int = 1,
) -> list[bytes]:
    """EIT[p/f] のセクション (Present / Following) を返す。

    present / following は {event_id, start_time(UNIX 秒), duration(秒),
    running_status, free_ca, name, text} の dict。
    """
    sections: list[bytes] = []
    for section_number, event in enumerate([present, following]):
        if event is None:
            continue
        name = arib_text(event.get("name", ""))
        text = arib_text(event.get("text", ""))
        short_event = descriptor(
            0x4D,
            b"jpn" + bytes([len(name)]) + name + bytes([len(text)]) + text,
        )
        status = int(event.get("running_status", 4)) & 0x07
        free_ca = 1 if event.get("free_ca", False) else 0

        event_body = struct.pack(">H", int(event.get("event_id", 0)))
        event_body += mjd_bcd_time(float(event["start_time"]))
        event_body += bcd_duration(int(event.get("duration", 0)))
        event_body += struct.pack(">H", (status << 13) | (free_ca << 12) | len(short_event))
        event_body += short_event

        # service_id (table_id_extension)・version・section_number はヘッダが持つ
        body = struct.pack(">H", transport_stream_id)
        body += struct.pack(">H", original_network_id)
        body += bytes([1, 0x4E])  # segment_last_section_number, last_table_id
        body += event_body
        sections.append(build_long_section(
            0x4E,  # EIT[p/f] (自局)
            service_id,
            body,
            section_number=section_number,
            last_section_number=1,
        ))
    return sections


def build_tot(unix_seconds: float) -> bytes:
    """TOT (時刻情報)。現時刻を伝える。"""
    body = mjd_bcd_time(unix_seconds) + struct.pack(">H", 0xF000)
    header = bytes([0x73, 0x70, len(body) & 0xFF])
    section = header + body
    return section + struct.pack(">I", crc32_mpeg(section))


# ---------------------------------------------------------------------------
# psisiarc
# ---------------------------------------------------------------------------

class PSIArchiveEncoder:
    """psisiarc の書庫をチャンクごとに書く。

    psisiarc (psiarchiver.cpp) と同じく、前回のチャンクの辞書にあるセクションは
    辞書 ID (4096 以上) で参照し、参照しなかった前回のエントリは辞書ウィンドウ
    に引き継ぐ。実際の放送の書庫は 2 チャンク目以降ほぼ再利用だけになる。
    """

    #: 引き継ぐ前回の辞書のエントリ数の上限
    MAX_CARRIED_ENTRIES = 32

    def __init__(self) -> None:
        # 前回のチャンクの辞書 (辞書 ID 4096 + index の順)
        self.window: list[tuple[int, bytes]] = []

    def encode(
        self,
        sections: list[tuple[int, bytes]],
        current_time_seconds: float,
    ) -> bytes:
        """(PID, セクション) のリストを 1 チャンクにする。

        辞書には重複を除いたセクションを載せ、コードリストでは渡された順に
        すべてを送出する。
        """
        if not sections:
            raise ValueError("sections must not be empty")
        for _, section in sections:
            if len(section) > 4096:
                raise ValueError("a section does not fit in one psisiarc dictionary entry")

        current: list[tuple[int, bytes]] = []
        for entry in sections:
            if entry not in current:
                current.append(entry)
        if len(current) > 64:
            raise ValueError("psisiarc supports at most 64 dictionary entries per chunk here")

        dictionary: list[int] = []
        new_entries: list[tuple[int, bytes]] = []
        referenced: set[int] = set()
        for entry in current:
            index = next(
                (i for i, old in enumerate(self.window) if old == entry and i not in referenced),
                None,
            )
            if index is None:
                dictionary.append(len(entry[1]) - 1)
                new_entries.append(entry)
            else:
                dictionary.append(4096 + index)
                referenced.add(index)
        carried = [
            old for i, old in enumerate(self.window) if i not in referenced
        ][:self.MAX_CARRIED_ENTRIES]
        window = current + carried

        # 辞書データサイズは PID リストとセクション集合のバイト数の和
        dictionary_data_size = sum(2 + len(section) for _, section in new_entries)
        dictionary_buffer_size = sum(2 + len(section) for _, section in window)
        time_list_len = 2
        code_list_len = len(sections)

        out = bytearray()
        out += struct.pack(
            "<IIHHHHIII",
            PSISIARC_MAGIC,
            PSISIARC_MAGIC2,
            0,  # 予約 (+8)
            time_list_len,
            len(dictionary),
            len(window),
            dictionary_data_size,
            dictionary_buffer_size,
            code_list_len,
        )
        out += b"\x00\x00\x00\x00"  # 予約 (32 バイトのヘッダの残り)

        # タイムリスト: 絶対時刻 + 相対エントリ (コード数 code_list_len)
        absolute = 0x80000000 | (
            int(current_time_seconds * TIME_UNITS_PER_SECOND) & 0x3FFFFFFF
        )
        out += struct.pack("<I", absolute)
        out += struct.pack("<HH", 0, code_list_len - 1)

        # 辞書: 前回の辞書 ID の参照、または セクション長 - 1
        for value in dictionary:
            out += struct.pack("<H", value)
        # PID リスト (新規のエントリのみ、0xe000 との OR)
        for pid, _ in new_entries:
            out += struct.pack("<H", 0xE000 | (pid & 0x1FFF))
        # セクション集合 (新規のエントリのみ)
        for _, section in new_entries:
            out += section
        if dictionary_data_size % 2:
            out += b"\xff"

        # 符号リスト: 辞書 ID (このチャンクの辞書のインデックス + 4096)
        for entry in sections:
            out += struct.pack("<H", 4096 + current.index(entry))

        # トレーラー: データ部分が 4 の倍数なら "====" 、それ以外は "=="
        data_size = len(out) - 32
        out += b"====" if data_size % 4 == 0 else b"=="

        self.window = window
        return bytes(out)


def encode_psi_archived_data(
    sections: list[tuple[int, bytes]],
    current_time_seconds: float,
) -> bytes:
    """(PID, セクション) のリストを、前回の辞書のない psisiarc の 1 チャンクにする。"""
    return PSIArchiveEncoder().encode(sections, current_time_seconds)


class _Context:
    def __init__(self) -> None:
        self.pids: list[int] = []
        self.sections: list[bytes | None] = []
        self.position = 0
        self.trailer_size = 0
        self.time_list_count = -1
        self.code_list_position = 0
        self.code_count = 0
        self.init_time = -1
        self.curr_time = -1


class _Incomplete(Exception):
    """チャンクが途中で切れている (続きの到着を待つ)。"""


def _read_u16(data: bytes, position: int) -> int:
    if position + 2 > len(data):
        raise _Incomplete()
    return struct.unpack_from("<H", data, position)[0]


def _read_u32(data: bytes, position: int) -> int:
    if position + 4 > len(data):
        raise _Incomplete()
    return struct.unpack_from("<I", data, position)[0]


def decode_psi_archived_data(data: bytes) -> list[tuple[float, int, bytes]]:
    """psisiarc を読み、(秒, PID, ヘッダ付き TS パケット) を返す。

    テスト用。クライアント側 (LivePSIArchivedDataDecoder.ts) と同じ手順で
    読み進め、チャンクが途中で切れている場合はそこで止める。
    """
    context = _Context()
    result: list[tuple[float, int, bytes]] = []
    packet_counters: dict[int, int] = {}

    def set_header(packets: bytearray, pid: int) -> None:
        counter = packet_counters.get(pid, 0)
        for index in range(0, len(packets), 188):
            packets[index] = 0x47
            packets[index + 1] = (0x40 if index == 0 else 0) | ((pid >> 8) & 0x1F)
            packets[index + 2] = pid & 0xFF
            packets[index + 3] = 0x10 | counter
            counter = (counter + 1) & 0x0F
        packet_counters[pid] = counter

    while len(data) - context.position >= context.trailer_size + 32:
        try:
            position = context.position + context.trailer_size
            time_list_len = _read_u16(data, position + 10)
            dictionary_len = _read_u16(data, position + 12)
            dictionary_window_len = _read_u16(data, position + 14)
            dictionary_data_size = _read_u32(data, position + 16)
            dictionary_buffer_size = _read_u32(data, position + 20)
            code_list_len = _read_u32(data, position + 24)

            if (
                _read_u32(data, position) != PSISIARC_MAGIC
                or _read_u32(data, position + 4) != PSISIARC_MAGIC2
                or dictionary_window_len < dictionary_len
                or dictionary_buffer_size < dictionary_data_size
                or dictionary_window_len > 65536 - 4096
            ):
                return result

            chunk_size = (
                32 + time_list_len * 4 + dictionary_len * 2
                + ((dictionary_data_size + 1) // 2) * 2 + code_list_len * 2
            )
            if len(data) - position < chunk_size:
                break

            time_list_position = position + 32
            position += 32 + time_list_len * 4

            if context.time_list_count < 0:
                # 辞書を読む。読み切れない場合は何も反映せずに待つ。
                # このチャンクの辞書は新しいリストに作り、4096 以上の値は
                # 前回の辞書の ID を参照する (参照したものは -1 で印を付ける)
                previous_pids = list(context.pids)
                previous_sections = context.sections
                pids: list[int] = [0] * dictionary_len
                sections: list[bytes | None] = [None] * dictionary_len
                section_list_position = 0

                for index in range(dictionary_len):
                    code_or_size = _read_u16(data, position) - 4096
                    position += 2
                    if code_or_size >= 0:
                        if (code_or_size >= len(previous_pids)
                                or previous_pids[code_or_size] < 0):
                            return result
                        pids[index] = previous_pids[code_or_size]
                        sections[index] = previous_sections[code_or_size]
                        previous_pids[code_or_size] = -1
                    else:
                        pids[index] = code_or_size
                        sections[index] = None
                        section_list_position += 2
                section_list_position += position

                for index in range(dictionary_len):
                    if pids[index] >= 0:
                        continue
                    length = pids[index] + 4097
                    if section_list_position + length > len(data):
                        raise _Incomplete()
                    section = data[section_list_position:section_list_position + length]
                    packets = bytearray(((len(section) + 1 + 183) // 184) * 188)
                    j = 0
                    k = 0
                    while k < len(section):
                        if j % 188 == 0:
                            j += 4
                            if k == 0:
                                packets[j] = 0
                                j += 1
                        packets[j] = section[k]
                        j += 1
                        k += 1
                    sections[index] = bytes(packets)
                    section_list_position += length
                    pids[index] = _read_u16(data, position) & 0x1FFF
                    position += 2

                # 辞書ウィンドウの残りは、前回の辞書の未参照のエントリを順に引き継ぐ
                previous = 0
                while len(pids) < dictionary_window_len:
                    if previous >= len(previous_pids):
                        return result
                    if previous_pids[previous] >= 0:
                        pids.append(previous_pids[previous])
                        sections.append(previous_sections[previous])
                    previous += 1

                context.pids = pids
                context.sections = sections
                context.time_list_count = 0
                position = section_list_position + dictionary_data_size % 2
            else:
                position += dictionary_len * 2 + ((dictionary_data_size + 1) // 2) * 2

            # コードリストまで届いていなければ、このチャンクはまだ処理しない
            if position + code_list_len * 2 > len(data):
                raise _Incomplete()

            position += context.code_list_position
            time_list_position += context.time_list_count * 4
            while context.time_list_count < time_list_len:
                abs_time = _read_u32(data, time_list_position)
                if abs_time == 0xFFFFFFFF:
                    context.curr_time = -1
                elif abs_time >= 0x80000000:
                    context.curr_time = abs_time & 0x3FFFFFFF
                    if context.init_time < 0:
                        context.init_time = context.curr_time
                else:
                    code_count = _read_u16(data, time_list_position + 2) + 1
                    if context.curr_time >= 0:
                        context.curr_time += _read_u16(data, time_list_position)
                        second = (
                            (context.curr_time + 0x40000000 - context.init_time) & 0x3FFFFFFF
                        ) / TIME_UNITS_PER_SECOND
                        while context.code_count < code_count:
                            code = _read_u16(data, position) - 4096
                            packets = bytearray(context.sections[code] or b"")
                            pid = context.pids[code]
                            set_header(packets, pid)
                            result.append((second, pid, bytes(packets)))
                            context.code_count += 1
                            position += 2
                            context.code_list_position += 2
                        context.code_count = 0
                    else:
                        position += code_count * 2
                        context.code_list_position += code_count * 2
                context.time_list_count += 1
                time_list_position += 4

            context.position = position
            context.trailer_size = 2 + (2 + chunk_size) % 4
            context.time_list_count = -1
            context.code_list_position = 0
            context.curr_time = -1
        except _Incomplete:
            # 続きが届いたらチャンクの先頭から読み直す
            break

    return result


# ---------------------------------------------------------------------------
# ライブ PSI/SI アーカイブデータストリーム (モック)
# ---------------------------------------------------------------------------

# チャンクを送出する間隔 (秒)。実際のサーバーは数秒おきにチャンクを流す。
PSI_ARCHIVED_DATA_INTERVAL = 0.5


def _event_from_program(program: dict | None, default_event_id: int) -> dict | None:
    """チャンネルの現在/次の番組 (channels fixture) を EIT のイベントにする。"""
    if not program:
        return None
    try:
        start_time = datetime.datetime.fromisoformat(program["start_time"]).timestamp()
    except (KeyError, TypeError, ValueError):
        start_time = time.time()
    return {
        "event_id": int(program.get("event_id") or default_event_id),
        "start_time": start_time,
        "duration": int(program.get("duration") or 3600),
        "running_status": 4,
        "name": str(program.get("title") or ""),
        "text": str(program.get("description") or ""),
    }


def build_sections(
    channel: dict,
    include_data_component: bool,
    current_time: float | None = None,
) -> list[tuple[int, bytes]]:
    """1 周期ぶんのセクション (PAT / PMT / SDT / EIT[p/f] / TOT)。"""
    now = time.time() if current_time is None else current_time
    service_id = int(channel.get("service_id") or 1024)
    network_id = int(channel.get("network_id") or 0)
    present = _event_from_program(channel.get("program_present"), 100)
    following = _event_from_program(channel.get("program_following"), 101)

    sections: list[tuple[int, bytes]] = [
        (0x0000, build_pat(service_id, 0x1000)),
        (0x1000, build_pmt(
            service_id,
            data_pid=DATA_COMPONENT_PID if include_data_component else None,
        )),
        (0x0011, build_sdt(
            service_id,
            network_id,
            service_name=str(channel.get("name") or "KonomiTV Mock"),
        )),
    ]
    for section in build_eit_present_following(
        service_id,
        network_id,
        present=present,
        following=following,
    ):
        sections.append((0x0012, section))
    sections.append((0x0014, build_tot(now)))
    return sections


def iter_psi_archived_data(
    channel: dict,
    include_data_component: bool,
    interval: float = PSI_ARCHIVED_DATA_INTERVAL,
):
    """ライブ PSI/SI アーカイブデータストリーム (エンドレス) を生成する。"""
    # 1 本のストリームでは辞書を引き継ぐ (毎回同じ PAT / PMT / SDT は 2 回目
    # から前回の辞書 ID の参照になる)
    encoder = PSIArchiveEncoder()
    while True:
        now = time.time()
        sections = build_sections(channel, include_data_component, now)
        # 1 チャンクに PAT/PMT/SDT を、続くチャンクに EIT[p/f] と TOT を入れる
        # (クライアント側は複数チャンクの連結をそのまま読める)
        yield encoder.encode(sections[:3], now)
        yield encoder.encode(sections[3:], now)
        time.sleep(interval)


def iter_sections(data: bytes) -> list[tuple[int, bytes]]:
    """psisiarc から (PID, セクション) を取り出す (テスト・検証用)。"""
    sections: list[tuple[int, bytes]] = []
    for _, pid, packets in decode_psi_archived_data(data):
        payload = bytearray()
        for offset in range(0, len(packets), 188):
            payload += packets[offset + 4:offset + 188]
        if not payload:
            continue
        pointer = payload[0]
        section = bytes(payload[1 + pointer:])
        if len(section) < 3:
            continue
        section_length = ((section[1] & 0x0F) << 8) | section[2]
        # ショート形式のセクション (TOT など) は CRC が section_length に含まれない
        checksum = 0 if section[1] & 0x80 else 4
        sections.append((pid, section[:3 + section_length + checksum]))
    return sections
