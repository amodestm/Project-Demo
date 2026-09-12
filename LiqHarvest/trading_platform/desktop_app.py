"""
=========================================
desktop_app.py — Binance 快速下单终端
=========================================
功能：
  - 余额 / PnL 状态栏
  - 行情条（当前价 / 涨跌幅）
  - 币种选择 + 搜索
  - 仓位% + 杠杆 + 市价/限价
  - 做多 / 做空 / 对冲一键下单
  - 止盈止损条件单（限价自动算价 / 市价直接挂）
  - 底部日志
"""
import json, os, threading, time, urllib.request, urllib.error
import customtkinter as ctk
from typing import Optional

BACKEND_URL = "http://127.0.0.1:9090"
# Binance USDT/USDC 交易费率
MAKER_FEE = 0.0002   # 限价被吃 0.02%
TAKER_FEE = 0.0005   # 市价/主动吃单 0.05%
ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")


# ==================== API 客户端 ====================

class API:
    @staticmethod
    def _req(path: str, method="GET", body=None) -> dict:
        url = BACKEND_URL + path
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=8) as r:
                return json.loads(r.read())
        except Exception as e:
            return {"error": str(e)}

    @staticmethod
    def get_ticker(sym):       return API._req(f"/api/ticker?symbol={sym}")
    @staticmethod
    def get_account():         return API._req("/api/account")
    @staticmethod
    def get_balances():        return API._req("/api/balances").get("balances", [])
    @staticmethod
    def get_pairs():           return API._req("/api/pairs").get("pairs", [])
    @staticmethod
    def get_positions():       return API._req("/api/positions").get("positions", [])
    @staticmethod
    def get_open_orders():     return API._req("/api/open_orders").get("orders", [])
    @staticmethod
    def get_conditional_orders(): return API._req("/api/conditional_orders").get("orders", [])
    @staticmethod
    def cancel_order(symbol, order_id):
        return API._req("/api/cancel_order", "POST", {"symbol": symbol, "orderId": order_id})
    @staticmethod
    def cancel_conditional_order(symbol, strategy_id):
        return API._req("/api/cancel_conditional_order", "POST",
                        {"symbol": symbol, "strategyId": strategy_id})
    @staticmethod
    def cancel_all():
        return API._req("/api/cancel_all", "POST", {})
    @staticmethod
    def place_order(legs, mode="long"):
        return API._req("/api/order", "POST", {"legs": legs, "mode": mode})
    @staticmethod
    def place_conditional_orders(orders: list) -> dict:
        return API._req("/api/conditional_orders", "POST", {"orders": orders})


# ==================== 主应用 ====================

