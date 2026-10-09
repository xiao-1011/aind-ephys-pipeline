#!/usr/bin/env python3
"""Verify independent replay cache against previously pinned model hashes.

The recorded verification snapshots in model_provenance.json still refer to
the prior read-only KS4 test; the new HF cache is separately verified here.
"""

import argparse
import json
from pathlib import Path

import ks4_motion_trace_models as pinned

from dredge_trace_probe import TEST


def check_models(user_root):
    pinned.TEST = TEST
    return pinned.check_models(Path(user_root))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(check_models(args.user_root), indent=2), flush=True)
