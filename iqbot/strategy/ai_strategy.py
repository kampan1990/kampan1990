"""
AI-powered strategy using Claude API.

Sends the latest indicator snapshot to Claude and asks for a trading decision.
Falls back to None (no trade) on any API error so the bot stays safe.
"""

import json
import logging
import os
from typing import Optional

import anthropic

from .base import BaseStrategy
from .indicators import compute_all

log = logging.getLogger("iqbot.strategy.ai")

_SYSTEM_PROMPT = """You are an expert trading analyst for binary options, digital options, and forex.
You receive a snapshot of technical indicators for the latest candle and must decide whether to trade.

Respond with ONLY valid JSON — no markdown, no explanation outside the JSON:
{
  "signal": "call" | "put" | "wait",
  "confidence": 0-100,
  "reason": "one concise sentence"
}

Rules:
- "call" = price likely to go UP
- "put" = price likely to go DOWN
- "wait" = unclear / risky — do not trade
- Only signal call/put when confidence >= 65
- Consider all indicators together, not individually
- When indicators conflict, prefer "wait"
"""


class AIStrategy(BaseStrategy):
    """
    Combines RSI, EMA, Bollinger Bands, and MACD into a single prompt,
    sends it to Claude, and returns the AI's decision.
    """

    def __init__(
        self,
        asset: str = "EURUSD",
        trade_type: str = "binary",
        rsi_period: int = 14,
        ema_short: int = 9,
        ema_long: int = 21,
        bb_period: int = 20,
        bb_std: float = 2.0,
        macd_fast: int = 12,
        macd_slow: int = 26,
        macd_signal: int = 9,
        min_confidence: int = 65,
        model: str = "claude-haiku-4-5-20251001",  # fast + cheap for frequent calls
    ):
        self.asset = asset
        self.trade_type = trade_type
        self.rsi_period = rsi_period
        self.ema_short = ema_short
        self.ema_long = ema_long
        self.bb_period = bb_period
        self.bb_std = bb_std
        self.macd_fast = macd_fast
        self.macd_slow = macd_slow
        self.macd_signal_period = macd_signal
        self.min_confidence = min_confidence
        self.model = model

        api_key = os.environ.get("ANTHROPIC_API_KEY") or ""
        if not api_key:
            raise EnvironmentError("ANTHROPIC_API_KEY environment variable is not set.")
        self._client = anthropic.Anthropic(api_key=api_key)

        # Minimum candles so all indicators are seeded
        self.min_candles = max(rsi_period + 1, ema_long, bb_period, macd_slow + macd_signal) + 10

    def analyze(self, candles: list[dict]) -> Optional[str]:
        if len(candles) < self.min_candles:
            log.debug("Not enough candles (%d < %d)", len(candles), self.min_candles)
            return None

        indicators = compute_all(
            candles,
            rsi_period=self.rsi_period,
            ema_short=self.ema_short,
            ema_long=self.ema_long,
            bb_period=self.bb_period,
            bb_std=self.bb_std,
            macd_fast=self.macd_fast,
            macd_slow=self.macd_slow,
            macd_signal=self.macd_signal_period,
        )
        if indicators is None:
            return None

        prompt = self._build_prompt(indicators)
        try:
            response = self._client.messages.create(
                model=self.model,
                max_tokens=256,
                system=_SYSTEM_PROMPT,
                messages=[{"role": "user", "content": prompt}],
            )
            raw = response.content[0].text.strip()
            return self._parse_response(raw)
        except Exception as exc:
            log.error("AI analysis failed: %s", exc)
            return None

    def _build_prompt(self, ind: dict) -> str:
        # EMA crossover direction
        ema_cross = "bullish" if ind["ema_short"] > ind["ema_long"] else "bearish"
        ema_crossed = (
            "just crossed UP" if ind["ema_short_prev"] <= ind["ema_long_prev"] and ind["ema_short"] > ind["ema_long"]
            else "just crossed DOWN" if ind["ema_short_prev"] >= ind["ema_long_prev"] and ind["ema_short"] < ind["ema_long"]
            else "no recent cross"
        )

        # BB position
        bb_width = ind["bb_upper"] - ind["bb_lower"]
        bb_pos = (ind["close"] - ind["bb_lower"]) / bb_width * 100 if bb_width > 0 else 50
        bb_zone = (
            "above upper band (overbought)" if ind["close"] > ind["bb_upper"]
            else "below lower band (oversold)" if ind["close"] < ind["bb_lower"]
            else f"{bb_pos:.0f}% within bands"
        )

        # MACD
        macd_cross = (
            "MACD crossed above signal (bullish)" if ind["macd_prev"] <= ind["macd_signal_prev"] and ind["macd"] > ind["macd_signal"]
            else "MACD crossed below signal (bearish)" if ind["macd_prev"] >= ind["macd_signal_prev"] and ind["macd"] < ind["macd_signal"]
            else "no recent MACD cross"
        )

        return f"""Analyze this trading opportunity:

Asset: {self.asset} | Trade type: {self.trade_type}
Current price: {ind["close"]}

--- INDICATORS ---
RSI({self.rsi_period}): {ind["rsi"]} (prev: {ind["rsi_prev"]})
  → {"Oversold zone (<30)" if ind["rsi"] < 30 else "Overbought zone (>70)" if ind["rsi"] > 70 else "Neutral zone"}

EMA({self.ema_short}/{self.ema_long}): {ind["ema_short"]} / {ind["ema_long"]}
  → Trend: {ema_cross} | Crossover: {ema_crossed}

Bollinger Bands({self.bb_period}): upper={ind["bb_upper"]} mid={ind["bb_mid"]} lower={ind["bb_lower"]}
  → Price position: {bb_zone}

MACD({self.macd_fast}/{self.macd_slow}/{self.macd_signal_period}): {ind["macd"]} | Signal: {ind["macd_signal"]} | Histogram: {ind["macd_hist"]}
  → {macd_cross}

Based on ALL indicators above, what is your trading signal?"""

    def _parse_response(self, raw: str) -> Optional[str]:
        try:
            # Strip markdown code blocks if present
            text = raw.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
            data = json.loads(text)
            signal = data.get("signal", "wait").lower()
            confidence = int(data.get("confidence", 0))
            reason = data.get("reason", "")

            log.info(
                "AI decision: signal=%s confidence=%d reason=%s",
                signal, confidence, reason,
            )

            if signal in ("call", "put") and confidence >= self.min_confidence:
                return signal
            return None
        except Exception as exc:
            log.error("Failed to parse AI response '%s': %s", raw, exc)
            return None
