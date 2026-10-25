import Foundation

enum ExternalAppService: String, CaseIterable, Identifiable, Codable {
    case feishu, dingtalk, wecom, ctrip, meituan, wps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .feishu: "飞书 CLI"
        case .dingtalk: "钉钉 CLI"
        case .wecom: "企业微信 CLI"
        case .ctrip: "携程"
        case .meituan: "美团"
        case .wps: "WPS 文档"
        }
    }
    var icon: String {
        switch self {
        case .feishu: "paperplane"
        case .dingtalk: "bolt"
        case .wecom: "bubble.left.and.bubble.right"
        case .ctrip: "airplane"
        case .meituan: "bag"
        case .wps: "doc.text"
        }
    }
    var isCLI: Bool { [.feishu, .dingtalk, .wecom].contains(self) }
    var brandAsset: String { "Brand-" + rawValue }
    var connectionDetail: String {
        if isCLI { return "官方账号登录与授权" }
        switch self {
        case .ctrip: return "机票、酒店与旅行查询"
        case .meituan: return "跑腿帮买、帮取送与旅行服务"
        case .wps: return "通过文件 App 选取和导入文档"
        default: return "官方账号登录与授权"
        }
    }
    var documentationURL: URL {
        let address = switch self {
        case .feishu: "https://github.com/larksuite/cli"
        case .dingtalk: "https://open.dingtalk.com/dingtalk-dev/wiki"
        case .wecom: "https://github.com/WecomTeam/wecom-cli"
        case .ctrip: "https://www.ctrip.com/wendao/openclaw"
        case .meituan: "https://developer.meituan.com/ai-hub/mcp-list"
        case .wps: "https://www.wps.cn/"
        }
        return URL(string: address)!
    }
}

struct OfficeConnectionStatus: Decodable {
    let service: String
    let installed: Bool
    let connected: Bool
    let state: String
    let message: String
    let jobID: String?
}

struct OfficeAuthorizationJob: Decodable {
    let id: String
    let service: String
    let state: String
    let message: String
    let authorizationURL: String?
    let qrCode: String?
    let verificationCode: String?
    var finished: Bool { ["complete", "error", "cancelled"].contains(state) }
}

