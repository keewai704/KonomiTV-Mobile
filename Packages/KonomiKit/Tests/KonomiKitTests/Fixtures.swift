import Foundation

enum Fixtures {

    static let versionJSON = """
    {
      "version": "v2.0.0",
      "latest_version": null,
      "environment": "Linux",
      "backend": "EDCB",
      "encoder": "FFmpeg"
    }
    """

    static let channelsJSON = """
    {
      "GR": [
        {
          "id": "gr011",
          "display_channel_id": "gr011",
          "network_id": 32736,
          "service_id": 1024,
          "transport_stream_id": 32736,
          "remocon_id": 1,
          "channel_number": "011",
          "type": "GR",
          "name": "NHK総合",
          "is_subchannel": false,
          "is_radiochannel": false,
          "is_watchable": true,
          "is_display": true,
          "viewer_count": 12,
          "terrestrial_regions": [{"region_id": "tokyo", "name": "東京"}],
          "unknown_key": {"nested": true},
          "program_present": {
            "id": "p1",
            "channel_id": "gr011",
            "network_id": 32736,
            "service_id": 1024,
            "event_id": 100,
            "title": "ニュース7",
            "description": "最新のニュース",
            "start_time": "2026-11-03T21:00:00+09:00",
            "end_time": "2026-11-03T21:30:00+09:00",
            "duration": 1800,
            "is_free": true,
            "genres": [{"major": "ニュース", "middle": "報道"}],
            "primary_audio_type": "2/0モード(ステレオ)",
            "primary_audio_language": "日本語",
            "extra_program_field": "ignored"
          },
          "program_following": {
            "id": "p2",
            "channel_id": "gr011",
            "title": "次の番組",
            "description": "",
            "start_time": "2026-11-03T21:30:00+09:00",
            "end_time": "2026-11-03T22:00:00+09:00",
            "duration": 1800,
            "is_free": true,
            "genres": []
          }
        },
        {
          "id": "gr021",
          "display_channel_id": "gr021",
          "network_id": 32736,
          "service_id": 1025,
          "remocon_id": 2,
          "channel_number": "021",
          "type": "GR",
          "name": "Eテレ",
          "is_subchannel": true,
          "is_radiochannel": false,
          "is_watchable": true,
          "is_display": true,
          "viewer_count": 0,
          "program_present": null,
          "program_following": null
        }
      ],
      "BS": [
        {
          "id": "bs101",
          "display_channel_id": "bs101",
          "network_id": 4,
          "service_id": 1024,
          "transport_stream_id": 16400,
          "remocon_id": 1,
          "channel_number": "101",
          "type": "BS",
          "name": "NHK BS",
          "is_subchannel": false,
          "is_radiochannel": false,
          "is_watchable": true,
          "is_display": true,
          "viewer_count": 5,
          "program_present": {
            "id": "pb1",
            "channel_id": "bs101",
            "title": "BSニュース",
            "start_time": "2026-11-03T21:00:00.123456+09:00",
            "end_time": "2026-11-03T21:30:00.123456+09:00",
            "duration": 1800,
            "is_free": true,
            "genres": [{"major": "ニュース", "middle": "報道"}]
          },
          "program_following": null
        }
      ],
      "CS": [],
      "CATV": [],
      "SKY": [],
      "BS4K": []
    }
    """

    static let recordedProgramsJSON = """
    {
      "total": 35,
      "recorded_programs": [
        {
          "id": 101,
          "title": "テスト番組",
          "description": "番組の説明",
          "start_time": "2026-11-02T20:00:00+09:00",
          "end_time": "2026-11-02T21:00:00+09:00",
          "duration": 3600,
          "is_free": true,
          "genres": [{"major": "ドラマ", "middle": "国内ドラマ"}],
          "series_title": "テストシリーズ",
          "episode_number": "第1話",
          "subtitle": "サブタイトル",
          "channel": {
            "id": "gr011",
            "display_channel_id": "gr011",
            "network_id": 32736,
            "service_id": 1024,
            "remocon_id": 1,
            "channel_number": "011",
            "type": "GR",
            "name": "NHK総合",
            "is_subchannel": false,
            "is_radiochannel": false,
            "is_watchable": true
          },
          "recorded_video": {
            "id": 101,
            "status": "Recorded",
            "duration": 3600,
            "video_resolution_width": 1920,
            "video_resolution_height": 1080,
            "video_codec": "H.264",
            "video_frame_rate": 29.97,
            "container_format": "MPEG-TS",
            "primary_audio_codec": "AAC-LC",
            "file_size": 123456789,
            "created_at": "2026-11-02T21:05:00+09:00",
            "updated_at": "2026-11-02T21:05:00+09:00"
          },
          "created_at": "2026-11-02T21:05:00+09:00",
          "updated_at": "2026-11-02T21:05:00+09:00",
          "unknown_field": 123
        },
        {
          "id": 102,
          "title": "テスト番組2",
          "description": "",
          "start_time": "2026-11-02T22:00:00+09:00",
          "end_time": "2026-11-02T22:02:00+09:00",
          "duration": 120.5,
          "channel": null,
          "recorded_video": {
            "id": 102,
            "status": "Recorded",
            "duration": 120.5
          }
        }
      ]
    }
    """

    static let recordedProgramJSON = """
    {
      "id": 101,
      "title": "テスト番組",
      "description": "番組の説明",
      "start_time": "2026-11-02T20:00:00+09:00",
      "end_time": "2026-11-02T21:00:00+09:00",
      "duration": 3600,
      "is_free": true,
      "genres": [{"major": "ドラマ", "middle": "国内ドラマ"}],
      "series_title": "テストシリーズ",
      "episode_number": "第1話",
      "subtitle": "サブタイトル",
      "channel": {
        "id": "gr011",
        "display_channel_id": "gr011",
        "network_id": 32736,
        "service_id": 1024,
        "remocon_id": 1,
        "channel_number": "011",
        "type": "GR",
        "name": "NHK総合"
      },
      "recorded_video": {
        "id": 101,
        "status": "Recorded",
        "duration": 3600,
        "video_resolution_width": 1920,
        "video_resolution_height": 1080,
        "video_codec": "H.264"
      }
    }
    """

    static let loginJSON = """
    {
      "access_token": "test-access-token",
      "token_type": "bearer"
    }
    """

    static let userJSON = """
    {
      "id": 1,
      "name": "テストユーザー",
      "is_admin": false,
      "niconico_user_id": null,
      "twitter_accounts": [],
      "created_at": "2026-01-01T00:00:00+09:00",
      "updated_at": "2026-01-01T00:00:00+09:00",
      "unknown_key": "ignored"
    }
    """

    static let emptyProgramsJSON = """
    {
      "total": 0,
      "recorded_programs": []
    }
    """
}