class App(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("Binance 快速下单终端")
        self.geometry("860x900")
        self.minsize(720, 700)
        self.attributes("-topmost", True)  # 始终置顶

        self.all_pairs   = []
        self.current_symbol = "ETHUSDT"
        self.current_price = 0.0
        self.bid1 = 0.0
        self.ask1 = 0.0
        self.balance     = 0.0
        self._pending_tp = None
        self._running    = True

        self._build_ui()
        self.after(200, self._update_balances)
        self.after(500, self._load_pairs)
        self.after(1000, self._refresh_positions_and_orders)
        self._start_polling()

    # ==================== UI ====================

    def _build_ui(self):
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=0)
        self.grid_rowconfigure(1, weight=0)
        self.grid_rowconfigure(2, weight=1)
        self.grid_rowconfigure(3, weight=0)
        self._build_topbar()
        self._build_ticker()
        self._build_trade()
        self._build_log()

    # ---- 顶部状态栏 ----
    def _build_topbar(self):
        bar = ctk.CTkFrame(self, height=38, corner_radius=0)
        bar.grid(row=0, column=0, sticky="ew")
        bar.grid_columnconfigure(4, weight=1)

        ctk.CTkLabel(bar, text="Binance 快速下单", font=("SF Pro", 14, "bold")).grid(
            row=0, column=0, padx=10, pady=6)

        self.bal_toggle = ctk.CTkSegmentedButton(
            bar, values=["USDT", "USDC", "全部"],
            selected_color="#3b82f6", font=("SF Mono", 10),
            command=self._on_bal_toggle)
        self.bal_toggle.grid(row=0, column=1, padx=4)
        self.bal_toggle.set("USDC")

        self.bal_label    = ctk.CTkLabel(bar, text="余额: --", font=("SF Mono", 12))
        self.bal_label.grid(row=0, column=2, padx=6)

        self.upnl_label   = ctk.CTkLabel(bar, text="PnL: --", font=("SF Mono", 12))
        self.upnl_label.grid(row=0, column=3, padx=6)

        self.conn_label   = ctk.CTkLabel(bar, text="● 连接中",
                                          font=("SF Mono", 11), text_color="#f59e0b")
        self.conn_label.grid(row=0, column=4, padx=8, sticky="e")

    # ---- 行情条 ----
    def _build_ticker(self):
        bar = ctk.CTkFrame(self, height=30, corner_radius=0, fg_color="#0f172a")
        bar.grid(row=1, column=0, sticky="ew", padx=0)
        bar.grid_columnconfigure(4, weight=1)

        tk = ("SF Mono", 11)
        self.tk_price  = ctk.CTkLabel(bar, text="--", font=("SF Mono", 16, "bold"))
        self.tk_price.grid(row=0, column=0, padx=(10, 8), pady=4)
        self.tk_change = ctk.CTkLabel(bar, text="0.00%", font=tk, text_color="gray")
        self.tk_change.grid(row=0, column=1, padx=4)
        ctk.CTkLabel(bar, text="高", font=tk, text_color="gray").grid(row=0, column=2, padx=(12,2))
        self.tk_high   = ctk.CTkLabel(bar, text="--", font=tk)
        self.tk_high.grid(row=0, column=3, padx=2)
        ctk.CTkLabel(bar, text="低", font=tk, text_color="gray").grid(row=0, column=4, padx=(12,2))
        self.tk_low    = ctk.CTkLabel(bar, text="--", font=tk)
        self.tk_low.grid(row=0, column=5, padx=2)

    # ---- 下单面板 ----
    def _build_trade(self):
        frame = ctk.CTkScrollableFrame(self)
        frame.grid(row=2, column=0, sticky="nsew", padx=8, pady=4)
        frame.grid_columnconfigure(0, weight=1)

        # 币种选择
        pf = ctk.CTkFrame(frame, fg_color="transparent")
        pf.pack(fill="x", padx=10, pady=(8, 4))
        ctk.CTkLabel(pf, text="币种", font=("SF Pro", 12), width=40).pack(side="left")
        self.pair_var   = ctk.StringVar(value="ETHUSDT")
        self.pair_combo = ctk.CTkComboBox(
            pf, values=["ETHUSDT", "BTCUSDT"],
            variable=self.pair_var, command=self._on_pair_change, width=180)
        self.pair_combo.pack(side="left", padx=(4, 8))
        self.search_entry = ctk.CTkEntry(pf, placeholder_text="搜索...", width=100)
        self.search_entry.pack(side="left")
        self.search_entry.bind("<KeyRelease>", self._on_search)

        # 余额信息条
        self.pos_info_label = ctk.CTkLabel(
            frame, text="余额: -- USDC", font=("SF Mono", 9), text_color="#64748b")
        self.pos_info_label.pack(anchor="w", padx=12, pady=(0, 2))

        # ---- 做多行 ----
        def _make_row(parent, name, color, on_var, pos_var, lev_var, type_var, price_var):
            row = ctk.CTkFrame(parent, fg_color="#0f172a")
            row.pack(fill="x", padx=10, pady=2)

            ctk.CTkSwitch(row, text=name, variable=on_var, width=56,
                          progress_color=color, font=("SF Pro", 11, "bold"),
                          command=self._update_pnl).pack(side="left", padx=(6,4))

            for pct in [10, 25, 50, 75, 100]:
                ctk.CTkButton(row, text=str(pct), width=28, height=22,
                              font=("SF Mono", 9), fg_color="#1e293b",
                              hover_color="#334155",
                              command=lambda p=pct, v=pos_var: (v.set(str(p)), self._update_pnl())
                              ).pack(side="left", padx=1)

            e = ctk.CTkEntry(row, textvariable=pos_var, width=36, font=("SF Mono", 11))
            e.pack(side="left", padx=(2,0))
            e.bind("<KeyRelease>", lambda _: self._update_pnl())
            ctk.CTkLabel(row, text="%", font=("SF Mono", 9), text_color="gray").pack(side="left")

            ctk.CTkLabel(row, text="杠杆", font=("SF Mono", 8), text_color="gray").pack(side="left", padx=(6,1))
            le = ctk.CTkEntry(row, textvariable=lev_var, width=32, font=("SF Mono", 11))
            le.pack(side="left")
            le.bind("<KeyRelease>", lambda _: self._update_pnl())
            ctk.CTkLabel(row, text="x", font=("SF Mono", 9), text_color="gray").pack(side="left")

            ctk.CTkSegmentedButton(row, values=["市价","限价"], variable=type_var,
                                    font=("SF Mono", 9), width=80,
                                    command=lambda _: self._update_pnl()).pack(side="left", padx=(6,2))
            pe = ctk.CTkEntry(row, textvariable=price_var, width=72,
                               placeholder_text="价格", font=("SF Mono", 10))
            pe.pack(side="left", padx=2)
            pe.bind("<KeyRelease>", lambda _: self._update_pnl())

            # 预计数量 label 直接在 row 里创建
            qty_lbl = ctk.CTkLabel(row, text="0", font=("SF Mono", 9),
                                    text_color="#64748b", width=60)
            qty_lbl.pack(side="right", padx=6)
            return qty_lbl

        self.long_on     = ctk.BooleanVar(value=True)
        self.pos_l_var   = ctk.StringVar(value="50")
        self.lev_l_var   = ctk.StringVar(value="20")
        self.type_l_var  = ctk.StringVar(value="市价")
        self.price_l_var = ctk.StringVar(value="")
        self.qty_l_label = _make_row(frame, "做多", "#16a34a",
                                      self.long_on, self.pos_l_var, self.lev_l_var,
                                      self.type_l_var, self.price_l_var)

        self.short_on    = ctk.BooleanVar(value=False)
        self.pos_s_var   = ctk.StringVar(value="50")
        self.lev_s_var   = ctk.StringVar(value="20")
        self.type_s_var  = ctk.StringVar(value="市价")
        self.price_s_var = ctk.StringVar(value="")
        self.qty_s_label = _make_row(frame, "做空", "#dc2626",
                                      self.short_on, self.pos_s_var, self.lev_s_var,
                                      self.type_s_var, self.price_s_var)

        # 多空互斥：一次只能选一边
        self.long_on.trace_add("write", self._enforce_exclusive_long)
        self.short_on.trace_add("write", self._enforce_exclusive_short)

        # 执行按钮
        bf = ctk.CTkFrame(frame, fg_color="transparent")
        bf.pack(fill="x", padx=10, pady=8)
        ctk.CTkButton(bf, text="做多", fg_color="#16a34a", hover_color="#15803d",
                      font=("SF Pro", 13, "bold"),
                      command=lambda: self._place("long")).pack(side="left", fill="x", expand=True, padx=(0,2))
        ctk.CTkButton(bf, text="做空", fg_color="#dc2626", hover_color="#b91c1c",
                      font=("SF Pro", 13, "bold"),
                      command=lambda: self._place("short")).pack(side="left", fill="x", expand=True, padx=(2,0))

        # ---- 止盈止损 ----
        tp_frame = ctk.CTkFrame(frame, fg_color="#0f172a")
        tp_frame.pack(fill="x", padx=10, pady=(4, 2))

        # 第一行：总开关
        r1 = ctk.CTkFrame(tp_frame, fg_color="transparent")
        r1.pack(fill="x", padx=6, pady=(6,2))

        self.tp_enabled = ctk.BooleanVar(value=False)
        ctk.CTkSwitch(r1, text="止盈止损", variable=self.tp_enabled,
                      font=("SF Pro", 10, "bold"), progress_color="#3b82f6",
                      command=self._update_tp_display).pack(side="left", padx=(0,8))
        ctk.CTkLabel(r1, text="(% 是保证金盈亏，已含手续费)",
                     font=("SF Mono", 8), text_color="gray").pack(side="left")

        # 第二行：止盈 % + 平仓% + 类型
        r2 = ctk.CTkFrame(tp_frame, fg_color="transparent")
        r2.pack(fill="x", padx=6, pady=2)
        ctk.CTkLabel(r2, text="止盈", font=("SF Mono", 10, "bold"),
                     text_color="#22c55e", width=36, anchor="w").pack(side="left")
        self.tp_pct_var = ctk.StringVar(value="20")
        ctk.CTkEntry(r2, textvariable=self.tp_pct_var, width=42,
                     font=("SF Mono", 11)).pack(side="left", padx=(2,0))
        ctk.CTkLabel(r2, text="% → 平", font=("SF Mono", 9),
                     text_color="gray").pack(side="left", padx=(4,2))
        self.tp_close_pct_var = ctk.StringVar(value="100")
        ctk.CTkEntry(r2, textvariable=self.tp_close_pct_var, width=36,
                     font=("SF Mono", 11)).pack(side="left")
        ctk.CTkLabel(r2, text="%", font=("SF Mono", 9),
                     text_color="gray").pack(side="left", padx=(2,6))
        # 止盈固定限价（普通限价单，非条件单）
        ctk.CTkLabel(r2, text="限价", font=("SF Mono", 9, "bold"),
                     text_color="#22c55e").pack(side="left")
        self.tp_type_var = ctk.StringVar(value="限价")

        # 第三行：止损 % + 平仓% + 类型
        r3 = ctk.CTkFrame(tp_frame, fg_color="transparent")
        r3.pack(fill="x", padx=6, pady=(2,6))
        ctk.CTkLabel(r3, text="止损", font=("SF Mono", 10, "bold"),
                     text_color="#ef4444", width=36, anchor="w").pack(side="left")
        self.sl_pct_var = ctk.StringVar(value="10")
        ctk.CTkEntry(r3, textvariable=self.sl_pct_var, width=42,
                     font=("SF Mono", 11)).pack(side="left", padx=(2,0))
        ctk.CTkLabel(r3, text="% → 平", font=("SF Mono", 9),
                     text_color="gray").pack(side="left", padx=(4,2))
        self.sl_close_pct_var = ctk.StringVar(value="100")
        ctk.CTkEntry(r3, textvariable=self.sl_close_pct_var, width=36,
                     font=("SF Mono", 11)).pack(side="left")
        ctk.CTkLabel(r3, text="%", font=("SF Mono", 9),
                     text_color="gray").pack(side="left", padx=(2,6))
        # 止损：市价 / 限价
        self.sl_type_var = ctk.StringVar(value="市价")
        ctk.CTkSegmentedButton(r3, values=["市价","限价"], variable=self.sl_type_var,
                                font=("SF Mono", 9), width=90,
                                command=lambda _: self._update_pnl()
                                ).pack(side="left")

        # 预览行（显示计算出的价格）
        self.tp_preview = ctk.CTkLabel(tp_frame, text="", font=("SF Mono", 9), text_color="#64748b")
        self.tp_preview.pack(anchor="w", padx=8, pady=(0,6))

        # ---- 持仓区 ----
        pos_card = ctk.CTkFrame(frame, fg_color="#0f172a")
        pos_card.pack(fill="x", padx=10, pady=(8, 2))
        ph = ctk.CTkFrame(pos_card, fg_color="transparent")
        ph.pack(fill="x", padx=6, pady=(6,2))
        ctk.CTkLabel(ph, text="持仓", font=("SF Pro", 11, "bold")).pack(side="left")
        self.pos_count_lbl = ctk.CTkLabel(ph, text="0", font=("SF Mono", 10),
                                            text_color="#64748b")
        self.pos_count_lbl.pack(side="left", padx=(6,0))
        ctk.CTkButton(ph, text="刷新", width=46, height=20, font=("SF Mono", 9),
                      fg_color="#334155",
                      command=self._refresh_positions_and_orders
                      ).pack(side="right", padx=(2,4))
        self.pos_container = ctk.CTkFrame(pos_card, fg_color="transparent")
        self.pos_container.pack(fill="x", padx=6, pady=(0,6))

        # ---- 挂单区 (普通+条件单) ----
        ord_card = ctk.CTkFrame(frame, fg_color="#0f172a")
        ord_card.pack(fill="x", padx=10, pady=(2, 8))
        oh = ctk.CTkFrame(ord_card, fg_color="transparent")
        oh.pack(fill="x", padx=6, pady=(6,2))
        ctk.CTkLabel(oh, text="挂单 (TP/SL/限价)", font=("SF Pro", 11, "bold")).pack(side="left")
        self.ord_count_lbl = ctk.CTkLabel(oh, text="0", font=("SF Mono", 10),
                                            text_color="#64748b")
        self.ord_count_lbl.pack(side="left", padx=(6,0))
        ctk.CTkButton(oh, text="一键全撤", width=66, height=20, font=("SF Mono", 9),
                      fg_color="#dc2626", hover_color="#b91c1c",
                      command=self._cancel_all_clicked
                      ).pack(side="right", padx=(2,4))
        self.ord_container = ctk.CTkFrame(ord_card, fg_color="transparent")
        self.ord_container.pack(fill="x", padx=6, pady=(0,6))

    # ---- 日志 ----
    def _build_log(self):
        frame = ctk.CTkFrame(self, height=100, corner_radius=0)
        frame.grid(row=3, column=0, sticky="ew", padx=0)
        frame.grid_columnconfigure(0, weight=1)
        frame.grid_rowconfigure(1, weight=1)

        hf = ctk.CTkFrame(frame, fg_color="transparent")
        hf.grid(row=0, column=0, sticky="ew", padx=4, pady=(2,0))
        ctk.CTkLabel(hf, text="日志", font=("SF Pro", 10, "bold")).pack(side="left", padx=4)
        ctk.CTkButton(hf, text="清空", width=40, height=18, font=("SF Mono", 9),
                      fg_color="#334155",
                      command=lambda: (self.log_text.configure(state="normal"),
                                       self.log_text.delete("1.0","end"),
                                       self.log_text.configure(state="disabled"))
                      ).pack(side="right", padx=4)

        self.log_text = ctk.CTkTextbox(frame, height=80, font=("SF Mono", 10), wrap="word")
        self.log_text.grid(row=1, column=0, sticky="ew", padx=4, pady=(0,4))
        self.log_text.insert("end", "就绪。\n")
        self.log_text.configure(state="disabled")

    # ==================== 事件 ====================

    def _update_pnl(self):
        """更新预计数量 + 余额信息 + 止盈止损价格预览"""
        try:
            # 精确预留手续费：单边费率 × 杠杆 ≈ 占保证金的百分比
            ll_v = max(int(self.lev_l_var.get() or 1), 1)
            ls_v = max(int(self.lev_s_var.get() or 1), 1)
            ent_l_lim = self.type_l_var.get() == "限价"
            ent_s_lim = self.type_s_var.get() == "限价"
            fee_l = (MAKER_FEE if ent_l_lim else TAKER_FEE) * ll_v  # 入场单边费/保证金
            fee_s = (MAKER_FEE if ent_s_lim else TAKER_FEE) * ls_v
            # 留 2 倍单边费（够入场+一次出场），最多 8% 防极端
            fee_buffer = min(max(fee_l, fee_s) * 2, 0.08)
            balance = max(self.balance, 0.0001) * (1 - fee_buffer)
            price_l = self._get_entry_price("long")
            price_s = self._get_entry_price("short")

            long_on  = self.long_on.get()
            short_on = self.short_on.get()

            ll = ll_v
            ls = ls_v

            def _pct(v):
                try: return min(float(v.strip().rstrip('%')) / 100, 1.0)
                except: return 0

            pct_l = _pct(self.pos_l_var.get()) if long_on else 0
            pct_s = _pct(self.pos_s_var.get()) if short_on else 0

            qty_l = balance * pct_l * ll / price_l if long_on and price_l > 0 else 0
            qty_s = balance * pct_s * ls / price_s if short_on and price_s > 0 else 0

            def _fmt(q):
                return f"{q:.6f}" if q >= 0.000001 else f"{q:.2e}"

            self.qty_l_label.configure(text=_fmt(qty_l),
                                        text_color="#22c55e" if long_on else "#64748b")
            self.qty_s_label.configure(text=_fmt(qty_s),
                                        text_color="#ef4444" if short_on else "#64748b")

            # 余额信息
            total_pct = (pct_l if long_on else 0) + (pct_s if short_on else 0)
            over = total_pct > 1.0
            parts = [f"余额: {self.balance:.4f}"]
            if long_on:
                margin_l = balance * pct_l  # 实际占用保证金
                notion_l = qty_l * price_l if price_l > 0 else 0
                parts.append(f"多 仓{pct_l*100:.0f}% 保证金{margin_l:.2f} 名义{notion_l:.2f}")
            if short_on:
                margin_s = balance * pct_s
                notion_s = qty_s * price_s if price_s > 0 else 0
                parts.append(f"空 仓{pct_s*100:.0f}% 保证金{margin_s:.2f} 名义{notion_s:.2f}")
            parts.append(f"留费{fee_buffer*100:.1f}%")
            if over: parts.append(f"⚠️合计{total_pct*100:.0f}%>100%")
            self.pos_info_label.configure(
                text=" | ".join(parts),
                text_color="#ef4444" if over else "#64748b")

            # 止盈止损价格预览（按保证金 % + 手续费）
            if self.tp_enabled.get():
                try:
                    tp_pct = float(self.tp_pct_var.get() or 0)
                    sl_pct = float(self.sl_pct_var.get() or 0)
                    sl_t   = self.sl_type_var.get()
                    tp_lim = True   # 止盈固定限价
                    sl_lim = sl_t == "限价"
                    lines  = []

                    def _row(side_lbl, side, ref, lev, ent_lim):
                        if ref <= 0:
                            return None
                        ef = MAKER_FEE if ent_lim else TAKER_FEE
                        tp_px = self._calc_tp_sl_price(ref, side, tp_pct, lev,
                                                        ent_lim, tp_lim, True)
                        sl_px = self._calc_tp_sl_price(ref, side, sl_pct, lev,
                                                        ent_lim, sl_lim, False)
                        tp_move = (tp_px-ref)/ref*100 * (1 if side=="LONG" else -1)
                        sl_move = (sl_px-ref)/ref*100 * (1 if side=="LONG" else -1)
                        tp_fee = (ef + (MAKER_FEE if tp_lim else TAKER_FEE))*lev*100
                        sl_fee = (ef + (MAKER_FEE if sl_lim else TAKER_FEE))*lev*100
                        return (
                            f"{side_lbl}@{ref:.4f} {lev}x (含费)\n"
                            f"  TP {tp_t}→{tp_px:.4f}  价{tp_move:+.2f}%  "
                            f"保证金+{tp_pct:.0f}% (费{tp_fee:.2f}%)\n"
                            f"  SL {sl_t}→{sl_px:.4f}  价{sl_move:+.2f}%  "
                            f"保证金-{sl_pct:.0f}% (费{sl_fee:.2f}%)"
                        )

                    if long_on:
                        r = _row("多", "LONG", price_l or self.current_price, ll,
                                  self.type_l_var.get() == "限价")
                        if r: lines.append(r)
                    if short_on:
                        r = _row("空", "SHORT", price_s or self.current_price, ls,
                                  self.type_s_var.get() == "限价")
                        if r: lines.append(r)
                    self.tp_preview.configure(text="\n".join(lines))
                except Exception:
                    self.tp_preview.configure(text="")
            else:
                self.tp_preview.configure(text="")
        except Exception as e:
            self.pos_info_label.configure(text=f"计算错误: {e}", text_color="#ef4444")

    def _update_tp_display(self):
        self._update_pnl()

    def _enforce_exclusive_long(self, *_):
        """打开多 → 关空"""
        if self.long_on.get() and self.short_on.get():
            self.short_on.set(False)
        self._update_pnl()

    def _enforce_exclusive_short(self, *_):
        """打开空 → 关多"""
        if self.short_on.get() and self.long_on.get():
            self.long_on.set(False)
        self._update_pnl()

    def _calc_tp_sl_price(self, entry_price, side, pct, leverage,
                          entry_is_limit, exit_is_limit, is_tp):
        """
        根据保证金盈亏目标 % 反推 TP/SL 触发价格（已含手续费）
        side: "LONG" / "SHORT"
        pct:  保证金浮盈/亏 % (如 20 表示 +20%)
        leverage: 杠杆倍数
        entry_is_limit / exit_is_limit: True=Maker(0.02%) / False=Taker(0.04%)
        is_tp: True=止盈, False=止损
        """
        if leverage <= 0 or pct <= 0 or entry_price <= 0:
            return entry_price
        ef = MAKER_FEE if entry_is_limit else TAKER_FEE
        xf = MAKER_FEE if exit_is_limit else TAKER_FEE
        # 单边费率叠加杠杆 → 反映到保证金 %
        fee_pct_margin = (ef + xf) * leverage * 100
        # 止盈：要扣回手续费（赚的要还费）→ 价格变动幅度更大
        # 止损：手续费已扣进亏损 → 价格变动幅度更小
        if is_tp:
            target_pct_price = (pct + fee_pct_margin) / leverage / 100
        else:
            target_pct_price = (pct - fee_pct_margin) / leverage / 100
            target_pct_price = max(target_pct_price, 0)
        if side == "LONG":
            return entry_price * (1 + target_pct_price) if is_tp \
                   else entry_price * (1 - target_pct_price)
        else:  # SHORT
            return entry_price * (1 - target_pct_price) if is_tp \
                   else entry_price * (1 + target_pct_price)

    def _get_entry_price(self, side):
        if side == "long":
            v = self.price_l_var.get().strip()
            t = self.type_l_var.get()
        else:
            v = self.price_s_var.get().strip()
            t = self.type_s_var.get()
        if t == "限价" and v:
            try: return float(v)
            except: pass
        return self.current_price if self.current_price > 0 else 1.0

    def _on_pair_change(self, sym):
        self.current_symbol = sym.strip().upper()
        threading.Thread(target=self._fetch_ticker, daemon=True).start()

    def _on_search(self, _=None):
        q = self.search_entry.get().strip().upper()
        if not self.all_pairs:
            self._log("币种列表还没加载完，请稍等", True)
            return
        filtered = [p for p in self.all_pairs if q in p] if q else self.all_pairs
        # 精确匹配优先（搜 BTC 时 BTCUSDT 排在 BTCUSDC 前面）
        if q:
            exact = [p for p in filtered if p == q + "USDT" or p == q + "USDC" or p == q]
            others = [p for p in filtered if p not in exact]
            filtered = exact + others
        self.pair_combo.configure(values=filtered[:100])
        # 自动切换到第一个匹配项 → 立刻刷新行情
        if filtered and q and filtered[0] != self.pair_var.get():
            self.pair_var.set(filtered[0])
            self.current_symbol = filtered[0]
            threading.Thread(target=self._fetch_ticker, daemon=True).start()

    def _on_bal_toggle(self, coin):
        threading.Thread(target=self._fetch_balance, args=(coin,), daemon=True).start()

    # ==================== 下单 ====================

    def _calc_qty(self, mode):
        # 精确预留手续费（与 _update_pnl 一致）
        ll = max(int(self.lev_l_var.get() or 1), 1)
        ls = max(int(self.lev_s_var.get() or 1), 1)
        ent_l_lim = self.type_l_var.get() == "限价"
        ent_s_lim = self.type_s_var.get() == "限价"
        fee_l = (MAKER_FEE if ent_l_lim else TAKER_FEE) * ll
        fee_s = (MAKER_FEE if ent_s_lim else TAKER_FEE) * ls
        fee_buffer = min(max(fee_l, fee_s) * 2, 0.08)
        balance = max(self.balance, 0.0001) * (1 - fee_buffer)
        price_l = self._get_entry_price("long")
        price_s = self._get_entry_price("short")
        long_on  = self.long_on.get()
        short_on = self.short_on.get()

        def _pct(v):
            try: return min(float(v.strip().rstrip('%')) / 100, 1.0)
            except: return 0

        pct_l = _pct(self.pos_l_var.get()) if long_on else 0
        pct_s = _pct(self.pos_s_var.get()) if short_on else 0

        ql = balance * pct_l * ll / price_l if long_on and price_l > 0 else 0
        qs = balance * pct_s * ls / price_s if short_on and price_s > 0 else 0

        MIN_NOTIONAL = 20.0    # ETHUSDT 等主流币最低名义价值 $20
        if long_on and pct_l > 0 and price_l > 0 and ql * price_l < MIN_NOTIONAL:
            ql = MIN_NOTIONAL / price_l
        if short_on and pct_s > 0 and price_s > 0 and qs * price_s < MIN_NOTIONAL:
            qs = MIN_NOTIONAL / price_s

        return ql, qs

    def _place(self, mode):
        sym = self.pair_var.get().strip().upper()
        if not sym: return

        # 仓位%校验
        try:
            pct_l = float(self.pos_l_var.get() or 0) if self.long_on.get() else 0
            pct_s = float(self.pos_s_var.get() or 0) if self.short_on.get() else 0
        except ValueError:
            self._log("❌ 仓位%格式错误", True)
            return

        ql, qs = self._calc_qty(mode)
        ll, ls = self.lev_l_var.get(), self.lev_s_var.get()

        ot_l = "LIMIT" if self.type_l_var.get() == "限价" else "MARKET"
        ot_s = "LIMIT" if self.type_s_var.get() == "限价" else "MARKET"

        def _lp(v):
            try: return float(v.get().strip()) if v.get().strip() else None
            except: return None

        price_l = (_lp(self.price_l_var) or self.ask1) if ot_l == "LIMIT" else None
        price_s = (_lp(self.price_s_var) or self.bid1) if ot_s == "LIMIT" else None

        legs = []
        if mode == "long" and ql > 0:
            legs.append({"symbol": sym, "side": "BUY",  "quantity": ql,
                         "position_side": "LONG",  "leverage": int(ll),
                         "order_type": ot_l, "price": price_l})
        if mode == "short" and qs > 0:
            legs.append({"symbol": sym, "side": "SELL", "quantity": qs,
                         "position_side": "SHORT", "leverage": int(ls),
                         "order_type": ot_s, "price": price_s})

        if not legs:
            self._log("❌ 无有效下单腿，请检查开关和仓位设置", True)
            return

        # 保存止盈止损参数
        self._pending_tp = None
        if self.tp_enabled.get():
            entry_l = price_l or self.current_price
            entry_s = price_s or self.current_price
            try:
                tp_pct_v = float(self.tp_pct_var.get() or 0)
                sl_pct_v = float(self.sl_pct_var.get() or 0)
            except ValueError:
                tp_pct_v = sl_pct_v = 0
            if tp_pct_v <= 0 and sl_pct_v <= 0:
                self._log("⚠️ 止盈止损开了但 TP%/SL% 都是 0，不会挂单", True)
            else:
                self._pending_tp = {
                    "mode": mode, "sym": sym, "ql": ql, "qs": qs,
                    "ll": int(ll), "ls": int(ls),
                }
                self._log(f"📌 已计划止盈止损: TP={tp_pct_v}% SL={sl_pct_v}% 待入场成交后挂出")
        else:
            self._log("ℹ️ 止盈止损开关未打开，下单后不会自动挂 TP/SL")

        self._log(f"下单: {mode} {sym} 多{ql:.4f} 空{qs:.4f}")
        threading.Thread(target=self._do_order, args=(legs, mode), daemon=True).start()

    def _do_order(self, legs, mode):
        try:
            r = API.place_order(legs, mode)
            if r.get("error"):
                self.after(0, lambda e=r["error"]: self._log(f"下单失败: {e}", True))
                return
            entry_ok = False
            for d in r.get("details", []):
                sym, sd, qty = d["symbol"], d["side"], d["quantity"]
                rid = str(d.get("result", ""))
                if rid.isdigit() or rid.startswith("sim_"):
                    self.after(0, lambda s=sym, sd=sd, q=qty: self._log(f"✓ {s} {sd} {q}"))
                    entry_ok = True
                else:
                    self.after(0, lambda s=sym, e=rid: self._log(f"❌ {s} → {e[:80]}", True))

            if entry_ok and self._pending_tp:
                tp = self._pending_tp
                threading.Thread(target=self._wait_and_place_tp_sl,
                                 args=(tp,), daemon=True).start()
            else:
                self.after(800, self._refresh_balances)
        except Exception as e:
            self.after(0, lambda: self._log(f"下单异常: {e}", True))

    def _wait_and_place_tp_sl(self, tp):
        """轮询持仓直到成交，立刻挂条件单"""
        sym = tp["sym"]
        last_log = ""
        for i in range(30):
            try:
                ps = API.get_positions()
                # 单独诊断 — 看到底有没有这个币种
                pos_sym = [p for p in ps if p["symbol"] == sym]
                has_l = any(p["side"] == "LONG"  for p in pos_sym)
                has_s = any(p["side"] == "SHORT" for p in pos_sym)
                mode  = tp.get("mode", "long")
                need_l = mode == "long"  and tp["ql"] > 0
                need_s = mode == "short" and tp["qs"] > 0
                if (not need_l or has_l) and (not need_s or has_s):
                    elapsed = round((i+1)*0.5, 1)
                    p0 = pos_sym[0] if pos_sym else {}
                    self.after(0, lambda t=elapsed, q=p0.get("quantity",0),
                                       e=p0.get("entry_price",0):
                               self._log(f"✓ 持仓确认({t}s) 数量={q} 入场={e}, 开始挂条件单"))
                    self._place_tp_sl(tp)
                    self.after(500, self._refresh_balances)
                    self.after(800, self._refresh_positions_and_orders)
                    return
                # 每 5 秒输出一次"还在等"
                if i > 0 and i % 10 == 0:
                    msg = (f"等待持仓确认...({i*0.5:.0f}s) "
                           f"该币种持仓数={len(pos_sym)} 总持仓数={len(ps)}")
                    if msg != last_log:
                        last_log = msg
                        self.after(0, lambda m=msg: self._log(m))
            except Exception as e:
                self.after(0, lambda err=e: self._log(f"轮询异常: {err}", True))
            time.sleep(0.5)

        # 超时后给出具体诊断
        try:
            ps = API.get_positions()
            pos_sym = [p for p in ps if p["symbol"] == sym]
        except Exception:
            pos_sym = []
        if not pos_sym:
            self.after(0, lambda: self._log(
                f"⚠️ 超时15s未找到 {sym} 持仓 — 可能限价单未成交，或者持仓量被过滤(<0.0001)。"
                f"请去 Binance 网页确认是否已成交，未成交请撤单后用市价重下", True))
        else:
            self.after(0, lambda: self._log(
                f"⚠️ 持仓存在但方向不匹配 {sym}: {pos_sym}", True))
        self.after(500, self._refresh_balances)

    def _place_tp_sl(self, tp):
        """根据真实入场均价挂止盈止损条件单"""
        try:
            ps = API.get_positions()
            if not ps:
                self._log("无法获取持仓，跳过止盈止损", True)
                return

            sym = tp["sym"]

            # 真实入场价 + 真实持仓数量（防止部分成交导致 TP/SL 数量错位）
            pos_l = next((p for p in ps
                          if p["side"] == "LONG"  and p["symbol"] == sym), None)
            pos_s = next((p for p in ps
                          if p["side"] == "SHORT" and p["symbol"] == sym), None)
            entry_l = pos_l["entry_price"] if pos_l else None
            entry_s = pos_s["entry_price"] if pos_s else None

            if entry_l is None and entry_s is None:
                self._log("❌ 未找到持仓，跳过止盈止损（防止用错价格）", True)
                return

            # 只对真实持仓的一边挂条件单，按各自平仓比例计算数量
            ql_full = pos_l["quantity"] if pos_l else 0
            qs_full = pos_s["quantity"] if pos_s else 0

            # 止盈/止损各自独立的平仓比例
            def _close_pct(var):
                try: return min(float(var.get() or 100), 100) / 100
                except: return 1.0
            tp_close = _close_pct(self.tp_close_pct_var)
            sl_close = _close_pct(self.sl_close_pct_var)

            if ql_full == 0 and qs_full == 0:
                self._log("❌ 持仓数量为 0，跳过止盈止损", True)
                return

            # 提示部分成交（实际持仓 < 计划数量）
            if pos_l and tp["ql"] > 0 and ql_full < tp["ql"] * 0.999:
                self._log(f"⚠️ 多单部分成交: 计划{tp['ql']:.4f} 实际{ql_full:.4f}")
            if pos_s and tp["qs"] > 0 and qs_full < tp["qs"] * 0.999:
                self._log(f"⚠️ 空单部分成交: 计划{tp['qs']:.4f} 实际{qs_full:.4f}")

            tp_pct = float(self.tp_pct_var.get() or 0)   # 保证金 %
            sl_pct = float(self.sl_pct_var.get() or 0)

            # TP 用普通限价单，SL 用条件单
            sl_use_limit = self.sl_type_var.get() == "限价"
            sl_type = "STOP" if sl_use_limit else "STOP_MARKET"

            # 入场单类型（用于费率推断）
            ent_l_lim = self.type_l_var.get() == "限价"
            ent_s_lim = self.type_s_var.get() == "限价"
            lev_l = tp.get("ll", 20)
            lev_s = tp.get("ls", 20)

            tp_orders = []  # 普通限价平仓单
            cond_orders = []  # 止损条件单

            def _cond(strat_type, side, pos_side, stop_px, qty, use_limit):
                o = {"symbol": sym, "side": side, "position_side": pos_side,
                     "strategy_type": strat_type, "stop_price": round(stop_px, 8),
                     "quantity": qty}
                if use_limit:
                    o["price"] = round(stop_px, 8)
                return o

            # ── 纯多 ──
            if ql_full > 0:
                if tp_pct > 0:
                    ql_tp = ql_full * tp_close
                    px = self._calc_tp_sl_price(entry_l, "LONG", tp_pct, lev_l,
                                                ent_l_lim, True, True)
                    tp_orders.append({"symbol": sym, "side": "SELL", "quantity": ql_tp,
                                       "position_side": "LONG", "order_type": "LIMIT",
                                       "price": px, "leverage": lev_l})
                    self._log(f"止盈(限价): 多单 ${px:.4f} "
                              f"平{ql_tp:.4f}/{ql_full:.4f} "
                              f"(目标 +{tp_pct:.0f}% 保证金)")
                if sl_pct > 0:
                    ql_sl = ql_full * sl_close
                    px = self._calc_tp_sl_price(entry_l, "LONG", sl_pct, lev_l,
                                                ent_l_lim, sl_use_limit, False)
                    cond_orders.append(_cond(sl_type, "SELL", "LONG",
                                             px, ql_sl, sl_use_limit))
                    self._log(f"止损({self.sl_type_var.get()}): 多单 ${px:.4f} "
                              f"平{ql_sl:.4f}/{ql_full:.4f} "
                              f"(目标 -{sl_pct:.0f}% 保证金)")

            # ── 纯空 ──
            if qs_full > 0:
                if tp_pct > 0:
                    qs_tp = qs_full * tp_close
                    px = self._calc_tp_sl_price(entry_s, "SHORT", tp_pct, lev_s,
                                                ent_s_lim, True, True)
                    tp_orders.append({"symbol": sym, "side": "BUY", "quantity": qs_tp,
                                       "position_side": "SHORT", "order_type": "LIMIT",
                                       "price": px, "leverage": lev_s})
                    self._log(f"止盈(限价): 空单 ${px:.4f} "
                              f"平{qs_tp:.4f}/{qs_full:.4f} "
                              f"(目标 +{tp_pct:.0f}% 保证金)")
                if sl_pct > 0:
                    qs_sl = qs_full * sl_close
                    px = self._calc_tp_sl_price(entry_s, "SHORT", sl_pct, lev_s,
                                                ent_s_lim, sl_use_limit, False)
                    cond_orders.append(_cond(sl_type, "BUY", "SHORT",
                                             px, qs_sl, sl_use_limit))
                    self._log(f"止损({self.sl_type_var.get()}): 空单 ${px:.4f} "
                              f"平{qs_sl:.4f}/{qs_full:.4f} "
                              f"(目标 -{sl_pct:.0f}% 保证金)")

            # TP 普通限价单
            if tp_orders:
                r = API.place_order(tp_orders, "hedge")
                if r.get("error"):
                    self._log(f"止盈挂单失败: {r['error']}", True)
                else:
                    ok = sum(1 for d in r.get("details", []) if str(d.get("result", "")).isdigit())
                    self._log(f"止盈限价单: {ok}/{len(tp_orders)} 成功")

            # SL 条件单
            if cond_orders:
                r = API.place_conditional_orders(cond_orders)
                ok = r.get("success", 0)
                total = r.get("total", len(cond_orders))
                self._log(f"止损条件单: {ok}/{total} 成功")
                for d in r.get("details", []):
                    if not d.get("ok", False):
                        self._log(f"  ❌ {d.get('strategy_type','?')} stopPx={d.get('stop_price','?')}: {d.get('result')}", True)
                if ok < total:
                    self._log("⚠️ 部分止损单失败", True)
        except Exception as e:
            self._log(f"挂止盈止损失败: {e}", True)

    # ==================== 数据刷新 ====================

    def _start_polling(self):
        def _loop():
            while self._running:
                self._fetch_ticker()
                time.sleep(3)
        def _bal_loop():
            while self._running:
                self._update_balances()
                time.sleep(10)
        def _pos_loop():
            while self._running:
                time.sleep(5)
                self._fetch_positions_and_orders()
        threading.Thread(target=_loop, daemon=True).start()
        threading.Thread(target=_bal_loop, daemon=True).start()
        threading.Thread(target=_pos_loop, daemon=True).start()

    def _fetch_ticker(self):
        t = API.get_ticker(self.current_symbol)
        if "error" not in t:
            self.after(0, lambda: self._apply_ticker(t))

    def _apply_ticker(self, t):
        p = t.get("price", 0)
        self.current_price = p
        self.bid1 = t.get("bid1", 0)
        self.ask1 = t.get("ask1", 0)
        self.tk_price.configure(text=f"{p:.4f}" if p < 10000 else f"{p:.2f}")
        chg = t.get("change_pct", 0)
        c   = "#22c55e" if chg >= 0 else "#ef4444"
        self.tk_change.configure(text=f"{chg:+.2f}%", text_color=c)
        self.tk_high.configure(text=f"{t.get('high', 0):.4f}")
        self.tk_low.configure(text=f"{t.get('low', 0):.4f}")
        self._update_pnl()

    def _update_balances(self):
        threading.Thread(target=self._fetch_balance,
                         args=(self.bal_toggle.get(),), daemon=True).start()

    def _refresh_balances(self):
        self._update_balances()

    def _fetch_balance(self, coin):
        try:
            bals = API.get_balances()
            self.after(0, lambda: self._apply_balances(bals, coin))
            a = API.get_account()
            self.after(0, lambda: self._apply_account(a))
        except Exception as e:
            self.after(0, lambda: self._log(f"余额获取失败: {e}", True))

    def _apply_balances(self, bals, coin):
        # 顶部按钮只控制显示文案；仓位计算永远用统一账户 totalAvailableBalance
        # （在 _apply_account 里会把 self.balance 覆盖成真实可开仓余额）
        if coin == "全部":
            total = sum(b.get("total", 0) for b in bals if isinstance(b, dict))
            self.bal_label.configure(text=f"总资产: {total:.4f}")
        else:
            b = next((b for b in bals if isinstance(b, dict) and b.get("asset") == coin), None)
            if b:
                self.bal_label.configure(
                    text=f"{b['asset']} 可用:{b.get('cross',0):.4f} UM:{b.get('um',0):.4f}")
        self._update_pnl()

    def _apply_account(self, a):
        if "error" in a: return
        # 真正能用来开仓的余额 — 统一账户 totalAvailableBalance
        avail = a.get("available") or a.get("balance") or 0
        if avail > 0:
            self.balance = avail
        up = a.get("unrealized_pnl", 0)
        c  = "#22c55e" if up >= 0 else "#ef4444"
        self.upnl_label.configure(text=f"PnL: {up:+.4f}", text_color=c)
        conn = a.get("connected", True)
        self.conn_label.configure(
            text="● 已连接" if conn else "● 断开",
            text_color="#22c55e" if conn else "#ef4444")
        self._update_pnl()  # balance 更新后重算仓位

    def _load_pairs(self):
        def _fetch():
            pairs = API.get_pairs()
            if not pairs:
                # 自动尝试重新加载精度
                self.after(0, lambda: self._log("币种列表为空，调用 reload_precisions 重试..."))
                r = API._req("/api/reload_precisions", "POST", {})
                if r.get("ok"):
                    self.after(0, lambda n=r.get("after",0):
                               self._log(f"✓ 精度重载成功: {n} 个", False))
                    pairs = API.get_pairs()
                else:
                    self.after(0, lambda: self._log(
                        f"❌ 精度重载失败 — 确认 Clash 代理 7897 + fapi 路由通畅。"
                        f"返回: {r}", True))
            if pairs:
                self.all_pairs = pairs
                self.after(0, lambda: self.pair_combo.configure(values=pairs))
                self.after(0, lambda n=len(pairs): self._log(f"币种列表已加载: {n} 个"))
        threading.Thread(target=_fetch, daemon=True).start()

    # ==================== 持仓 / 挂单 ====================

    def _refresh_positions_and_orders(self):
        threading.Thread(target=self._fetch_positions_and_orders, daemon=True).start()

    def _fetch_positions_and_orders(self):
        try:
            ps = API.get_positions()
        except Exception as e:
            ps = []
            self.after(0, lambda: self._log(f"持仓查询异常: {e}", True))
        try:
            normal = API.get_open_orders()
        except Exception:
            normal = []
        try:
            cond = API.get_conditional_orders()
        except Exception as e:
            cond = []
            self.after(0, lambda err=e: self._log(f"条件单查询异常: {err}", True))
        self.after(0, lambda: self._render_positions(ps))
        self.after(0, lambda: self._render_orders(normal, cond))

    def _render_positions(self, positions):
        for w in self.pos_container.winfo_children():
            w.destroy()
        self.pos_count_lbl.configure(text=str(len(positions)))
        if not positions:
            ctk.CTkLabel(self.pos_container, text="无持仓",
                         font=("SF Mono", 9), text_color="#64748b"
                         ).pack(pady=4)
            return
        # 标题
        hdr = ctk.CTkFrame(self.pos_container, fg_color="transparent")
        hdr.pack(fill="x", padx=2, pady=(2, 1))
        for txt, w in [("品种",70),("方向",50),("数量",70),("入场",70),
                       ("标记",70),("PnL",60),("杠杆",36),("操作",106)]:
            ctk.CTkLabel(hdr, text=txt, font=("SF Mono", 9),
                         text_color="#64748b", width=w, anchor="w"
                         ).pack(side="left", padx=1)

        for p in positions:
            row = ctk.CTkFrame(self.pos_container, fg_color="#1e293b")
            row.pack(fill="x", padx=2, pady=1)
            side_color = "#22c55e" if p["side"] == "LONG" else "#ef4444"
            pnl_color  = "#22c55e" if p["pnl"] >= 0 else "#ef4444"
            ctk.CTkLabel(row, text=p["symbol"], font=("SF Mono", 10),
                         width=70, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=p["side"], font=("SF Mono", 10, "bold"),
                         text_color=side_color, width=50, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=f"{p['quantity']:.4f}", font=("SF Mono", 10),
                         width=70, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=f"{p['entry_price']:.4f}", font=("SF Mono", 10),
                         width=70, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=f"{p['mark_price']:.4f}", font=("SF Mono", 10),
                         width=70, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=f"{p['pnl']:+.4f}", font=("SF Mono", 10),
                         text_color=pnl_color, width=60, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=f"{p['leverage']}x", font=("SF Mono", 10),
                         text_color="#64748b", width=36, anchor="w").pack(side="left", padx=1)
            # 平仓：市价(立即) + 限价(按标记价挂单)
            ctk.CTkButton(row, text="市价", width=44, height=20, font=("SF Mono", 9),
                          fg_color="#dc2626", hover_color="#b91c1c",
                          command=lambda s=p["symbol"], sd=p["side"], q=p["quantity"]:
                                  self._close_position(s, sd, q, "MARKET", None)
                          ).pack(side="left", padx=1)
            ctk.CTkButton(row, text="限价", width=44, height=20, font=("SF Mono", 9),
                          fg_color="#f59e0b", hover_color="#d97706",
                          command=lambda s=p["symbol"], sd=p["side"], q=p["quantity"],
                                          mp=p["mark_price"]:
                                  self._close_position_limit_dialog(s, sd, q, mp)
                          ).pack(side="left", padx=1)

    def _render_orders(self, normal, cond):
        for w in self.ord_container.winfo_children():
            w.destroy()
        total = len(normal) + len(cond)
        self.ord_count_lbl.configure(text=str(total))
        if total == 0:
            ctk.CTkLabel(self.ord_container, text="无挂单",
                         font=("SF Mono", 9), text_color="#64748b"
                         ).pack(pady=4)
            return
        # 标题
        hdr = ctk.CTkFrame(self.ord_container, fg_color="transparent")
        hdr.pack(fill="x", padx=2, pady=(2, 1))
        for txt, w in [("品种",70),("类型",110),("方向",90),("数量",70),
                       ("价格",66),("触发价",66),("",46)]:
            ctk.CTkLabel(hdr, text=txt, font=("SF Mono", 9),
                         text_color="#64748b", width=w, anchor="w"
                         ).pack(side="left", padx=1)

        def _row(o, is_cond):
            row = ctk.CTkFrame(self.ord_container, fg_color="#1e293b")
            row.pack(fill="x", padx=2, pady=1)
            side_color = "#22c55e" if o["side"] == "BUY" else "#ef4444"
            kind = (o.get("strategy_type") if is_cond else o.get("type")) or "-"
            stop = f"{o.get('stop_price',0):.4f}" if o.get("stop_price") else "-"
            px   = (f"{o.get('price',0):.4f}"
                    if o.get("price") else ("市价" if is_cond else "-"))
            ctk.CTkLabel(row, text=o["symbol"], font=("SF Mono", 10),
                         width=70, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=kind, font=("SF Mono", 9),
                         text_color="#cbd5e1", width=110, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=f"{o['side']} {o.get('position_side','')}",
                         font=("SF Mono", 9, "bold"), text_color=side_color,
                         width=90, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=f"{o.get('orig_qty',0):.4f}",
                         font=("SF Mono", 10), width=70, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=px, font=("SF Mono", 10),
                         width=66, anchor="w").pack(side="left", padx=1)
            ctk.CTkLabel(row, text=stop, font=("SF Mono", 10),
                         width=66, anchor="w").pack(side="left", padx=1)
            oid = o.get("strategy_id") if is_cond else o.get("order_id")
            ctk.CTkButton(row, text="撤", width=42, height=20, font=("SF Mono", 9),
                          fg_color="#334155", hover_color="#475569",
                          command=lambda s=o["symbol"], i=oid, c=is_cond: self._cancel_order(s, i, c)
                          ).pack(side="left", padx=1)

        for o in cond:   _row(o, True)
        for o in normal: _row(o, False)

    def _close_position(self, symbol, side, quantity, order_type="MARKET", price=None):
        """
        平仓 — order_type=MARKET 立即市价；LIMIT 按 price 挂限价
        """
        exit_side = "SELL" if side == "LONG" else "BUY"
        leg = {"symbol": symbol, "side": exit_side, "quantity": quantity,
               "position_side": side, "order_type": order_type, "price": price}
        kind = "市价" if order_type == "MARKET" else f"限价@{price}"
        def _do():
            r = API._req("/api/order", "POST",
                          {"legs": [leg], "mode": "close"})
            err = r.get("error")
            if err:
                self.after(0, lambda e=err: self._log(f"平仓({kind})失败: {e}", True))
            else:
                # 检查 details 里是否成功
                d0 = (r.get("details") or [{}])[0]
                rid = str(d0.get("result", ""))
                if rid.isdigit() or rid.startswith("sim_"):
                    self.after(0, lambda: self._log(f"✓ 平仓({kind}) {symbol} {side} {quantity}"))
                else:
                    self.after(0, lambda e=rid: self._log(f"平仓({kind})失败: {e[:80]}", True))
            self.after(500, self._refresh_balances)
            self.after(800, self._refresh_positions_and_orders)
        threading.Thread(target=_do, daemon=True).start()

    def _close_position_limit_dialog(self, symbol, side, quantity, mark_price):
        """限价平仓弹窗 — 让用户确认/修改价格"""
        dlg = ctk.CTkToplevel(self)
        dlg.title(f"限价平仓 {symbol}")
        dlg.geometry("320x180")
        dlg.transient(self)
        dlg.grab_set()

        info = (f"{symbol}  {side}  数量 {quantity:.4f}\n"
                f"标记价: {mark_price:.4f}")
        ctk.CTkLabel(dlg, text=info, font=("SF Mono", 11),
                     justify="left").pack(pady=(14, 4), padx=14, anchor="w")

        ctk.CTkLabel(dlg, text="限价", font=("SF Mono", 10),
                     text_color="gray").pack(anchor="w", padx=14)
        price_var = ctk.StringVar(value=f"{mark_price:.4f}")
        entry = ctk.CTkEntry(dlg, textvariable=price_var, font=("SF Mono", 12))
        entry.pack(fill="x", padx=14, pady=(2, 8))
        entry.focus_set()

        def _submit():
            try:
                px = float(price_var.get().strip())
            except ValueError:
                self._log("价格格式错误", True)
                return
            dlg.destroy()
            self._close_position(symbol, side, quantity, "LIMIT", px)

        bf = ctk.CTkFrame(dlg, fg_color="transparent")
        bf.pack(fill="x", padx=14, pady=(2, 12))
        ctk.CTkButton(bf, text="取消", fg_color="#334155",
                      hover_color="#475569", width=80,
                      command=dlg.destroy
                      ).pack(side="right", padx=(4,0))
        ctk.CTkButton(bf, text="挂限价单", fg_color="#f59e0b",
                      hover_color="#d97706", width=100,
                      command=_submit
                      ).pack(side="right")
        # 回车直接确认
        entry.bind("<Return>", lambda _: _submit())

    def _cancel_order(self, symbol, oid, is_cond):
        def _do():
            r = (API.cancel_conditional_order(symbol, oid) if is_cond
                 else API.cancel_order(symbol, oid))
            if r.get("success"):
                self.after(0, lambda: self._log(f"✓ 已撤 {symbol} {oid}"))
            else:
                self.after(0, lambda e=r.get("error","失败"): self._log(f"撤单失败: {e}", True))
            self.after(500, self._refresh_positions_and_orders)
        threading.Thread(target=_do, daemon=True).start()

    def _cancel_all_clicked(self):
        def _do():
            r = API.cancel_all()
            if r.get("error"):
                self.after(0, lambda e=r["error"]: self._log(f"全撤异常: {e}", True))
                return
            msg = (f"已撤 普通 {r.get('cancelled_normal',0)}/{r.get('total_normal',0)} | "
                   f"条件 {r.get('cancelled_conditional',0)}/{r.get('total_conditional',0)}")
            self.after(0, lambda m=msg: self._log(m))
            for e in r.get("errors", []) or []:
                self.after(0, lambda x=e: self._log(f"  ❌ {x}", True))
            self.after(500, self._refresh_positions_and_orders)
        threading.Thread(target=_do, daemon=True).start()

    def _log(self, msg, err=False):
        def _do():
            t = time.strftime("%H:%M:%S")
            tag = "ERR" if err else "INF"
            self.log_text.configure(state="normal")
            self.log_text.insert("end", f"[{t}] {tag}: {msg}\n")
            self.log_text.see("end")
            self.log_text.configure(state="disabled")
        if threading.current_thread() is threading.main_thread():
            _do()
        else:
            self.after(0, _do)

    def on_closing(self):
        self._running = False
        self.destroy()


if __name__ == "__main__":
    app = App()
    app.protocol("WM_DELETE_WINDOW", app.on_closing)
    app.mainloop()
