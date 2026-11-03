import Foundation

/// A major genre and its middle genres, from ARIB-STD-B10-2-H (the same
/// list the web client's ProgramUtils.CONTENT_TYPE holds).
public struct ProgramGenreCategory: Sendable, Hashable {
    public var major: String
    public var middles: [String]

    public init(major: String, middles: [String]) {
        self.major = major
        self.middles = middles
    }
}

/// Master list of the genres a program search condition can select.
public enum ProgramGenreCatalog {
    public static let categories: [ProgramGenreCategory] = [
        ProgramGenreCategory(
            major: "ニュース・報道",
            middles: [
                "定時・総合",
                "天気",
                "特集・ドキュメント",
                "政治・国会",
                "経済・市況",
                "海外・国際",
                "解説",
                "討論・会談",
                "報道特番",
                "ローカル・地域",
                "交通",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "スポーツ",
            middles: [
                "スポーツニュース",
                "野球",
                "サッカー",
                "ゴルフ",
                "その他の球技",
                "相撲・格闘技",
                "オリンピック・国際大会",
                "マラソン・陸上・水泳",
                "モータースポーツ",
                "マリン・ウィンタースポーツ",
                "競馬・公営競技",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "情報・ワイドショー",
            middles: [
                "芸能・ワイドショー",
                "ファッション",
                "暮らし・住まい",
                "健康・医療",
                "ショッピング・通販",
                "グルメ・料理",
                "イベント",
                "番組紹介・お知らせ",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "ドラマ",
            middles: [
                "国内ドラマ",
                "海外ドラマ",
                "時代劇",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "音楽",
            middles: [
                "国内ロック・ポップス",
                "海外ロック・ポップス",
                "クラシック・オペラ",
                "ジャズ・フュージョン",
                "歌謡曲・演歌",
                "ライブ・コンサート",
                "ランキング・リクエスト",
                "カラオケ・のど自慢",
                "民謡・邦楽",
                "童謡・キッズ",
                "民族音楽・ワールドミュージック",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "バラエティ",
            middles: [
                "クイズ",
                "ゲーム",
                "トークバラエティ",
                "お笑い・コメディ",
                "音楽バラエティ",
                "旅バラエティ",
                "料理バラエティ",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "映画",
            middles: [
                "洋画",
                "邦画",
                "アニメ",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "アニメ・特撮",
            middles: [
                "国内アニメ",
                "海外アニメ",
                "特撮",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "ドキュメンタリー・教養",
            middles: [
                "社会・時事",
                "歴史・紀行",
                "自然・動物・環境",
                "宇宙・科学・医学",
                "カルチャー・伝統文化",
                "文学・文芸",
                "スポーツ",
                "ドキュメンタリー全般",
                "インタビュー・討論",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "劇場・公演",
            middles: [
                "現代劇・新劇",
                "ミュージカル",
                "ダンス・バレエ",
                "落語・演芸",
                "歌舞伎・古典",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "趣味・教育",
            middles: [
                "旅・釣り・アウトドア",
                "園芸・ペット・手芸",
                "音楽・美術・工芸",
                "囲碁・将棋",
                "麻雀・パチンコ",
                "車・オートバイ",
                "コンピュータ・ＴＶゲーム",
                "会話・語学",
                "幼児・小学生",
                "中学生・高校生",
                "大学生・受験",
                "生涯教育・資格",
                "教育問題",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "福祉",
            middles: [
                "高齢者",
                "障害者",
                "社会福祉",
                "ボランティア",
                "手話",
                "文字（字幕）",
                "音声解説",
                "その他",
            ]
        ),
        ProgramGenreCategory(
            major: "拡張",
            middles: [
                "BS/地上デジタル放送用番組付属情報",
                "広帯域CSデジタル放送用拡張",
                "衛星デジタル音声放送用拡張",
                "サーバー型番組付属情報",
                "IP放送用番組付属情報",
            ]
        ),
        ProgramGenreCategory(
            major: "その他",
            middles: [
                "その他",
            ]
        ),
    ]

    /// Middle genres of a major genre, or an empty list.
    public static func middles(of major: String) -> [String] {
        categories.first { $0.major == major }?.middles ?? []
    }
}
