import SwiftUI

/// マイページ: the compact width hub that lists the sections without a tab.
struct MyPageView: View {
    var body: some View {
        List {
            ForEach(MypageRow.allCases) { row in
                NavigationLink(value: row.route) {
                    Label(row.title, systemImage: row.systemImage)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mypage.\(row.rawValue)")
            }
        }
        .navigationTitle("マイページ")
    }
}
