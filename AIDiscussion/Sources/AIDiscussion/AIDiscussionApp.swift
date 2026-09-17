import SwiftUI
import AppKit
import AIDiscussionCore

@main
struct AIDiscussionApp: App {

    @StateObject private var services: DiscussionServices

    init() {
        do {
            let instance = try DiscussionServices.makeDefault()
            _services = StateObject(wrappedValue: instance)
        } catch {
            fatalError("无法初始化 AI 议事会核心服务: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("AI 议事会") {
            DiscussionHubView(services: services)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("新建讨论组") {
                    // 可以通过通知或环境触发新建
                    NotificationCenter.default.post(name: .createNewDiscussionGroup, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

public extension Notification.Name {
    static let createNewDiscussionGroup = Notification.Name("createNewDiscussionGroup")
}
