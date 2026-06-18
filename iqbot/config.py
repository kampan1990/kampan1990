# All settings in one place

EMAIL = "your@email.com"
PASSWORD = "yourpassword"
ACCOUNT_TYPE = "DEMO"  # DEMO or REAL

TRADE_AMOUNT = 1.0       # $ per trade
MAX_LOSS_SESSION = 20.0  # stop bot if lose this much in session
MAX_TRADES = 50          # max trades per session

ASSETS = {
    "binary": "EURUSD-OTC",
    "digital": "EURUSD",
    "forex": "EURUSD"
}

TRADE_TYPE = "binary"    # binary, digital, forex
DURATION = 1             # minutes (for binary/digital)

RSI_PERIOD = 14
RSI_OVERBOUGHT = 70
RSI_OVERSOLD = 30
EMA_SHORT = 9
EMA_LONG = 21

HEADLESS = False         # True = no window, False = show browser
