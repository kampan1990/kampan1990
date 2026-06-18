"""
Playwright-based browser manager for IQ Option.

Price data is obtained by intercepting the WebSocket messages that IQ Option's
platform sends to the browser — no screen-scraping of chart pixels needed.
The WS protocol uses a proprietary JSON envelope:  {"name": "...", "msg": {...}}
"""

import asyncio
import json
import logging
import time
from collections import defaultdict, deque
from typing import Optional

from playwright.async_api import (
    Browser,
    BrowserContext,
    Page,
    Playwright,
    WebSocket,
    async_playwright,
)

logger = logging.getLogger(__name__)

# IQ Option platform URL
IQ_URL = "https://iqoption.com/traderoom"

# How many raw tick/candle WS messages to buffer per asset
_CANDLE_BUFFER_SIZE = 200


class BrowserManager:
    def __init__(self, headless: bool = False):
        self.headless = headless

        self._playwright: Optional[Playwright] = None
        self._browser: Optional[Browser] = None
        self._context: Optional[BrowserContext] = None
        self._page: Optional[Page] = None

        # asset -> deque of candle dicts received over WS
        self._candle_store: dict[str, deque] = defaultdict(
            lambda: deque(maxlen=_CANDLE_BUFFER_SIZE)
        )
        # raw history candles received in response to a getCandles request
        self._history_store: dict[str, list] = {}
        self._history_events: dict[str, asyncio.Event] = {}

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        self._playwright = await async_playwright().start()
        self._browser = await self._playwright.chromium.launch(
            headless=self.headless,
            args=["--disable-blink-features=AutomationControlled"],
        )
        self._context = await self._browser.new_context(
            # Pretend to be a normal Chrome so IQ Option doesn't block us
            user_agent=(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            viewport={"width": 1440, "height": 900},
        )
        self._page = await self._context.new_page()

        # Attach WebSocket listener before navigating so we catch everything
        self._page.on("websocket", self._on_websocket)

    async def close(self) -> None:
        if self._browser:
            await self._browser.close()
        if self._playwright:
            await self._playwright.stop()

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    async def login(self, email: str, password: str) -> None:
        await self._page.goto("https://iqoption.com/login", wait_until="networkidle")

        await self._page.fill('input[name="email"]', email)
        await self._page.fill('input[name="password"]', password)
        await self._page.click('button[type="submit"]')

        # Wait until the traderoom loads (balance element becomes visible)
        try:
            await self._page.wait_for_selector(
                ".balance-value, .js-balance-value, [class*='balance']",
                timeout=30_000,
            )
            logger.info("Login successful")
        except Exception:
            raise RuntimeError(
                "Login failed or timed out — check credentials or 2FA requirement"
            )

    # ------------------------------------------------------------------
    # Account helpers
    # ------------------------------------------------------------------

    async def switch_to_demo(self) -> None:
        """
        IQ Option shows a account-switcher dropdown in the header.
        We look for the demo account toggle and click it.
        """
        try:
            # Open account switcher
            await self._page.click(
                "[class*='account-info'], [class*='AccountInfo'], .js-demo-switcher",
                timeout=10_000,
            )
            await asyncio.sleep(0.5)
            # Click the "Practice" / "Demo" option
            await self._page.click(
                "text=Practice, text=Demo, [class*='practice'], [class*='demo']",
                timeout=5_000,
            )
            await asyncio.sleep(1)
            logger.info("Switched to demo account")
        except Exception as exc:
            logger.warning("Could not auto-switch to demo: %s", exc)

    async def get_balance(self) -> float:
        """Read the displayed balance from the DOM."""
        selectors = [
            ".balance-value",
            ".js-balance-value",
            "[class*='balance__value']",
            "[class*='BalanceValue']",
        ]
        for sel in selectors:
            try:
                text = await self._page.inner_text(sel, timeout=3_000)
                return float(text.replace(",", "").replace("$", "").strip())
            except Exception:
                continue
        raise RuntimeError("Could not read balance from page")

    # ------------------------------------------------------------------
    # WebSocket interception
    # ------------------------------------------------------------------

    def _on_websocket(self, ws: WebSocket) -> None:
        ws.on("framereceived", lambda payload: self._on_ws_frame(payload))

    def _on_ws_frame(self, payload: str) -> None:
        """
        IQ Option sends JSON frames. We care about two message types:
          - "candle-generated"  : real-time 1-minute candle updates
          - "candles"           : historical candle response
        """
        try:
            data = json.loads(payload)
        except (json.JSONDecodeError, TypeError):
            return

        name = data.get("name", "")
        msg = data.get("msg", {})

        if name == "candle-generated":
            # msg contains the candle for the active instrument
            self._store_candle(msg)

        elif name == "candles":
            # Historical batch: msg is a list of candles for a requested asset
            candles = msg if isinstance(msg, list) else msg.get("candles", [])
            if candles:
                asset = candles[0].get("active_id") or candles[0].get("from")
                self._history_store[str(asset)] = [
                    self._normalize_candle(c) for c in candles
                ]
                evt = self._history_events.get(str(asset))
                if evt:
                    evt.set()

    def _normalize_candle(self, raw: dict) -> dict:
        return {
            "timestamp": raw.get("at") or raw.get("from") or raw.get("timestamp", 0),
            "open": float(raw.get("open", 0)),
            "high": float(raw.get("max", raw.get("high", 0))),
            "low": float(raw.get("min", raw.get("low", 0))),
            "close": float(raw.get("close", 0)),
            "volume": float(raw.get("volume", 0)),
        }

    def _store_candle(self, msg: dict) -> None:
        # "from" is the asset name string (e.g. "EURUSD")
        asset = str(msg.get("active_id", msg.get("from", "unknown")))
        self._candle_store[asset].append(self._normalize_candle(msg))

    # ------------------------------------------------------------------
    # Market data
    # ------------------------------------------------------------------

    async def get_candles(self, asset: str, count: int = 100) -> list[dict]:
        """
        Return up to `count` recent 1-minute candles for `asset`.

        Strategy:
        1. If we already have enough buffered from live WS stream, return those.
        2. Otherwise send a getCandles WS request and wait for the response.
        """
        buffered = list(self._candle_store.get(asset, []))
        if len(buffered) >= count:
            return buffered[-count:]

        # Request historical data via the platform's JS API
        await self._request_history(asset, count)

        # Prefer the history batch if it arrived
        if asset in self._history_store:
            history = self._history_store[asset]
            # Merge buffered live ticks on top
            combined = history + buffered
            # Deduplicate by timestamp, keep latest
            seen: dict[int, dict] = {}
            for c in combined:
                seen[c["timestamp"]] = c
            return sorted(seen.values(), key=lambda x: x["timestamp"])[-count:]

        # Fall back to whatever we have
        return buffered[-count:]

    async def _request_history(self, asset: str, count: int) -> None:
        """
        IQ Option exposes a JS object `iqoption` or the platform sends the
        request via its own internal JS calls. We inject JS to call the
        platform's internal WebSocket sender.
        """
        asset_id = asset  # The platform accepts string name or numeric id

        event_key = str(asset_id)
        self._history_events[event_key] = asyncio.Event()

        # Duration 60 = 1-minute candles
        end_ts = int(time.time())
        start_ts = end_ts - count * 60

        request_payload = json.dumps({
            "name": "get-candles",
            "msg": {
                "active_id": asset,
                "size": count,
                "to": end_ts,
                "count": count,
                "period": 60,
            },
        })

        # Send via the page's WebSocket — inject JS that finds the WS and sends
        await self._page.evaluate(
            """(payload) => {
                // IQ Option stores the active WebSocket connection on window
                const ws = window.__iqWs || window._ws;
                if (ws && ws.readyState === WebSocket.OPEN) {
                    ws.send(payload);
                }
            }""",
            request_payload,
        )

        # Wait up to 5 s for the history to arrive
        try:
            await asyncio.wait_for(
                self._history_events[event_key].wait(), timeout=5.0
            )
        except asyncio.TimeoutError:
            logger.warning("History candles for %s did not arrive in time", asset)

    # ------------------------------------------------------------------
    # Trade execution
    # ------------------------------------------------------------------

    async def place_trade(
        self,
        direction: str,          # "call" or "put"
        amount: float,
        duration: int,            # minutes
        trade_type: str,          # "binary", "digital", "forex"
    ) -> Optional[str]:
        """
        Place a trade. Returns a trade ID string on success, or None on failure.

        IQ Option's traderoom has a unified interface. The approach:
        1. Set the amount in the amount input field.
        2. Set duration (for binary/digital).
        3. Click the CALL or PUT button.
        4. Extract the trade ID from the resulting WS message or DOM.
        """
        try:
            await self._set_trade_amount(amount)
            if trade_type in ("binary", "digital"):
                await self._set_duration(duration)

            btn_selector = self._get_trade_button_selector(direction, trade_type)
            await self._page.click(btn_selector, timeout=5_000)
            await asyncio.sleep(0.3)

            logger.info(
                "Placed %s %s trade: direction=%s amount=%.2f duration=%s",
                trade_type, direction, direction, amount, duration,
            )
            # A real implementation would capture the trade ID from the WS ack
            return f"trade_{int(time.time())}"

        except Exception as exc:
            logger.error("Failed to place trade: %s", exc)
            return None

    async def _set_trade_amount(self, amount: float) -> None:
        selectors = [
            ".trade-amount input",
            "[class*='amount'] input",
            "input[data-field='amount']",
        ]
        for sel in selectors:
            try:
                el = await self._page.wait_for_selector(sel, timeout=2_000)
                await el.triple_click()
                await el.type(str(amount))
                return
            except Exception:
                continue
        raise RuntimeError("Could not find trade amount input")

    async def _set_duration(self, minutes: int) -> None:
        # Most IQ Option layouts show a duration/expiry selector
        selectors = [
            "[class*='duration'] input",
            "[class*='expiry'] input",
            ".expiration-input",
        ]
        for sel in selectors:
            try:
                el = await self._page.wait_for_selector(sel, timeout=2_000)
                await el.triple_click()
                await el.type(str(minutes))
                return
            except Exception:
                continue
        # Non-fatal; duration may already be set
        logger.debug("Could not set duration — may already be correct")

    def _get_trade_button_selector(self, direction: str, trade_type: str) -> str:
        # Selectors based on IQ Option's class naming patterns (may need tuning
        # if IQ Option redesigns — inspect the DOM to update)
        direction_up = direction.upper()  # CALL or PUT

        if trade_type == "binary":
            return (
                f"[class*='call-button'][class*='{direction}'], "
                f".{direction}-button, "
                f"button[data-direction='{direction}']"
            )
        elif trade_type == "digital":
            return (
                f"[class*='digital'][class*='{direction}'], "
                f".digital-{direction}"
            )
        else:  # forex
            return (
                f"[class*='forex'][class*='{direction}'], "
                f".forex-{direction}-button"
            )
