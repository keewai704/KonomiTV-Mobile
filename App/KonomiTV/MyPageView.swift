import SwiftUI

/// マイページ: the tab bar hub that lists the sections without a tab.
struct MyPageView: View {
    let model: AppModel

    var body: some View {
        List {
            ForEach(model.visibleMypageRows) { row in
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
