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

    static let seriesListJSON = """
    {
      "total": 3,
      "series_list": [
        {
          "id": 1,
          "title": "アニメ 鬼滅の刃",
          "description": "大正時代を舞台に、家族を鬼にされた少年が鬼狩りの道を歩むアニメシリーズ。",
          "genres": [
            {
              "major": "アニメ・特撮",
              "middle": "国内アニメ"
            }
          ],
          "broadcast_periods": [
            {
              "channel": {
                "id": "NID32737-SID1024",
                "display_channel_id": "gr021",
                "network_id": 32737,
                "service_id": 1024,
                "transport_stream_id": 32737,
                "remocon_id": 2,
                "channel_number": "2",
                "type": "GR",
                "name": "NHK Eテレ",
                "terrestrial_regions": [
                  "関東広域圏"
                ],
                "jikkyo_force": null,
                "is_subchannel": false,
                "is_radiochannel": false,
                "is_watchable": true,
                "is_display": true,
                "viewer_count": 0,
                "program_present": null,
                "program_following": null
              },
              "start_date": "2026-10-06",
              "end_date": "2026-12-29",
              "recorded_programs": [
                {
                  "id": 4,
                  "recorded_video": {
                    "id": 4,
                    "status": "Recorded",
                    "file_path": "/recorded/gr021/program4.m2ts",
                    "file_hash": "mockhash0004",
                    "file_size": 1000004000,
                    "file_created_at": "2026-10-31T21:31:00+09:00",
                    "file_modified_at": "2026-10-31T21:31:00+09:00",
                    "recording_start_time": "2026-10-31T20:00:00+09:00",
                    "recording_end_time": "2026-10-31T21:30:00+09:00",
                    "duration": 5400.0,
                    "container_format": "MPEG-TS",
                    "video_codec": "H.264",
                    "video_codec_profile": "Main",
                    "video_scan_type": "Progressive",
                    "video_frame_rate": 29.97,
                    "video_resolution_width": 1440,
                    "video_resolution_height": 1080,
                    "has_video_stream_changes": false,
                    "primary_audio_codec": "AAC-LC",
                    "primary_audio_channel": "Stereo",
                    "primary_audio_sampling_rate": 48000,
                    "secondary_audio_codec": null,
                    "secondary_audio_channel": null,
                    "secondary_audio_sampling_rate": null,
                    "cm_sections": [],
                    "thumbnail_info": null,
                    "created_at": "2026-10-31T21:32:00+09:00",
                    "updated_at": "2026-10-31T21:32:00+09:00"
                  },
                  "recording_start_margin": 0.0,
                  "recording_end_margin": 0.0,
                  "is_partially_recorded": false,
                  "channel": {
                    "id": "NID32737-SID1024",
                    "display_channel_id": "gr021",
                    "network_id": 32737,
                    "service_id": 1024,
                    "transport_stream_id": 32737,
                    "remocon_id": 2,
                    "channel_number": "2",
                    "type": "GR",
                    "name": "NHK Eテレ",
                    "terrestrial_regions": [
                      "関東広域圏"
                    ],
                    "jikkyo_force": null,
                    "is_subchannel": false,
                    "is_radiochannel": false,
                    "is_watchable": true,
                    "is_display": true,
                    "viewer_count": 0,
                    "program_present": null,
                    "program_following": null
                  },
                  "network_id": 32737,
                  "service_id": 1024,
                  "event_id": 10004,
                  "series_id": 1,
                  "series_broadcast_period_id": 0,
                  "title": "アニメ 鬼滅の刃",
                  "series_title": "アニメ 鬼滅の刃",
                  "episode_number": "第1話",
                  "subtitle": "アニメ 鬼滅の刃",
                  "description": "人気アニメの第1話。",
                  "detail": {},
                  "start_time": "2026-10-31T20:00:00+09:00",
                  "end_time": "2026-10-31T21:30:00+09:00",
                  "duration": 5400.0,
                  "is_free": true,
                  "genres": [
                    {
                      "major": "スポーツ",
                      "middle": "野球"
                    }
                  ],
                  "primary_audio_type": "2/0モード(ステレオ)",
                  "primary_audio_language": "日本語",
                  "secondary_audio_type": null,
                  "secondary_audio_language": null,
                  "created_at": "2026-10-31T21:32:00+09:00",
                  "updated_at": "2026-10-31T21:32:00+09:00"
                }
              ]
            }
          ],
          "created_at": "2026-10-06T22:00:00+09:00",
          "updated_at": "2026-11-01T23:00:00+09:00"
        },
        {
          "id": 2,
          "title": "アニメ 葬送のフリーレン",
          "description": "魔王討伐を果たした魔法使いフリーレンが、勇者たちとの旅を振り返るファンタジーアニメ。",
          "genres": [
            {
              "major": "アニメ・特撮",
              "middle": "国内アニメ"
            }
          ],
          "broadcast_periods": [
            {
              "channel": {
                "id": "NID32736-SID1024",
                "display_channel_id": "gr011",
                "network_id": 32736,
                "service_id": 1024,
                "transport_stream_id": 32736,
                "remocon_id": 1,
                "channel_number": "1",
                "type": "GR",
                "name": "NHK総合",
                "terrestrial_regions": [
                  "関東広域圏"
                ],
                "jikkyo_force": null,
                "is_subchannel": false,
                "is_radiochannel": false,
                "is_watchable": true,
                "is_display": true,
                "viewer_count": 0,
                "program_present": null,
                "program_following": null
              },
              "start_date": "2026-10-02",
              "end_date": "2026-12-25",
              "recorded_programs": [
                {
                  "id": 5,
                  "recorded_video": {
                    "id": 5,
                    "status": "Recorded",
                    "file_path": "/recorded/gr011/program5.m2ts",
                    "file_hash": "mockhash0005",
                    "file_size": 1000005000,
                    "file_created_at": "2026-10-30T20:31:00+09:00",
                    "file_modified_at": "2026-10-30T20:31:00+09:00",
                    "recording_start_time": "2026-10-30T20:00:00+09:00",
                    "recording_end_time": "2026-10-30T20:30:00+09:00",
                    "duration": 1800.0,
                    "container_format": "MPEG-TS",
                    "video_codec": "H.264",
                    "video_codec_profile": "Main",
                    "video_scan_type": "Progressive",
                    "video_frame_rate": 29.97,
                    "video_resolution_width": 1440,
                    "video_resolution_height": 1080,
                    "has_video_stream_changes": false,
                    "primary_audio_codec": "AAC-LC",
                    "primary_audio_channel": "Stereo",
                    "primary_audio_sampling_rate": 48000,
                    "secondary_audio_codec": null,
                    "secondary_audio_channel": null,
                    "secondary_audio_sampling_rate": null,
                    "cm_sections": [],
                    "thumbnail_info": null,
                    "created_at": "2026-10-30T20:32:00+09:00",
                    "updated_at": "2026-10-30T20:32:00+09:00"
                  },
                  "recording_start_margin": 0.0,
                  "recording_end_margin": 0.0,
                  "is_partially_recorded": false,
                  "channel": {
                    "id": "NID32736-SID1024",
                    "display_channel_id": "gr011",
                    "network_id": 32736,
                    "service_id": 1024,
                    "transport_stream_id": 32736,
                    "remocon_id": 1,
                    "channel_number": "1",
                    "type": "GR",
                    "name": "NHK総合",
                    "terrestrial_regions": [
                      "関東広域圏"
                    ],
                    "jikkyo_force": null,
                    "is_subchannel": false,
                    "is_radiochannel": false,
                    "is_watchable": true,
                    "is_display": true,
                    "viewer_count": 0,
                    "program_present": null,
                    "program_following": null
                  },
                  "network_id": 32736,
                  "service_id": 1024,
                  "event_id": 10005,
                  "series_id": 2,
                  "series_broadcast_period_id": 0,
                  "title": "アニメ 葬送のフリーレン",
                  "series_title": "アニメ 葬送のフリーレン",
                  "episode_number": "第1話",
                  "subtitle": "アニメ 葬送のフリーレン",
                  "description": "魔王討伐後の旅を描くアニメ。",
                  "detail": {},
                  "start_time": "2026-10-30T20:00:00+09:00",
                  "end_time": "2026-10-30T20:30:00+09:00",
                  "duration": 1800.0,
                  "is_free": true,
                  "genres": [
                    {
                      "major": "映画",
                      "middle": "洋画"
                    }
                  ],
                  "primary_audio_type": "2/0モード(ステレオ)",
                  "primary_audio_language": "日本語",
                  "secondary_audio_type": null,
                  "secondary_audio_language": null,
                  "created_at": "2026-10-30T20:32:00+09:00",
                  "updated_at": "2026-10-30T20:32:00+09:00"
                }
              ]
            }
          ],
          "created_at": "2026-10-01T23:00:00+09:00",
          "updated_at": "2026-10-30T23:00:00+09:00"
        },
        {
          "id": 3,
          "title": "朝の連続ドラマ",
          "description": "毎朝放送される連続テレビドラマ。家族の日常を丁寧に描く。",
          "genres": [
            {
              "major": "ドラマ",
              "middle": "国内ドラマ"
            }
          ],
          "broadcast_periods": [
            {
              "channel": {
                "id": "NID16384-SID1024",
                "display_channel_id": "bs101",
                "network_id": 16384,
                "service_id": 1024,
                "transport_stream_id": 16384,
                "remocon_id": 1,
                "channel_number": "BS1",
                "type": "BS",
                "name": "NHK BS",
                "terrestrial_regions": null,
                "jikkyo_force": null,
                "is_subchannel": false,
                "is_radiochannel": false,
                "is_watchable": true,
                "is_display": true,
                "viewer_count": 0,
                "program_present": null,
                "program_following": null
              },
              "start_date": "2026-09-29",
              "end_date": "2026-12-28",
              "recorded_programs": [
                {
                  "id": 7,
                  "recorded_video": {
                    "id": 7,
                    "status": "Recorded",
                    "file_path": "/recorded/bs101/program7.m2ts",
                    "file_hash": "mockhash0007",
                    "file_size": 1000007000,
                    "file_created_at": "2026-10-28T21:01:00+09:00",
                    "file_modified_at": "2026-10-28T21:01:00+09:00",
                    "recording_start_time": "2026-10-28T20:00:00+09:00",
                    "recording_end_time": "2026-10-28T21:00:00+09:00",
                    "duration": 3600.0,
                    "container_format": "MPEG-TS",
                    "video_codec": "H.264",
                    "video_codec_profile": "Main",
                    "video_scan_type": "Progressive",
                    "video_frame_rate": 29.97,
                    "video_resolution_width": 1440,
                    "video_resolution_height": 1080,
                    "has_video_stream_changes": false,
                    "primary_audio_codec": "AAC-LC",
                    "primary_audio_channel": "Stereo",
                    "primary_audio_sampling_rate": 48000,
                    "secondary_audio_codec": null,
                    "secondary_audio_channel": null,
                    "secondary_audio_sampling_rate": null,
                    "cm_sections": [],
                    "thumbnail_info": null,
                    "created_at": "2026-10-28T21:02:00+09:00",
                    "updated_at": "2026-10-28T21:02:00+09:00"
                  },
                  "recording_start_margin": 0.0,
                  "recording_end_margin": 0.0,
                  "is_partially_recorded": false,
                  "channel": {
                    "id": "NID16384-SID1024",
                    "display_channel_id": "bs101",
                    "network_id": 16384,
                    "service_id": 1024,
                    "transport_stream_id": 16384,
                    "remocon_id": 1,
                    "channel_number": "BS1",
                    "type": "BS",
                    "name": "NHK BS",
                    "terrestrial_regions": null,
                    "jikkyo_force": null,
                    "is_subchannel": false,
                    "is_radiochannel": false,
                    "is_watchable": true,
                    "is_display": true,
                    "viewer_count": 0,
                    "program_present": null,
                    "program_following": null
                  },
                  "network_id": 16384,
                  "service_id": 1024,
                  "event_id": 10007,
                  "series_id": 3,
                  "series_broadcast_period_id": 0,
                  "title": "朝の連続ドラマ",
                  "series_title": "朝の連続ドラマ",
                  "episode_number": "第1話",
                  "subtitle": "朝の連続ドラマ",
                  "description": "主人公が新しい街で成長する物語。",
                  "detail": {},
                  "start_time": "2026-10-28T20:00:00+09:00",
                  "end_time": "2026-10-28T21:00:00+09:00",
                  "duration": 3600.0,
                  "is_free": true,
                  "genres": [
                    {
                      "major": "アニメ／特撮",
                      "middle": "国内アニメ"
                    }
                  ],
                  "primary_audio_type": "2/0モード(ステレオ)",
                  "primary_audio_language": "日本語",
                  "secondary_audio_type": null,
                  "secondary_audio_language": null,
                  "created_at": "2026-10-28T21:02:00+09:00",
                  "updated_at": "2026-10-28T21:02:00+09:00"
                }
              ]
            }
          ],
          "created_at": "2026-09-29T08:00:00+09:00",
          "updated_at": "2026-10-28T08:00:00+09:00"
        }
      ]
    }
    """

    static let seriesDetailJSON = """
    {
      "id": 1,
      "title": "アニメ 鬼滅の刃",
      "description": "大正時代を舞台に、家族を鬼にされた少年が鬼狩りの道を歩むアニメシリーズ。",
      "genres": [
        {
          "major": "アニメ・特撮",
          "middle": "国内アニメ"
        }
      ],
      "broadcast_periods": [
        {
          "channel": {
            "id": "NID32737-SID1024",
            "display_channel_id": "gr021",
            "network_id": 32737,
            "service_id": 1024,
            "transport_stream_id": 32737,
            "remocon_id": 2,
            "channel_number": "2",
            "type": "GR",
            "name": "NHK Eテレ",
            "terrestrial_regions": [
              "関東広域圏"
            ],
            "jikkyo_force": null,
            "is_subchannel": false,
            "is_radiochannel": false,
            "is_watchable": true,
            "is_display": true,
            "viewer_count": 0,
            "program_present": null,
            "program_following": null
          },
          "start_date": "2026-10-06",
          "end_date": "2026-12-29",
          "recorded_programs": [
            {
              "id": 4,
              "recorded_video": {
                "id": 4,
                "status": "Recorded",
                "file_path": "/recorded/gr021/program4.m2ts",
                "file_hash": "mockhash0004",
                "file_size": 1000004000,
                "file_created_at": "2026-10-31T21:31:00+09:00",
                "file_modified_at": "2026-10-31T21:31:00+09:00",
                "recording_start_time": "2026-10-31T20:00:00+09:00",
                "recording_end_time": "2026-10-31T21:30:00+09:00",
                "duration": 5400.0,
                "container_format": "MPEG-TS",
                "video_codec": "H.264",
                "video_codec_profile": "Main",
                "video_scan_type": "Progressive",
                "video_frame_rate": 29.97,
                "video_resolution_width": 1440,
                "video_resolution_height": 1080,
                "has_video_stream_changes": false,
                "primary_audio_codec": "AAC-LC",
                "primary_audio_channel": "Stereo",
                "primary_audio_sampling_rate": 48000,
                "secondary_audio_codec": null,
                "secondary_audio_channel": null,
                "secondary_audio_sampling_rate": null,
                "cm_sections": [],
                "thumbnail_info": null,
                "created_at": "2026-10-31T21:32:00+09:00",
                "updated_at": "2026-10-31T21:32:00+09:00"
              },
              "recording_start_margin": 0.0,
              "recording_end_margin": 0.0,
              "is_partially_recorded": false,
              "channel": {
                "id": "NID32737-SID1024",
                "display_channel_id": "gr021",
                "network_id": 32737,
                "service_id": 1024,
                "transport_stream_id": 32737,
                "remocon_id": 2,
                "channel_number": "2",
                "type": "GR",
                "name": "NHK Eテレ",
                "terrestrial_regions": [
                  "関東広域圏"
                ],
                "jikkyo_force": null,
                "is_subchannel": false,
                "is_radiochannel": false,
                "is_watchable": true,
                "is_display": true,
                "viewer_count": 0,
                "program_present": null,
                "program_following": null
              },
              "network_id": 32737,
              "service_id": 1024,
              "event_id": 10004,
              "series_id": 1,
              "series_broadcast_period_id": 0,
              "title": "アニメ 鬼滅の刃",
              "series_title": "アニメ 鬼滅の刃",
              "episode_number": "第1話",
              "subtitle": "アニメ 鬼滅の刃",
              "description": "人気アニメの第1話。",
              "detail": {},
              "start_time": "2026-10-31T20:00:00+09:00",
              "end_time": "2026-10-31T21:30:00+09:00",
              "duration": 5400.0,
              "is_free": true,
              "genres": [
                {
                  "major": "スポーツ",
                  "middle": "野球"
                }
              ],
              "primary_audio_type": "2/0モード(ステレオ)",
              "primary_audio_language": "日本語",
              "secondary_audio_type": null,
              "secondary_audio_language": null,
              "created_at": "2026-10-31T21:32:00+09:00",
              "updated_at": "2026-10-31T21:32:00+09:00"
            }
          ]
        }
      ],
      "created_at": "2026-10-06T22:00:00+09:00",
      "updated_at": "2026-11-01T23:00:00+09:00"
    }
    """

    static let programsJSON = """
    {
      "total": 7,
      "programs": [
        {
          "id": "NID16384-SID1024-EID20410",
          "channel_id": "NID16384-SID1024",
          "network_id": 16384,
          "service_id": 1024,
          "event_id": 20410,
          "title": "NHK BS ショッピング・通販",
          "description": "今日のおすすめ商品を紹介します。",
          "detail": {},
          "start_time": "2026-11-04T10:00:00+09:00",
          "end_time": "2026-11-04T11:00:00+09:00",
          "duration": 3600.0,
          "is_free": true,
          "genres": [
            {
              "major": "情報・ワイドショー",
              "middle": "ショッピング・通販"
            }
          ],
          "video_type": null,
          "video_codec": "H.264",
          "video_resolution": "1080p",
          "primary_audio_type": "2/0モード(ステレオ)",
          "primary_audio_language": "日本語",
          "primary_audio_sampling_rate": "48kHz",
          "secondary_audio_type": null,
          "secondary_audio_language": null,
          "secondary_audio_sampling_rate": null
        },
        {
          "id": "NID16386-SID1024-EID20510",
          "channel_id": "NID16386-SID1024",
          "network_id": 16386,
          "service_id": 1024,
          "event_id": 20510,
          "title": "NHK BSプレミアム4K ショッピング・通販",
          "description": "今日のおすすめ商品を紹介します。",
          "detail": {},
          "start_time": "2026-11-04T10:00:00+09:00",
          "end_time": "2026-11-04T11:00:00+09:00",
          "duration": 3600.0,
          "is_free": true,
          "genres": [
            {
              "major": "情報・ワイドショー",
              "middle": "ショッピング・通販"
            }
          ],
          "video_type": null,
          "video_codec": "H.264",
          "video_resolution": "1080p",
          "primary_audio_type": "2/0モード(ステレオ)",
          "primary_audio_language": "日本語",
          "primary_audio_sampling_rate": "48kHz",
          "secondary_audio_type": null,
          "secondary_audio_language": null,
          "secondary_audio_sampling_rate": null
        }
      ]
    }
    """

    static let timetableJSON = """
    {
      "channels": [
        {
          "channel": {
            "id": "NID32736-SID1024",
            "display_channel_id": "gr011",
            "network_id": 32736,
            "service_id": 1024,
            "transport_stream_id": 32736,
            "remocon_id": 1,
            "channel_number": "1",
            "type": "GR",
            "name": "NHK総合",
            "terrestrial_regions": [
              "関東広域圏"
            ],
            "jikkyo_force": null,
            "is_subchannel": false,
            "is_radiochannel": false,
            "is_watchable": true,
            "is_display": true,
            "viewer_count": 0,
            "program_present": null,
            "program_following": null
          },
          "programs": [
            {
              "id": "NID32736-SID1024-EID20000",
              "channel_id": "NID32736-SID1024",
              "network_id": 32736,
              "service_id": 1024,
              "event_id": 20000,
              "title": "NHK総合 モーニングニュース",
              "description": "今日のニュースと天気をお伝えします。",
              "detail": {},
              "start_time": "2026-11-03T00:00:00+09:00",
              "end_time": "2026-11-03T01:00:00+09:00",
              "duration": 3600.0,
              "is_free": true,
              "genres": [
                {
                  "major": "ニュース・報道",
                  "middle": "定時・総合"
                }
              ],
              "video_type": null,
              "video_codec": "H.264",
              "video_resolution": "1080p",
              "primary_audio_type": "2/0モード(ステレオ)",
              "primary_audio_language": "日本語",
              "primary_audio_sampling_rate": "48kHz",
              "secondary_audio_type": null,
              "secondary_audio_language": null,
              "secondary_audio_sampling_rate": null,
              "reservation": {
                "id": 42,
                "status": "Reserved",
                "recording_availability": "Full"
              }
            },
            {
              "id": "NID32736-SID1024-EID20001",
              "channel_id": "NID32736-SID1024",
              "network_id": 32736,
              "service_id": 1024,
              "event_id": 20001,
              "title": "NHK総合 朝の情報ワイド",
              "description": "暮らしに役立つ情報をお届けします。",
              "detail": {},
              "start_time": "2026-11-03T01:00:00+09:00",
              "end_time": "2026-11-03T02:00:00+09:00",
              "duration": 3600.0,
              "is_free": true,
              "genres": [
                {
                  "major": "情報・ワイドショー",
                  "middle": "芸能・ワイドショー"
                }
              ],
              "video_type": null,
              "video_codec": "H.264",
              "video_resolution": "1080p",
              "primary_audio_type": "2/0モード(ステレオ)",
              "primary_audio_language": "日本語",
              "primary_audio_sampling_rate": "48kHz",
              "secondary_audio_type": null,
              "secondary_audio_language": null,
              "secondary_audio_sampling_rate": null,
              "reservation": null
            },
            {
              "id": "NID32736-SID1024-EID20002",
              "channel_id": "NID32736-SID1024",
              "network_id": 32736,
              "service_id": 1024,
              "event_id": 20002,
              "title": "NHK総合 アニメ劇場",
              "description": "人気アニメを毎日放送中。",
              "detail": {},
              "start_time": "2026-11-03T02:00:00+09:00",
              "end_time": "2026-11-03T03:00:00+09:00",
              "duration": 3600.0,
              "is_free": true,
              "genres": [
                {
                  "major": "アニメ・特撮",
                  "middle": "国内アニメ"
                }
              ],
              "video_type": null,
              "video_codec": "H.264",
              "video_resolution": "1080p",
              "primary_audio_type": "2/0モード(ステレオ)",
              "primary_audio_language": "日本語",
              "primary_audio_sampling_rate": "48kHz",
              "secondary_audio_type": null,
              "secondary_audio_language": null,
              "secondary_audio_sampling_rate": null,
              "reservation": null
            }
          ],
          "subchannels": null
        }
      ],
      "date_range": {
        "earliest": "2026-11-03T00:00:00+09:00",
        "latest": "2026-11-04T00:00:00+09:00"
      }
    }
    """

    static let clientSettingsJSON = """
    {
      "last_synced_at": 1762174800.25,
      "saved_twitter_hashtags": [],
      "mylist": [
        {
          "type": "Series",
          "id": 1,
          "created_at": 1762174800
        },
        {
          "type": "RecordedProgram",
          "id": 4,
          "created_at": 1762174900
        }
      ],
      "watched_history": [
        {
          "video_id": 4,
          "last_playback_position": 123.5,
          "created_at": 1762174800,
          "updated_at": 1762175100
        }
      ],
      "pinned_channel_ids": [
        "gr011",
        "bs101"
      ],
      "timetable_channel_width": "Normal",
      "timetable_hour_height": "Normal",
      "timetable_hover_expand": false,
      "timetable_dim_shopping_programs": true,
      "timetable_genre_colors": {
        "ニュース・報道": "White",
        "情報・ワイドショー": "White",
        "ドキュメンタリー・教養": "Blue",
        "スポーツ": "Cyan",
        "ドラマ": "Pink",
        "アニメ・特撮": "Yellow",
        "バラエティ": "Lime",
        "音楽": "Orange",
        "映画": "Brown",
        "劇場・公演": "Ochre",
        "趣味・教育": "Teal",
        "福祉": "White",
        "その他": "White"
      },
      "show_player_background_image": true,
      "use_pure_black_player_background": false,
      "tv_channel_sort_by_jikkyo_force": false,
      "tv_channel_up_down_buttons_reverse": false,
      "tv_channel_selection_requires_alt_key": false,
      "use_28hour_clock": false,
      "show_original_broadcast_time_during_playback": false,
      "panel_display_state": "RestorePreviousState",
      "tv_panel_active_tab": "Program",
      "video_panel_active_tab": "RecordedProgram",
      "video_watched_history_max_count": 50,
      "caption_font": "Windows TV MaruGothic",
      "always_border_caption_text": true,
      "specify_caption_opacity": false,
      "caption_opacity": 0.5,
      "tv_show_superimpose": true,
      "video_show_superimpose": false,
      "capture_save_mode": "UploadServer",
      "capture_caption_mode": "Both",
      "capture_filename_pattern": "Capture_%date%-%time%",
      "prefer_posting_to_nicolive": true,
      "comment_speed_rate": 1,
      "comment_font_size": 34,
      "close_comment_form_after_sending": true,
      "mute_vulgar_comments": true,
      "mute_abusive_discriminatory_prejudiced_comments": true,
      "mute_big_size_comments": true,
      "mute_fixed_comments": false,
      "mute_colored_comments": false,
      "mute_consecutive_same_characters_comments": false,
      "mute_comment_keywords_normalize_alphanumeric_width_case": true,
      "muted_comment_keywords": [],
      "muted_niconico_user_ids": [],
      "fold_panel_after_sending_tweet": false,
      "reset_hashtag_when_program_switches": true,
      "auto_add_watching_channel_hashtag": true,
      "twitter_reply_thread_mode": "PerHashtag",
      "bluesky_reply_thread_mode": "Disabled",
      "twitter_active_tab": "Capture",
      "tweet_hashtag_position": "Append",
      "tweet_capture_watermark_position": "None",
      "unknown_future_key": {
        "nested": [
          1,
          "two",
          true,
          null
        ],
        "flag": false
      }
    }
    """

    static let recordedProgramSeriesJSON = """
    {
      "id": 4,
      "recorded_video": {
        "id": 4,
        "status": "Recorded",
        "file_path": "/recorded/gr021/program4.m2ts",
        "file_hash": "mockhash0004",
        "file_size": 1000004000,
        "file_created_at": "2026-10-31T21:31:00+09:00",
        "file_modified_at": "2026-10-31T21:31:00+09:00",
        "recording_start_time": "2026-10-31T20:00:00+09:00",
        "recording_end_time": "2026-10-31T21:30:00+09:00",
        "duration": 5400.0,
        "container_format": "MPEG-TS",
        "video_codec": "H.264",
        "video_codec_profile": "Main",
        "video_scan_type": "Progressive",
        "video_frame_rate": 29.97,
        "video_resolution_width": 1440,
        "video_resolution_height": 1080,
        "has_video_stream_changes": false,
        "primary_audio_codec": "AAC-LC",
        "primary_audio_channel": "Stereo",
        "primary_audio_sampling_rate": 48000,
        "secondary_audio_codec": null,
        "secondary_audio_channel": null,
        "secondary_audio_sampling_rate": null,
        "cm_sections": [],
        "thumbnail_info": null,
        "created_at": "2026-10-31T21:32:00+09:00",
        "updated_at": "2026-10-31T21:32:00+09:00"
      },
      "recording_start_margin": 0.0,
      "recording_end_margin": 0.0,
      "is_partially_recorded": false,
      "channel": {
        "id": "NID32737-SID1024",
        "display_channel_id": "gr021",
        "network_id": 32737,
        "service_id": 1024,
        "transport_stream_id": 32737,
        "remocon_id": 2,
        "channel_number": "2",
        "type": "GR",
        "name": "NHK Eテレ",
        "terrestrial_regions": [
          "関東広域圏"
        ],
        "jikkyo_force": null,
        "is_subchannel": false,
        "is_radiochannel": false,
        "is_watchable": true,
        "is_display": true,
        "viewer_count": 0,
        "program_present": null,
        "program_following": null
      },
      "network_id": 32737,
      "service_id": 1024,
      "event_id": 10004,
      "series_id": 1,
      "series_broadcast_period_id": 0,
      "title": "アニメ 鬼滅の刃",
      "series_title": "アニメ 鬼滅の刃",
      "episode_number": "第1話",
      "subtitle": "アニメ 鬼滅の刃",
      "description": "人気アニメの第1話。",
      "detail": {},
      "start_time": "2026-10-31T20:00:00+09:00",
      "end_time": "2026-10-31T21:30:00+09:00",
      "duration": 5400.0,
      "is_free": true,
      "genres": [
        {
          "major": "スポーツ",
          "middle": "野球"
        }
      ],
      "primary_audio_type": "2/0モード(ステレオ)",
      "primary_audio_language": "日本語",
      "secondary_audio_type": null,
      "secondary_audio_language": null,
      "created_at": "2026-10-31T21:32:00+09:00",
      "updated_at": "2026-10-31T21:32:00+09:00"
    }
    """
}
