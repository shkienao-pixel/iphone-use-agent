import Foundation
import Security

// Credential values are accepted only on stdin and returned only to the
// connector's captured pipe. No credential is passed in a process argument.
private let identity: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "PhoneAgent.Ctrip.Local",
    kSecAttrAccount as String: "wendao-api-key",
    kSecAttrSynchronizable as String: false
]

private func reply(_ value: [String: Any], exitCode: Int32 = 0) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    exit(exitCode)
}

private func failure(_ message: String) -> Never {
    reply(["ok": false, "error": message], exitCode: 1)
}

guard CommandLine.arguments.count == 2 else { failure("无效的钥匙串操作") }
switch CommandLine.arguments[1] {
case "status":
    var query = identity
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess { reply(["ok": true, "configured": true]) }
    if status == errSecItemNotFound { reply(["ok": true, "configured": false]) }
    failure("暂时无法读取钥匙串状态，请检查钥匙串是否已解锁")
case "set":
    var incoming = Data()
    while incoming.count <= 4096 {
        let part = FileHandle.standardInput.readData(ofLength: 4097 - incoming.count)
        if part.isEmpty { break }
        incoming.append(part)
    }
    guard incoming.count <= 4096,
          let key = String(data: incoming, encoding: .utf8),
          (8...4096).contains(key.utf8.count),
          key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
        failure("授权码格式无效，未保存")
    }
    let values: [String: Any] = [
        kSecValueData as String: Data(key.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]
    var status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
        status = SecItemAdd(identity.merging(values) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { failure("授权码未能保存到本机钥匙串") }
    reply(["ok": true, "configured": true])
case "get":
    var query = identity
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data, (8...4096).contains(data.count) else {
        failure("请先在本机配置页面保存携程授权码")
    }
    FileHandle.standardOutput.write(data)
case "delete":
    let status = SecItemDelete(identity as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        failure("未能移除本机携程授权码")
    }
    reply(["ok": true, "configured": false])
default:
    failure("无效的钥匙串操作")
}
