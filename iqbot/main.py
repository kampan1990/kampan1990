"""
IQ Option Trading Bot — main entry point.

Flow:
  1. Browser launches, logs in, switches to demo account.
  2. Main loop polls for candles every 30 seconds.
  3. Strategy analyzes candles → signal.
  4. Risk manager checks if we're within limits.
  5. Trade is placed, logged.
  6. After expiry, result is recorded (simplified: we compare balance delta).
"""

import asyncio
import logging
import sys

import config
from browser import BrowserManager
from logger import log_trade, update_trade_result
from risk_manager import RiskManager
from strategy import RsiEmaStrategy, AIStrategy

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("bot.log"),
    ],
)
log = logging.getLogger("iqbot.main")


# ---------------------------------------------------------------------------
# Helper: wait for trade expiry and record result
# ---------------------------------------------------------------------------
async def settle_trade(
    browser: BrowserManager,
    risk: RiskManager,
    trade_id: str,
    amount: float,
    direction: str,
    asset: str,
    trade_type: str,
    duration_min: int,
    balance_before: float,
) -> None:
    """
    Wait for the trade to expire, then compare the balance to determine
    win/loss. This is a practical approach when we don't have a direct
    result API.
    """
    await asyncio.sleep(duration_min * 60 + 5)  # wait expiry + small buffer

    try:
        balance_after = await browser.get_balance()
        pnl = balance_after - balance_before

        # For binary/digital the payout is ~80-95%; treat any positive delta as win.
        result = "win" if pnl > 0 else "loss"
        risk.record_trade(pnl)
        update_trade_result(trade_id, result, pnl, balance_after)

        log.info(
            "Trade settled: id=%s result=%s pnl=%.2f balance=%.2f",
            trade_id, result, pnl, balance_after,
        )
    except Exception as exc:
        log.error("Error settling trade %s: %s", trade_id, exc)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
async def run() -> None:
    browser = BrowserManager(headless=config.HEADLESS)
    await browser.start()

    if config.STRATEGY_MODE == "ai":
        log.info("Strategy: AI (Claude) with BB + MACD + RSI + EMA")
        strategy = AIStrategy(
            asset=asset,
            trade_type=config.TRADE_TYPE,
            rsi_period=config.RSI_PERIOD,
            ema_short=config.EMA_SHORT,
            ema_long=config.EMA_LONG,
            bb_period=config.BB_PERIOD,
            bb_std=config.BB_STD,
            macd_fast=config.MACD_FAST,
            macd_slow=config.MACD_SLOW,
            macd_signal=config.MACD_SIGNAL,
            min_confidence=config.AI_MIN_CONFIDENCE,
        )
    else:
        log.info("Strategy: Classic RSI + EMA crossover")
        strategy = RsiEmaStrategy(
            rsi_period=config.RSI_PERIOD,
            rsi_overbought=config.RSI_OVERBOUGHT,
            rsi_oversold=config.RSI_OVERSOLD,
            ema_short=config.EMA_SHORT,
            ema_long=config.EMA_LONG,
        )
    risk = RiskManager(
        max_loss=config.MAX_LOSS_SESSION,
        max_trades=config.MAX_TRADES,
    )

    asset = config.ASSETS[config.TRADE_TYPE]
    pending_settlements: list[asyncio.Task] = []

    try:
        # ----------------------------------------------------------------
        # Auth
        # ----------------------------------------------------------------
        log.info("Logging in as %s …", config.EMAIL)
        await browser.login(config.EMAIL, config.PASSWORD)

        if config.ACCOUNT_TYPE == "DEMO":
            await browser.switch_to_demo()

        log.info("Bot started. Trade type=%s asset=%s", config.TRADE_TYPE, asset)

        # ----------------------------------------------------------------
        # Trading loop
        # ----------------------------------------------------------------
        while risk.can_trade():
            try:
                candles = await browser.get_candles(asset, count=100)
                log.debug("Fetched %d candles for %s", len(candles), asset)

                signal = strategy.analyze(candles)

                if signal is None:
                    log.debug("No signal — waiting …")
                    await asyncio.sleep(30)
                    continue

                log.info("Signal: %s for %s", signal.upper(), asset)

                balance_before = await browser.get_balance()

                trade_id = await browser.place_trade(
                    direction=signal,
                    amount=config.TRADE_AMOUNT,
                    duration=config.DURATION,
                    trade_type=config.TRADE_TYPE,
                )

                if trade_id is None:
                    log.warning("Trade placement failed — skipping")
                    await asyncio.sleep(30)
                    continue

                # Log immediately as pending; we'll patch it after expiry
                log_trade(
                    asset=asset,
                    trade_type=config.TRADE_TYPE,
                    direction=signal,
                    amount=config.TRADE_AMOUNT,
                    duration_min=config.DURATION,
                    result="pending",
                    trade_id=trade_id,
                    balance_after=balance_before,
                )

                # Schedule settlement check without blocking the main loop
                task = asyncio.create_task(
                    settle_trade(
                        browser=browser,
                        risk=risk,
                        trade_id=trade_id,
                        amount=config.TRADE_AMOUNT,
                        direction=signal,
                        asset=asset,
                        trade_type=config.TRADE_TYPE,
                        duration_min=config.DURATION,
                        balance_before=balance_before,
                    )
                )
                pending_settlements.append(task)

                # Don't spam trades — wait for one candle (1 min) before next analysis
                await asyncio.sleep(config.DURATION * 60)

            except KeyboardInterrupt:
                raise
            except Exception as exc:
                log.error("Loop error: %s", exc, exc_info=True)
                await asyncio.sleep(10)

        log.info("Session ended. Summary: %s", risk.summary())

    finally:
        # Wait for any in-flight settlement tasks so the CSV is accurate
        if pending_settlements:
            log.info("Waiting for %d pending trade settlements …", len(pending_settlements))
            await asyncio.gather(*pending_settlements, return_exceptions=True)

        await browser.close()


def main() -> None:
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        log.info("Bot stopped by user.")


if __name__ == "__main__":
    main()
