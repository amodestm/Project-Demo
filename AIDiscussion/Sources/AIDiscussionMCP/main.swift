import Foundation
import AIDiscussionBridge

// 完整实现见 MCPServer.swift / ToolCatalog.swift / ToolHandlers.swift / BridgeClient.swift。
// 这里只负责把进程跑起来并接上 stdio。
AIDiscussionMCPServer().run()
