import logging

logger = logging.getLogger(__name__)


class RiskManager:
    """
    Tracks session P&L and enforces two hard stops:
      1. Session loss limit  (MAX_LOSS_SESSION)
      2. Trade count limit   (MAX_TRADES)
    """

    def __init__(self, max_loss: float, max_trades: int):
        self.max_loss = max_loss      # e.g. 20.0 means stop if we lose $20
        self.max_trades = max_trades

        self.session_pnl = 0.0
        self.trades_placed = 0
        self.wins = 0
        self.losses = 0

    # ------------------------------------------------------------------
    # Pre-trade gate
    # ------------------------------------------------------------------

    def can_trade(self) -> bool:
        if self.trades_placed >= self.max_trades:
            logger.warning(
                "Trade limit reached (%d/%d). Stopping.", self.trades_placed, self.max_trades
            )
            return False

        if self.session_pnl <= -self.max_loss:
            logger.warning(
                "Session loss limit reached (P&L=%.2f, limit=-%.2f). Stopping.",
                self.session_pnl, self.max_loss,
            )
            return False

        return True

    # ------------------------------------------------------------------
    # Post-trade update
    # ------------------------------------------------------------------

    def record_trade(self, pnl: float) -> None:
        """
        Call this after a trade result is known.
        pnl > 0 = win, pnl < 0 = loss.
        """
        self.session_pnl += pnl
        self.trades_placed += 1

        if pnl > 0:
            self.wins += 1
        else:
            self.losses += 1

        logger.info(
            "Trade recorded: pnl=%.2f | session_pnl=%.2f | W:%d L:%d",
            pnl, self.session_pnl, self.wins, self.losses,
        )

    # ------------------------------------------------------------------
    # Reporting
    # ------------------------------------------------------------------

    def summary(self) -> dict:
        total = self.wins + self.losses
        win_rate = (self.wins / total * 100) if total else 0.0
        return {
            "trades": total,
            "wins": self.wins,
            "losses": self.losses,
            "win_rate_pct": round(win_rate, 1),
            "session_pnl": round(self.session_pnl, 2),
        }
