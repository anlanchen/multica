import MulticaCore
import SwiftUI

struct SkillsPage: View {
    var body: some View {
        SkillsListPage()
    }
}

struct SkillDetailPage: View {
    let skillID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "SkillDetailPage")
    }
}
