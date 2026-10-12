import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct SkillsPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.skills"))
    }
}

struct SkillDetailPage: View {
    let skillID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "SkillDetailPage")
    }
}
