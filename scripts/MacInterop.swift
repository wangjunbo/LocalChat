import Foundation
import AppKit

@main struct MacInterop {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let prefs = UserDefaults(suiteName: "HarmonyInterop-\(UUID().uuidString)")!
        let store = ChatStore(assistantDirectory: root.appendingPathComponent("Archive"),
                              downloadsDirectory: downloads, alertPreferences: prefs,
                              deviceIdentity: UUID().uuidString, serviceType: "_lcharmonytest._tcp", onlineAlertEffect: {})
        defer { store.stop() }
        let deadline = Date().addingTimeInterval(45)
        while !store.running && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let port = store.listeningPort else { throw CocoaError(.fileReadUnknown) }
        print("PORT:\(port.rawValue)"); fflush(stdout)
        var responded = false
        let bytes = Data((0..<180000).map { UInt8($0 % 251) })
        while Date() < deadline {
            if let peer = store.peers.first(where: { $0.online }) {
                if peer.deviceType != "Phone" { throw CocoaError(.fileReadCorruptFile) }
                if !responded, store.messages[peer.id]?.contains(where: { $0.text == "来自鸿蒙的中文消息 👋" }) == true {
                    responded = true
                    store.selected = peer.id
                    store.sendText("来自 Mac 的回复 👋")
                    let fixture = root.appendingPathComponent("mac-fixture.bin")
                    try bytes.write(to: fixture)
                    store.offerFile(fixture, to: peer.id)
                    let folder = root.appendingPathComponent("mac-folder 中文")
                    try FileManager.default.createDirectory(at: folder.appendingPathComponent("子目录/空目录"), withIntermediateDirectories: true)
                    try bytes.write(to: folder.appendingPathComponent("子目录/data.bin"))
                    try Data().write(to: folder.appendingPathComponent("zero"))
                    store.offerFile(folder, to: peer.id)
                    let empty = root.appendingPathComponent("mac-empty")
                    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
                    store.offerFile(empty, to: peer.id)
                }
                if let file = store.messages[peer.id]?.first(where: { $0.fileName == "phone-fixture.bin" && $0.status == "已保存" }), let url = file.url {
                    guard try Data(contentsOf: url) == bytes else { throw CocoaError(.fileReadCorruptFile) }
                    guard let folder = store.messages[peer.id]?.first(where: { $0.fileName == "phone-folder 中文" && $0.status == "已保存" })?.url,
                          let empty = store.messages[peer.id]?.first(where: { $0.fileName == "phone-empty" && $0.status == "已保存" })?.url else {
                        try await Task.sleep(nanoseconds: 20_000_000); continue
                    }
                    guard try Data(contentsOf: folder.appendingPathComponent("子目录/data.bin")) == bytes,
                          FileManager.default.fileExists(atPath: folder.appendingPathComponent("子目录/空目录").path),
                          (try Data(contentsOf: folder.appendingPathComponent("zero"))).isEmpty,
                          (try FileManager.default.contentsOfDirectory(atPath: empty.path)).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    print("MAC_PASS"); fflush(stdout)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CocoaError(.fileReadUnknown)
    }
}
