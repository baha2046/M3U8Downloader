#!/bin/zsh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/.venv/bin/python" -m pip install -r requirements.txt
"$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/web_app.py"
