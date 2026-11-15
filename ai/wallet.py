"""Load the testnet dev wallet from ../../dev-wallet.txt.

The file has no fixed label format, so extract by hex pattern: the 40-hex
token is the address, the 64-hex token is the private key. The key is only
ever passed to `cast send` as an argument inside this machine — it is never
printed or logged by any script in this project.
"""

import re
from pathlib import Path

WALLET_FILE = Path(__file__).resolve().parents[2] / "dev-wallet.txt"


def load_dev_wallet():
    text = WALLET_FILE.read_text()
    addr = re.search(r"0x[0-9a-fA-F]{40}", text)
    key = re.search(r"0x[0-9a-fA-F]{64}", text)
    if not addr or not key:
        raise RuntimeError("dev wallet not parseable")
    return addr.group(0), key.group(0)
