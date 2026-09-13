#!/usr/bin/env python3
"""
liquidation_viewer.py — 强平+三角扫描 监控窗口 (customtkinter)
替代 Swift App，避免内存崩溃
"""
import json, os, time, threading, re
import customtkinter as ctk

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

STATUS_FILE = os.path.expanduser("~/.liq_harvest/liquidation_bar.json")
CRASH_FILE = "/tmp/triangle_crash.json"

class MonitorApp(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("Liquidation Monitor")
        self.geometry("520x750")
        self.minsize(420, 600)
        self.attributes("-topmost", True)

        # ── 按钮栏 ──
        bar = ctk.CTkFrame(self, height=36, corner_radius=0)
        bar.pack(fill="x")
        ctk.CTkButton(bar, text="📐 箱体", width=65, height=28,
                      font=("", 11), command=lambda: self._show_popup("range")).pack(side="left", padx=2, pady=4)
        ctk.CTkButton(bar, text="💥 砸盘", width=65, height=28,
                      font=("", 11), command=lambda: self._show_popup("crash")).pack(side="left", padx=2, pady=4)
        ctk.CTkButton(bar, text="🔥 反转", width=65, height=28,
                      font=("", 11), command=lambda: self._show_popup("reversal")).pack(side="left", padx=2, pady=4)
        ctk.CTkButton(bar, text="🚀 突破", width=65, height=28,
                      font=("", 11), command=lambda: self._show_popup("breakout")).pack(side="left", padx=2, pady=4)
        ctk.CTkButton(bar, text="⚡ 急跌", width=65, height=28,
                      font=("", 11), command=lambda: self._show_popup("quick_drop")).pack(side="left", padx=2, pady=4)
        ctk.CTkLabel(bar, text="点击币名直接复制", font=("", 9), text_color="gray").pack(side="right", padx=8)

        # ── 文本区 ──
        self.text = ctk.CTkTextbox(self, font=("SF Mono", 12), wrap="none")
        self.text.pack(fill="both", expand=True, padx=0, pady=0)
        self.text.bind("<Button-1>", self._on_text_click)
        self.text.tag_config("coin", foreground="#39d6d6")  # 青色币名
        self.text.tag_config("red", foreground="#ef4444")    # 跌/爆仓
        self.text.tag_config("green", foreground="#22c55e")  # 涨/突破

        # ── 弹窗 ──
        self.popup = None
        self.crash_data = {}

        self._refresh()
        self.after(1000, self._poll)

    def _poll(self):
        self._refresh()
        self.after(1000, self._poll)

    def _read_file(self, path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception:
            return {}

    def _refresh(self):
        # 读数据
        liq = self._read_file(STATUS_FILE)
        tri = self._read_file(CRASH_FILE)
        if tri:
            self.crash_data = tri

        lines = []

        # ── 三角扫描 ──
        lines.append("═════ 🔺 箱体砸盘扫描 ═════")
        rng = tri.get("range_count", 0)
        crh = tri.get("crash_count", 0)
        rev = tri.get("reversal_count", 0)
        brk = tri.get("breakout_count", 0)
        qd  = tri.get("quick_drop_count", 0)
        lines.append(f"  📐 箱体震荡: {rng}个触发" if rng > 0 else "  📐 箱体震荡: 暂无符合要求")
        lines.append(f"  💥 砸盘确认: {crh}个触发" if crh > 0 else "  💥 砸盘确认: 暂无符合要求")
        lines.append(f"  🔥 反转进场: {rev}个建议做多" if rev > 0 else "  🔥 反转进场: 暂无符合要求")
        lines.append(f"  🚀 向上突破: {brk}个建议做多" if brk > 0 else "  🚀 向上突破: 暂无符合要求")
        lines.append(f"  ⚡ 二十分钟急跌: {qd}个触发" if qd > 0 else "  ⚡ 二十分钟急跌: 暂无符合要求")

        alerts = tri.get("alerts", [])
        special = [a for a in alerts if a.get("type") in ("breakout", "crash", "reversal", "quick_drop") or a.get("quality")]
        if special:
            lines.append("  ── 最近动态 ──")
            for a in special[-8:]:
                t = a.get("type", "")
                sym = a.get("sym", "?")
                msg = a.get("msg", "")
                if t == "reversal":
                    lines.append(f"  🔥 {sym} {msg}")
                elif t == "crash":
                    lines.append(f"  💥 {sym} {msg}")
                elif t == "breakout":
                    lines.append(f"  🚀 {sym} {msg}")
                elif t == "quick_drop":
                    lines.append(f"  ⚡ {sym} {msg}")
                else:
                    lines.append(f"  ⭐ {sym} {msg}")

        ts = tri.get("updated", time.strftime("%H:%M:%S"))
        lines.append(f"  🕐 {ts} 监控{tri.get('monitored', 0)}币")
        lines.append("")

        # ── 强平 + 价格跌幅 ──
        lines.append("═════ 📉 价格急跌 ═════")
        drops = liq.get("price_drops", [])
        if drops:
            for level, label in [(3.0, "≥3% 暴跌"), (2.0, "≥2% 大跌"), (1.5, "≥1.5% 下跌")]:
                tier = list(reversed([d for d in drops if d.get("level") == level]))[:10]
                if tier:
                    lines.append(f"  {label}")
                    for i, d in enumerate(tier):
                        new = "🆕" if i == 0 else "  "
                        src = "↘high" if d.get("source") == "high" else " ←1min"
                        lines.append(f"  {new} {d.get('sym','?')} 跌 {abs(d.get('drop_pct',0))}%! {src} {d.get('time','')} 当前={d.get('price',0)}")
        else:
            lines.append("  ✅ 暂无≥1.5% 急跌")

        lines.append("")
        lines.append("═════ 📈 价格急涨 ═════")
        rises = liq.get("price_rises", [])
        if rises:
            for level, label in [(3.0, "≥3% 暴涨"), (2.0, "≥2% 大涨"), (1.5, "≥1.5% 上涨")]:
                tier = list(reversed([r for r in rises if r.get("level") == level]))[:10]
                if tier:
                    lines.append(f"  {label}")
                    for i, d in enumerate(tier):
                        new = "🆕" if i == 0 else "  "
                        src = "↗low" if d.get("source") == "low" else " ←1min"
                        lines.append(f"  {new} {d.get('sym','?')} 涨 {d.get('rise_pct',0)}%! {src} {d.get('time','')} 当前={d.get('price',0)}")
        else:
            lines.append("  ✅ 暂无≥1.5% 急涨")

        lines.append("")
        lines.append("═════ 💥 爆仓统计 ═════")
        lines.append(f"📊 最近60s: {liq.get('total_60s', 0):.0f}U")
        lines.append(f"🔴 多单爆仓: {liq.get('sell_60s', 0):.0f}U")
        lines.append(f"🟢 空单爆仓: {liq.get('buy_60s', 0):.0f}U")
        lines.append(f"📝 {liq.get('count_60s', 0)}笔")
        lines.append("")

        top = liq.get("top", [])[:5]
        if top:
            lines.append("🏆 累计 TOP5")
            for t in top:
                total = t.get("sell", 0) + t.get("buy", 0)
                lines.append(f"  {t.get('sym','?')} {total:.0f}U")
            lines.append("")

        latest = liq.get("latest", [])[-10:]
        if latest:
            lines.append("⏱ 最近爆仓")
            for e in latest:
                side = e.get("side", "?")
                sc = "🟢B" if side == "BUY" else "🔴S"
                sym = e.get("sym", "?")
                usdt = e.get("usdt", 0)
                qty = e.get("qty", 0)
                price = e.get("price", 0)
                ts = e.get("ts", 0) / 1000
                t_str = time.strftime("%H:%M:%S", time.localtime(ts))
                lines.append(f"  {t_str} {sc} {sym} {usdt:.0f}U {qty:.1f}枚 @{price}")
            lines.append("")

        lines.append(f"🕐 爆仓: {liq.get('updated', '?')}  扫描: {tri.get('updated', '?')}  刷新: {time.strftime('%H:%M:%S')}")

        content = "\n".join(lines)

        # 始终更新（时间戳会变）
        current = self.text.get("1.0", "end-1c")
        if content != current:
            self.text.delete("1.0", "end")
            self.text.insert("1.0", content)
            # 币名高亮（匹配 BTCUSDT 等大写的 USDT 结尾词）
            for m in re.finditer(r'\b[A-Z0-9]+USDT\b', content):
                start = f"1.0+{m.start()}c"
                end = f"1.0+{m.end()}c"
                self.text.tag_add("coin", start, end)
            # 涨跌颜色（绿涨红跌）
            for ln, line in enumerate(content.split("\n"), 1):
                ls = f"{ln}.0"
                le = f"{ln}.end"
                if "📈" in line or "急涨" in line or "大涨" in line or "上涨" in line:
                    self.text.tag_add("green", ls, le)
                elif "📉" in line or "急跌" in line or "大跌" in line or "下跌" in line or "暴跌" in line or "二十分钟急跌" in line:
                    self.text.tag_add("red", ls, le)
                elif "多单爆仓" in line or "瀑布" in line:
                    self.text.tag_add("red", ls, le)
                elif "空单爆仓" in line:
                    self.text.tag_add("green", ls, le)
                elif "💥 爆仓统计" in line:
                    self.text.tag_add("red", ls, le)

    def _show_popup(self, typ):
        alerts = self.crash_data.get("alerts", [])
        filtered = [a for a in alerts if a.get("type") == typ]

        if typ == "range":
            title = f"📐 箱体震荡 ({len(filtered)}个) — 双击复制币名"
            # 优先 30-90min，再按交易量
            def range_sort_key(a):
                dur = a.get("duration", 0)
                in_sweet = 30 <= dur <= 90
                return (-in_sweet, -(a.get("volume", 0)))
            filtered.sort(key=range_sort_key)
        elif typ == "crash":
            title = f"💥 砸盘确认 ({len(filtered)}个) — 双击复制币名"
        elif typ == "breakout":
            title = f"🚀 向上突破 ({len(filtered)}个) — 双击复制币名"
        elif typ == "quick_drop":
            title = f"⚡ 二十分钟急跌 ({len(filtered)}个) — 双击复制币名"
        else:
            title = f"🔥 反转进场 ({len(filtered)}个) — 双击复制币名"

        if self.popup and self.popup.winfo_exists():
            self.popup.destroy()

        pw = ctk.CTkToplevel(self)
        pw.title(title)
        pw.geometry("560x500")
        pw.attributes("-topmost", True)
        self.popup = pw

        # ── 列表 ──
        frame = ctk.CTkScrollableFrame(pw, label_text=f"共 {len(filtered)} 条")
        frame.pack(fill="both", expand=True, padx=4, pady=4)

        for a in filtered:
            sym = a.get("sym", "?")
            if typ == "range":
                dur = a.get("dur_str", "")
                msg = a.get("msg", "")
                q = a.get("quality", "")
                prefix = "⭐" if q else "  "
                label = f"{prefix}{sym}  [{dur}]  {msg}"
            else:
                t = a.get("time", "")
                msg = a.get("msg", "")
                label = f"{sym}  [{t}]  {msg}"

            btn = ctk.CTkButton(frame, text=label, anchor="w", height=22,
                                font=("SF Mono", 11), fg_color="transparent",
                                hover_color="#1a3a5c", text_color="#55ccdd",
                                command=lambda s=sym: self._copy_sym(s))
            btn.pack(fill="x", pady=1, padx=2)

    def _copy_sym(self, sym):
        self.clipboard_clear()
        self.clipboard_append(sym)

    def _on_text_click(self, event):
        """点击文本中币种名称 → 复制"""
        idx = self.text.index(f"@{event.x},{event.y}")
        line_start = self.text.index(f"{idx} linestart")
        line_end = self.text.index(f"{idx} lineend")
        line = self.text.get(line_start, line_end)
        # 找点击位置的词
        col = int(idx.split(".")[1])
        words = re.split(r'(\s+)', line)
        pos = 0
        for w in words:
            w_clean = w.strip()
            if pos <= col < pos + len(w) and re.match(r'^[A-Z0-9]+USDT$', w_clean):
                self._copy_sym(w_clean)
                break
            pos += len(w)


if __name__ == "__main__":
    app = MonitorApp()
    app.mainloop()
