#!/bin/bash
# ==============================================
# 构建强平监控 macOS App (原生 Swift + AppKit)
# 无需安装任何依赖
# ==============================================
set -e
cd "$(dirname "$0")"

APP_NAME="LiquidationMonitor"
APP_DIR="./${APP_NAME}.app"

rm -rf "$APP_DIR"

# ── 0. 先建目录 ──
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# ── 1. 编译 Swift 菜单栏程序 ──
cat > _menu_bar.swift << 'SWIFT'
import AppKit
import Foundation

// ── 资源路径 ──
let pythonPath = "/Users/<YOUR_USER>/miniforge3/bin/python3"
let resourcesPath = Bundle.main.resourcePath!
let daemonPath = resourcesPath + "/liquidation_daemon.py"
let menuGenPath = resourcesPath + "/_menu_generator.py"

let WINDOW_WIDTH: CGFloat = 460
let WINDOW_HEIGHT: CGFloat = 680

// ── 弹窗列表数据源 ──
class PopupSrc: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var rows: [String] = []
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: rows[row])
        tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let isStar = rows[row].hasPrefix("⭐")
        tf.textColor = isStar ? NSColor(red: 1, green: 0.85, blue: 0, alpha: 1)
                              : NSColor(white: 0.9, alpha: 1)
        cell.addSubview(tf)
        tf.frame = cell.bounds.insetBy(dx: 8, dy: 1)
        tf.autoresizingMask = [.width, .height]
        return cell
    }
}

// ── Shell ──
@discardableResult
func runShell(_ cmd: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    let out = Pipe()
    p.standardOutput = out
    do {
        try p.run()
        p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8)
    } catch {
        return nil
    }
}

func ensureDaemon() {
    // 先杀所有旧进程，保证用 bundle 里的最新版
    runShell("pkill -f liquidation_daemon.py 2>/dev/null; pkill -f price_drop_monitor 2>/dev/null; pkill -f triangle_crash_scanner 2>/dev/null; sleep 1")
    runShell("nohup \(pythonPath) \(daemonPath) > /tmp/liq_daemon.log 2>&1 &")
    // 三角收敛扫描器
    runShell("nohup \(pythonPath) \(resourcesPath)/triangle_crash_scanner.py > /tmp/crash_scanner.log 2>&1 &")
}

