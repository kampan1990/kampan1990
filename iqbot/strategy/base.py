from abc import ABC, abstractmethod
from typing import Optional


class BaseStrategy(ABC):
    """
    All strategies must implement analyze() and return one of:
    "call", "put", or None (no trade signal).
    """

    @abstractmethod
    def analyze(self, candles: list[dict]) -> Optional[str]:
        """
        Receive a list of candle dicts with keys:
            open, high, low, close, volume, timestamp

        Return "call", "put", or None.
        """
        ...

    def _closes(self, candles: list[dict]) -> list[float]:
        return [c["close"] for c in candles]
