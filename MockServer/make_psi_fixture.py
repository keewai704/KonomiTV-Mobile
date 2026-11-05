#!/usr/bin/env python3
"""BML のテスト用フィクスチャ (BML/test/fixtures/psi-archived-data.bin) を作り直す。

モックサーバーが配信する PSI/SI アーカイブデータ (psisiarc) と同じ形式・同じ
中身を、決まった時刻で 3 周期ぶん書き出す。次の性質を持つので、BML のテストは
実放送に近いデータでパーサとカルーセルのデコードを確認できる。

* 1 チャンク目に PAT / PMT (データ放送のコンポーネント入り) / SDT / DII
* 2 チャンク目に EIT[p/f] (現在・次の番組) / TOT / DDB (4066 バイトの
  DSF 転送ブロック 2 個 = 4096 バイトと 1661 バイトのセクション)
* 2 周期目以降は前のチャンクの辞書を参照する (辞書 ID 4096 以上) ので、
  辞書の再利用と辞書ウィンドウへの引き継ぎ、データサイズ
  (PID リスト + セクション) とトレーラーが正しいことを確認できる

使い方 (リポジトリのルートで):

    python3 MockServer/make_psi_fixture.py           # 書き出す
    python3 MockServer/make_psi_fixture.py --check    # 差分があれば失敗する
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import data_broadcasting_mock as dbm

#: フィクスチャのチャンネル (モックサーバーの channels.json の gr011 と同じ ID 系)
CHANNEL = {
    "id": "NID32736-SID1024",
    "display_channel_id": "gr011",
    "network_id": 32736,
    "service_id": 1024,
    "name": "テスト放送",
    "program_present": {
        "event_id": 9000,
        "title": "テスト放送 ニュース・情報",
        "description": "放送中の番組です。",
        "start_time": "2026-01-01T12:00:00+09:00",
        "duration": 3600,
    },
    "program_following": {
        "event_id": 9100,
        "title": "テスト放送 アニメ劇場",
        "description": "このあと放送予定の番組です。",
        "start_time": "2026-01-01T13:00:00+09:00",
        "duration": 1800,
    },
}

#: フィクスチャの基準時刻 (2026-01-01 12:00:00 JST)。決まったバイト列にするため固定する。
START_TIME = 1767236400.0
#: 書き出す周期数 (1 周期 = 2 チャンク)
CYCLES = 3

FIXTURE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "BML", "test", "fixtures", "psi-archived-data.bin",
)


def build_fixture() -> bytes:
    """3 周期ぶんの psisiarc を組み立てる (辞書は周期をまたいで引き継ぐ)。"""
    encoder = dbm.PSIArchiveEncoder()
    out = bytearray()
    for cycle in range(CYCLES):
        now = START_TIME + cycle
        for chunk in dbm.build_section_chunks(CHANNEL, True, now):
            out += encoder.encode(chunk, now)
    return bytes(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="書き出さずに、差分がないかだけ確認する")
    arguments = parser.parse_args()

    data = build_fixture()
    if arguments.check:
        try:
            with open(FIXTURE_PATH, "rb") as fixture:
                current = fixture.read()
        except FileNotFoundError:
            print(f"{FIXTURE_PATH} がありません。", file=sys.stderr)
            return 1
        if current != data:
            print(
                f"{FIXTURE_PATH} が古いです。python3 MockServer/make_psi_fixture.py で作り直してください。",
                file=sys.stderr,
            )
            return 1
        print(f"{FIXTURE_PATH} は最新です。({len(data)} バイト)")
        return 0

    with open(FIXTURE_PATH, "wb") as fixture:
        fixture.write(data)
    print(f"{FIXTURE_PATH} に {len(data)} バイトを書き出しました。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
