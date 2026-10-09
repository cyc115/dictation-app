import sys
from pathlib import Path

# Lets tests import the suite modules (harness, suites.*) the way bench/suite.py does.
sys.path.insert(0, str(Path(__file__).resolve().parent))
