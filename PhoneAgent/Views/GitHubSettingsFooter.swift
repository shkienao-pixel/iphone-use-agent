import SwiftUI

struct GitHubSettingsFooter: View {
    // Fixed HTTPS literals; GitHub handles repository access and sign-in.
    private let profileURL = URL(string: "https://github.com/boboabw")!
    private let projectURL = URL(string: "https://github.com/boboabw/phone-agent")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub").font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                .padding(.horizontal, 16).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Link(destination: profileURL) {
                    HStack(spacing: 14) {
                        Image("GitHubAvatar").resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("boboabw").font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text("GitHub 主页").font(.caption).foregroundStyle(AgentPalette.secondaryText)
                        }
                        Spacer(minLength: 8)
                        externalLinkIcon
                    }.padding(.vertical, 12).frame(minHeight: 72)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("GitHub 作者 boboabw")
                .accessibilityHint("打开作者的 GitHub 主页")
                Divider().padding(.leading, 38)
                Link(destination: projectURL) {
                    HStack(spacing: 8) {
                        AgentSettingsRow(title: "项目地址", subtitle: "boboabw/phone-agent", icon: "chevron.left.forwardslash.chevron.right")
                        externalLinkIcon
                    }.frame(minHeight: 72).contentShape(Rectangle())
                }
                .accessibilityLabel("打开 GitHub 项目 boboabw/phone-agent")
                Divider().padding(.leading, 38)
                Link(destination: projectURL) {
                    HStack(spacing: 8) {
                        AgentSettingsRow(title: "在 GitHub 上 Star", subtitle: "", icon: "star")
                        externalLinkIcon
                    }.frame(minHeight: 72).contentShape(Rectangle())
                }
                .accessibilityHint("打开仓库页面，可使用 GitHub 的 Star 按钮")
            }
            .buttonStyle(AgentPressStyle())
            .padding(.horizontal, 16).frame(maxWidth: .infinity)
            .agentGlass(in: AgentInputMetrics.shape)
        }
    }

    private var externalLinkIcon: some View {
        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}