// ── 窗口代理 ──
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_HEIGHT),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
    )
    let textView = NSTextView()
    var crashData: [String: Any] = [:]  // 缓存三角扫描数据
    weak var popupWindow: NSWindow? = nil // weak 自动清空已释放窗口
    var popupSrc: PopupSrc? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDaemon()
        setupWindow()
        refreshContent()
        // 1s 刷新，给用户足够时间选择文字
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.refreshContent()
        }
    }

    @objc func btnShowPopup(_ sender: NSButton) {
        showDetailPopup(sender.identifier?.rawValue ?? "range")
    }

    func setupWindow() {
        window.title = "Liquidation Monitor"
        window.level = .floating
        window.delegate = self

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.maxX - WINDOW_WIDTH - 20, y: f.maxY - WINDOW_HEIGHT - 40))
        }
        window.setFrameAutosaveName("LiqMonitorWindow")

        // ── 按钮栏 ──
        let btnBar = NSView(frame: NSRect(x: 0, y: WINDOW_HEIGHT - 32, width: WINDOW_WIDTH, height: 32))
        btnBar.autoresizingMask = [.width, .minYMargin]
        btnBar.wantsLayer = true
        btnBar.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor

        let mkBtn: (String, String, NSColor) -> Void = { title, actionStr, color in
            let b = NSButton(title: title, target: self, action: Selector(("btnShowPopup:")))
            b.bezelStyle = .recessed
            b.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            b.frame = NSRect(x: 8 + btnBar.subviews.count * 82, y: 2, width: 76, height: 28)
            b.identifier = NSUserInterfaceItemIdentifier(actionStr)
            btnBar.addSubview(b)
        }
        mkBtn("📐 箱体", "range", .systemBlue)
        mkBtn("💥 砸盘", "crash", .systemRed)
        mkBtn("🔥 反转", "reversal", .systemOrange)

        window.contentView?.addSubview(btnBar)

        // ── 文本区 ──
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_HEIGHT - 32))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        textView.frame = scrollView.bounds
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var lastErrorShown = Date.distantPast

    func readStatusFile() -> String {
        // 三角扫描 — 缓存数据供弹窗使用
        var triOutput = ""
        if let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/triangle_crash.json")),
           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            crashData = json
            triOutput = formatTriangle(json)
        } else {
            triOutput = "═════ 🔺 箱体砸盘扫描 ═════\n  ⏳ 启动中...\nSEPARATOR"
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".liq_harvest/liquidation_bar.json").path,
            "/tmp/liquidation_bar.json",
        ]
        var baseOutput = "⏳ 等待守护进程启动..."
        for fp in paths {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: fp)),
               let _ = String(data: d, encoding: .utf8),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                baseOutput = formatStatus(json)
                break
            }
        }
        return triOutput + baseOutput
    }

    func formatTriangle(_ s: [String: Any]) -> String {
        var lines: [String] = []
        lines.append("═════ 🔺 箱体砸盘扫描 ═════")

        let monitored = s["monitored"] as? Int ?? 0
        let range = s["range_count"] as? Int ?? 0
        let crash = s["crash_count"] as? Int ?? 0
        let rev = s["reversal_count"] as? Int ?? 0

        // 三阶段状态
        let rngLabel = range > 0 ? "\(range)个触发" : "暂无符合要求"
        let crhLabel = crash > 0 ? "\(crash)个触发" : "暂无符合要求"
        let revLabel = rev   > 0 ? "\(rev)个建议做多" : "暂无符合要求"
        lines.append("  📐 箱体震荡: \(rngLabel)")
        lines.append("  💥 砸盘确认: \(crhLabel)")
        lines.append("  🔥 反转进场: \(revLabel)")

        // 简化预览 — 显示最近几条告警
        if let alerts = s["alerts"] as? [[String: Any]], !alerts.isEmpty {
            lines.append("  ── 最近动态 ──")
            for a in alerts.suffix(5) {
                let typ = a["type"] as? String ?? ""
                let sym = a["sym"] as? String ?? "?"
                let msg = a["msg"] as? String ?? ""
                let quality = a["quality"] as? String ?? ""
                if typ == "reversal"      { lines.append("  🔥 \(sym) \(msg)") }
                else if typ == "crash"    { lines.append("  💥 \(sym) \(msg)") }
                else if quality != ""     { lines.append("  ⭐ \(sym) \(msg)") }
                else                       { lines.append("  📐 \(sym) \(msg)") }
            }
        }

        lines.append("  🕐 \(s["updated"] as? String ?? "") 监控\(monitored)币")
        lines.append("SEPARATOR")
        return lines.joined(separator: "\n") + "\n"
    }

    // ── 弹窗：纯文本、无链接、无 delegate ──
    @objc func showDetailPopup(_ type: String) {
        popupWindow?.close()
        popupWindow = nil
        let alerts = crashData["alerts"] as? [[String: Any]] ?? []
        
        var title = ""
        var filtered: [[String: Any]] = []
        for a in alerts {
            let t = a["type"] as? String ?? ""
            if (type == "range" && t == "range") ||
               (type == "crash" && t == "crash") ||
               (type == "reversal" && t == "reversal") {
                filtered.append(a)
            }
        }
        
        if type == "range" {
            title = "📐 箱体震荡 (\(filtered.count)个) — 选中币名 Cmd+C 复制"
            filtered.sort { ($0["volume"] as? Double ?? 0) > ($1["volume"] as? Double ?? 0) }
        } else if type == "crash" {
            title = "💥 砸盘确认 (\(filtered.count)个) — 选中币名 Cmd+C 复制"
        } else {
            title = "🔥 反转进场 (\(filtered.count)个) — 选中币名 Cmd+C 复制"
        }
        
        let pw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 550),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        pw.title = title
        pw.level = .floating
        pw.appearance = NSAppearance(named: .darkAqua)
        
        let sv = NSScrollView(frame: pw.contentView?.bounds ?? NSRect(x:0,y:0,width:550,height:550))
        sv.hasVerticalScroller = true
        sv.autoresizingMask = [.width, .height]
        sv.drawsBackground = false
        
        let tv = NSTextView(frame: sv.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // 不设 delegate，不用 link — 零崩溃风险
        
        var text = ""
        if filtered.isEmpty {
            text = "暂无数据\n"
        } else {
            if type == "range" {
                text += "币名\t持续\t详情\n"
                text += String(repeating: "─", count: 70) + "\n"
                for a in filtered {
                    let sym = a["sym"] as? String ?? "?"
                    let dur = a["dur_str"] as? String ?? "?"
                    let msg = a["msg"] as? String ?? ""
                    let quality = (a["quality"] as? String ?? "").isEmpty ? "" : "⭐"
                    text += "\(quality)\(sym)\t\(dur)\t\(msg)\n"
                }
            } else {
                for a in filtered {
                    let sym = a["sym"] as? String ?? "?"
                    let t = a["time"] as? String ?? ""
                    let msg = a["msg"] as? String ?? ""
                    text += "\(sym)\t\(t)\t\(msg)\n"
                }
            }
        }
        tv.string = text
        sv.documentView = tv
        pw.contentView = sv
        pw.center()
        pw.makeKeyAndOrderFront(nil)
        popupWindow = pw
    }

    func formatStatus(_ s: [String: Any]) -> String {
        var lines: [String] = []
        lines.append("═════ 📉 价格急跌 ═════")

        if let drops = s["price_drops"] as? [[String: Any]], !drops.isEmpty {
            let levels: [(Double, String)] = [(3.0, "≥3% 暴跌"), (2.0, "≥2% 大跌"), (1.5, "≥1.5% 下跌")]
            for (level, label) in levels {
                let tier = drops.reversed().filter { ($0["level"] as? Double ?? 0) == level }.prefix(10)
                if !tier.isEmpty {
                    lines.append("  \(label)")
                    for (idx, d) in tier.enumerated() {
                        let newBadge = idx == 0 ? "🆕 " : "   "
                        let m = (d["source"] as? String == "high") ? "↘high" : "  ←1min"
                        let sym = d["sym"] as? String ?? "?"
                        let pct = abs(d["drop_pct"] as? Double ?? 0)
                        let t = d["time"] as? String ?? ""
                        let price = d["price"] as? Double ?? 0
                        lines.append("  \(newBadge)\(sym) 跌 \(pct)%! \(m)  \(t)  当前=\(price)")
                    }
                }
            }
        } else {
            lines.append("  ✅ 暂无≥1.5% 急跌")
        }
        lines.append("SEPARATOR")

        // ── 价格急涨 ──
        lines.append("═════ 📈 价格急涨 ═════")
        if let rises = s["price_rises"] as? [[String: Any]], !rises.isEmpty {
            let levels: [(Double, String)] = [(3.0, "≥3% 暴涨"), (2.0, "≥2% 大涨"), (1.5, "≥1.5% 上涨")]
            for (level, label) in levels {
                let tier = rises.reversed().filter { ($0["level"] as? Double ?? 0) == level }.prefix(10)
                if !tier.isEmpty {
                    lines.append("  \(label)")
                    for (idx, d) in tier.enumerated() {
                        let newBadge = idx == 0 ? "🆕 " : "   "
                        let m = (d["source"] as? String == "low") ? "↗low" : "  ←1min"
                        let sym = d["sym"] as? String ?? "?"
                        let pct = d["rise_pct"] as? Double ?? 0
                        let t = d["time"] as? String ?? ""
                        let price = d["price"] as? Double ?? 0
                        lines.append("  \(newBadge)\(sym) 涨 \(pct)%! \(m)  \(t)  当前=\(price)")
                    }
                }
            }
        } else {
            lines.append("  ✅ 暂无≥1.5% 急涨")
        }
        lines.append("SEPARATOR")

        if s["waterfall"] as? Bool == true, let alerts = s["waterfall_alerts"] as? [[String: Any]] {
            lines.append("⚠️ 瀑布进行中!!")
            lines.append("SEPARATOR")
            for a in alerts.suffix(3) {
                let t = a["time"] as? String ?? ""
                let v = fmt(a["last_10s"] as? Double ?? 0)
                let r = a["ratio"] as? Double ?? 0
                var extra = ""
                if let ts = a["top_sym"] as? String, !ts.isEmpty {
                    extra = " 主力 \(ts)=\(fmt(a["top_val"] as? Double ?? 0))U"
                }
                lines.append("  \(t) 10s=\(v)U (\(r)x)\(extra)")
            }
            lines.append("SEPARATOR")
        }

        lines.append("═════ 💥 爆仓统计 ═════")
        lines.append("📊 最近60s: \(fmt(s["total_60s"] as? Double ?? 0))U")
        lines.append("🔴 多单爆仓: \(fmt(s["sell_60s"] as? Double ?? 0))U")
        lines.append("🟢 空单爆仓: \(fmt(s["buy_60s"] as? Double ?? 0))U")
        lines.append("📝 \(s["count_60s"] as? Int ?? 0)笔")
        lines.append("SEPARATOR")

        if let top = s["top"] as? [[String: Any]], !top.isEmpty {
            lines.append("🏆 累计 TOP5")
            for t in top.prefix(5) {
                let sym = t["sym"] as? String ?? "?"
                let total = (t["sell"] as? Double ?? 0) + (t["buy"] as? Double ?? 0)
                lines.append("  \(sym) \(fmt(total))U")
            }
            lines.append("SEPARATOR")
        }

        if let latest = s["latest"] as? [[String: Any]], !latest.isEmpty {
            lines.append("⏱ 最近\(latest.count)笔")
            for e in latest {
                let ts = DateFormatter()
                ts.dateFormat = "HH:mm:ss"
                let tsStr = ts.string(from: Date(timeIntervalSince1970: (e["ts"] as? Double ?? 0) / 1000))
                let side = e["side"] as? String ?? "?"
                let sideC = side == "SELL" ? "S" : "B"
                let sym = e["sym"] as? String ?? "?"
                let usdt = fmt(e["usdt"] as? Double ?? 0)
                let qty = e["qty"] as? Double ?? 0
                let price = e["price"] as? Double ?? 0
                lines.append("  \(tsStr) \(sideC) \(sym) \(usdt)U \(qty)枚 @\(price)")
            }
            lines.append("SEPARATOR")
        }

        lines.append("🕐 \(s["updated"] as? String ?? "")")
        return lines.joined(separator: "\n")
    }

    func fmt(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.0f", v)
    }

    @objc func refreshContent() {
        // daemon 自己会崩溃重启，不需要每 0.2s 检查
        let output = readStatusFile()

        let attr = NSMutableAttributedString()
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let monoB = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let monoSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        // 保存当前滚动位置
        let scrollView = textView.enclosingScrollView
        let oldOrigin = scrollView?.contentView.bounds.origin ?? .zero

        for line in lines {
            let l = String(line)

            // ── 分隔线 ──
            if l == "SEPARATOR" {
                attr.append(NSAttributedString(string: "─────────────────\n", attributes: [
                    .foregroundColor: NSColor.lightGray, .font: monoSmall
                ]))
                continue
            }

            // ── 段落标题 ──
            var headerColor: NSColor?
            if l.contains("急跌") { headerColor = .systemRed }
            else if l.contains("急涨") { headerColor = .systemGreen }
            else if l.contains("爆仓统计") || l.contains("瀑布") { headerColor = .systemOrange }
            else if l.contains("✅") {
                attr.append(NSAttributedString(string: l + "\n", attributes: [
                    .foregroundColor: NSColor.systemGreen, .font: mono
                ]))
                continue
            }
            else if l.contains("TOP") || l.contains("最近") { headerColor = .systemBlue }
            if let hc = headerColor {
                attr.append(NSAttributedString(string: l + "\n", attributes: [
                    .foregroundColor: hc, .font: monoB
                ]))
                continue
            }

            // ── 数据行：按 token 逐词着色 ──
            let lineAttr = NSMutableAttributedString()
            let tokens = l.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

            for (idx, token) in tokens.enumerated() {
                if token.isEmpty { continue }

                var attrs: [NSAttributedString.Key: Any] = [
                    .font: mono, .foregroundColor: NSColor.textColor
                ]
                let sep = idx < tokens.count - 1 ? " " : ""

                // 币种名称 → 青色加粗
                if token.hasSuffix("USDT") && token.uppercased() == token && token.count > 4 {
                    attrs[.foregroundColor] = NSColor.systemCyan
                    attrs[.font] = monoB
                }

                // 大额爆仓 (XXKU / XXMU / 5位+数字U) — 排除币名
                if token.hasSuffix("U") && !token.hasSuffix("USDT") {
                    let numPart = String(token.dropLast())
                    if let val = parseAmount(numPart), val >= 10_000 {
                        attrs[.foregroundColor] = NSColor.systemYellow
                        attrs[.font] = monoB
                    }
                }

                // 跌幅标记
                if token.contains("跌") || (token.hasSuffix("%") && !token.hasPrefix("✅")) {
                    attrs[.foregroundColor] = NSColor.systemRed
                    attrs[.font] = monoB
                }

                // 涨幅标记
                if token.contains("涨") {
                    attrs[.foregroundColor] = NSColor.systemGreen
                    attrs[.font] = monoB
                }

                lineAttr.append(NSAttributedString(string: token + sep, attributes: attrs))
            }
            lineAttr.append(NSAttributedString(string: "\n"))
            attr.append(lineAttr)
        }

        textView.textStorage?.setAttributedString(attr)
        // 恢复滚动位置（防止自动跳到底部）
        if let sv = scrollView, oldOrigin.y > 0 {
            sv.contentView.scroll(to: NSPoint(x: 0, y: min(oldOrigin.y, sv.contentView.bounds.maxY)))
        }
    }

    // ── 解析格式化数字 (12.3K / 5.1M / 44199) ──
    func parseAmount(_ s: String) -> Double? {
        if s.isEmpty { return nil }
        let cleaned = s.replacingOccurrences(of: ",", with: "")
        if cleaned.hasSuffix("K") {
            return Double(cleaned.dropLast()).map { $0 * 1000 }
        }
        if cleaned.hasSuffix("M") {
            return Double(cleaned.dropLast()).map { $0 * 1_000_000 }
        }
        return Double(cleaned)
    }

    @objc func windowWillClose(_ notification: Notification) {
        runShell("pkill -f liquidation_daemon.py 2>/dev/null; pkill -f price_drop_monitor 2>/dev/null; pkill -f triangle_crash_scanner 2>/dev/null")
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        runShell("pkill -f liquidation_daemon.py 2>/dev/null; pkill -f price_drop_monitor 2>/dev/null; pkill -f triangle_crash_scanner 2>/dev/null")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataFile = home.appendingPathComponent(".liq_harvest/liquidation_bar.json").path
        try? FileManager.default.removeItem(atPath: dataFile)
        try? FileManager.default.removeItem(atPath: "/tmp/triangle_crash.json")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// ── 启动 ──
let app = NSApplication.shared
app.setActivationPolicy(.regular)
// 最小菜单（只有退出）
let menuBar = NSMenu()
let appItem = NSMenuItem()
menuBar.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "退出 LiquidationMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appItem.submenu = appMenu
app.menu = menuBar

let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT

echo "  编译中..."
swiftc \
  -o "${APP_DIR}/Contents/MacOS/${APP_NAME}" \
  -framework AppKit \
  _menu_bar.swift \
  2>&1
echo "  ✅ 编译完成"

# ── 2. 创建 Info.plist ──
mkdir -p "$APP_DIR/Contents/Resources"
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LiquidationMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.binance.liq-monitor</string>
    <key>CFBundleName</key>
    <string>LiquidationMonitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

# ── 3. 复制配套文件 ──
cp _menu_generator.py "$APP_DIR/Contents/Resources/"
cp liquidation_daemon.py "$APP_DIR/Contents/Resources/"
cp triangle_crash_scanner.py "$APP_DIR/Contents/Resources/"

# ── 4. 代码签名 ──
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

# ── 5. 清理 ──
rm -f _menu_bar.swift

echo ""
echo "============================================"
echo "  🎉 LiquidationMonitor.app 构建完成!"
echo "============================================"
echo ""
echo "  路径: $(pwd)/${APP_DIR}"
echo "  使用: open ${APP_DIR} 或从 /Applications 启动"
echo ""

# 复制到 /Applications
cp -r "$APP_DIR" /Applications/ 2>/dev/null && echo "  📦 已安装到 /Applications" || echo "  ⚠️ 复制到 /Applications 失败（权限？）"
echo ""
