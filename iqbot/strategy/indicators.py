"""
Pure-Python technical indicators: EMA, RSI, Bollinger Bands, MACD.
No external dependencies required.
"""

from typing import Optional


def ema(values: list[float], period: int) -> list[float]:
    if len(values) < period:
        return []
    k = 2 / (period + 1)
    result = [sum(values[:period]) / period]
    for price in values[period:]:
        result.append(price * k + result[-1] * (1 - k))
    return result


def rsi(closes: list[float], period: int = 14) -> list[float]:
    if len(closes) < period + 1:
        return []
    gains, losses = [], []
    for i in range(1, len(closes)):
        delta = closes[i] - closes[i - 1]
        gains.append(max(delta, 0.0))
        losses.append(max(-delta, 0.0))

    avg_gain = sum(gains[:period]) / period
    avg_loss = sum(losses[:period]) / period
    result = []
    for i in range(period, len(gains)):
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period
        if avg_loss == 0:
            result.append(100.0)
        else:
            rs = avg_gain / avg_loss
            result.append(100 - 100 / (1 + rs))
    return result


def bollinger_bands(
    closes: list[float], period: int = 20, num_std: float = 2.0
) -> tuple[list[float], list[float], list[float]]:
    """Returns (upper, middle, lower) bands aligned to closes[period-1:]."""
    if len(closes) < period:
        return [], [], []
    middle, upper, lower = [], [], []
    for i in range(period - 1, len(closes)):
        window = closes[i - period + 1 : i + 1]
        mean = sum(window) / period
        variance = sum((x - mean) ** 2 for x in window) / period
        std = variance ** 0.5
        middle.append(mean)
        upper.append(mean + num_std * std)
        lower.append(mean - num_std * std)
    return upper, middle, lower


def macd(
    closes: list[float],
    fast: int = 12,
    slow: int = 26,
    signal_period: int = 9,
) -> tuple[list[float], list[float], list[float]]:
    """
    Returns (macd_line, signal_line, histogram) — all aligned to the
    shortest series (determined by the slow EMA + signal_period).
    """
    ema_fast = ema(closes, fast)
    ema_slow = ema(closes, slow)

    # Align: ema_fast is longer; trim to match ema_slow length
    offset = len(ema_fast) - len(ema_slow)
    ema_fast_aligned = ema_fast[offset:]

    macd_line = [f - s for f, s in zip(ema_fast_aligned, ema_slow)]
    signal_line = ema(macd_line, signal_period)

    # Align macd_line to signal_line
    macd_offset = len(macd_line) - len(signal_line)
    macd_aligned = macd_line[macd_offset:]

    histogram = [m - s for m, s in zip(macd_aligned, signal_line)]
    return macd_aligned, signal_line, histogram


def compute_all(
    candles: list[dict],
    rsi_period: int = 14,
    ema_short: int = 9,
    ema_long: int = 21,
    bb_period: int = 20,
    bb_std: float = 2.0,
    macd_fast: int = 12,
    macd_slow: int = 26,
    macd_signal: int = 9,
) -> Optional[dict]:
    """
    Compute all indicators from candles and return the latest values as a dict.
    Returns None if there are not enough candles.
    """
    closes = [c["close"] for c in candles]
    highs = [c["high"] for c in candles]
    lows = [c["low"] for c in candles]

    rsi_vals = rsi(closes, rsi_period)
    ema_s = ema(closes, ema_short)
    ema_l = ema(closes, ema_long)
    bb_upper, bb_mid, bb_lower = bollinger_bands(closes, bb_period, bb_std)
    macd_line, signal_line, histogram = macd(closes, macd_fast, macd_slow, macd_signal)

    # Need at least 2 values in every series to detect crossovers
    if any(
        len(s) < 2
        for s in [rsi_vals, ema_s, ema_l, bb_upper, macd_line, signal_line, histogram]
    ):
        return None

    return {
        "close": closes[-1],
        "high": highs[-1],
        "low": lows[-1],
        "rsi": round(rsi_vals[-1], 2),
        "rsi_prev": round(rsi_vals[-2], 2),
        "ema_short": round(ema_s[-1], 6),
        "ema_short_prev": round(ema_s[-2], 6),
        "ema_long": round(ema_l[-1], 6),
        "ema_long_prev": round(ema_l[-2], 6),
        "bb_upper": round(bb_upper[-1], 6),
        "bb_mid": round(bb_mid[-1], 6),
        "bb_lower": round(bb_lower[-1], 6),
        "macd": round(macd_line[-1], 6),
        "macd_prev": round(macd_line[-2], 6),
        "macd_signal": round(signal_line[-1], 6),
        "macd_signal_prev": round(signal_line[-2], 6),
        "macd_hist": round(histogram[-1], 6),
        "macd_hist_prev": round(histogram[-2], 6),
    }
