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

# --- Strategy mode ---
# "ai"      → Claude AI analyzes all indicators and decides
# "classic" → Rule-based RSI + EMA crossover only
STRATEGY_MODE = "ai"

# --- AI settings (used when STRATEGY_MODE = "ai") ---
# Set ANTHROPIC_API_KEY in environment: export ANTHROPIC_API_KEY=sk-ant-...
AI_MIN_CONFIDENCE = 65   # minimum AI confidence % to place a trade (0-100)

# --- Indicator settings (used by both modes) ---
RSI_PERIOD = 14
RSI_OVERBOUGHT = 70
RSI_OVERSOLD = 30
EMA_SHORT = 9
EMA_LONG = 21
BB_PERIOD = 20
BB_STD = 2.0
MACD_FAST = 12
MACD_SLOW = 26
MACD_SIGNAL = 9

HEADLESS = False         # True = no window, False = show browser
