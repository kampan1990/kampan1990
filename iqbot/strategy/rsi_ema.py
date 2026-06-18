from typing import Optional

from .base import BaseStrategy


def _ema(values: list[float], period: int) -> list[float]:
    """
    Exponential moving average. Uses SMA as seed for the first value
    so we don't need an external library.
    """
    if len(values) < period:
        return []

    k = 2 / (period + 1)
    # Seed with the first simple average
    result = [sum(values[:period]) / period]

    for price in values[period:]:
        result.append(price * k + result[-1] * (1 - k))

    return result


def _rsi(closes: list[float], period: int) -> list[float]:
    """
    Wilder's RSI. Returns a list aligned with closes[period:].
    We need at least period+1 data points.
    """
    if len(closes) < period + 1:
        return []

    gains, losses = [], []
    for i in range(1, len(closes)):
        delta = closes[i] - closes[i - 1]
        gains.append(max(delta, 0.0))
        losses.append(max(-delta, 0.0))

    # Seed averages with simple mean over first period
    avg_gain = sum(gains[:period]) / period
    avg_loss = sum(losses[:period]) / period

    rsi_values = []
    for i in range(period, len(gains)):
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period

        if avg_loss == 0:
            rsi_values.append(100.0)
        else:
            rs = avg_gain / avg_loss
            rsi_values.append(100 - 100 / (1 + rs))

    return rsi_values


class RsiEmaStrategy(BaseStrategy):
    """
    Signal logic:
      CALL  — RSI crosses up from oversold AND short EMA crosses above long EMA
      PUT   — RSI crosses down from overbought AND short EMA crosses below long EMA

    Both conditions must be true on the same candle to reduce false positives.
    """

    def __init__(
        self,
        rsi_period: int = 14,
        rsi_overbought: float = 70,
        rsi_oversold: float = 30,
        ema_short: int = 9,
        ema_long: int = 21,
    ):
        self.rsi_period = rsi_period
        self.rsi_overbought = rsi_overbought
        self.rsi_oversold = rsi_oversold
        self.ema_short = ema_short
        self.ema_long = ema_long

        # Minimum candles needed so all indicators are fully seeded
        self.min_candles = max(rsi_period + 1, ema_long) + 5

    def analyze(self, candles: list[dict]) -> Optional[str]:
        if len(candles) < self.min_candles:
            return None

        closes = self._closes(candles)

        rsi = _rsi(closes, self.rsi_period)
        ema_s = _ema(closes, self.ema_short)
        ema_l = _ema(closes, self.ema_long)

        # Align all series to the same ending index.
        # We need at least 2 values in each to detect a crossover.
        min_len = min(len(rsi), len(ema_s), len(ema_l))
        if min_len < 2:
            return None

        rsi_prev, rsi_cur = rsi[-2], rsi[-1]
        ema_s_prev, ema_s_cur = ema_s[-2], ema_s[-1]
        ema_l_prev, ema_l_cur = ema_l[-2], ema_l[-1]

        # EMA crossover: short crosses above long
        ema_bullish_cross = ema_s_prev <= ema_l_prev and ema_s_cur > ema_l_cur
        # RSI recovers from oversold
        rsi_bullish = rsi_prev < self.rsi_oversold and rsi_cur >= self.rsi_oversold

        # EMA crossover: short crosses below long
        ema_bearish_cross = ema_s_prev >= ema_l_prev and ema_s_cur < ema_l_cur
        # RSI drops from overbought
        rsi_bearish = rsi_prev > self.rsi_overbought and rsi_cur <= self.rsi_overbought

        if ema_bullish_cross and rsi_bullish:
            return "call"
        if ema_bearish_cross and rsi_bearish:
            return "put"

        return None
