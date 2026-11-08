"""Select the newest available iPhone simulator running iOS 18.6 or later."""

import json
import sys

RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.iOS-"
IPHONE_PREFIX = "com.apple.CoreSimulator.SimDeviceType.iPhone-"
MINIMUM_IOS_VERSION = (18, 6)


def select_iphone_simulator(simulators):
    candidates = []
    for runtime in simulators["runtimes"]:
        identifier = runtime["identifier"]
        if not runtime["isAvailable"] or not identifier.startswith(RUNTIME_PREFIX):
            continue
        version = tuple(int(part) for part in runtime["version"].split("."))
        if version < MINIMUM_IOS_VERSION:
            continue
        for device in simulators["devices"].get(identifier, []):
            if device["isAvailable"] and device["deviceTypeIdentifier"].startswith(IPHONE_PREFIX):
                candidates.append((version, device["state"] == "Booted", device["udid"]))

    if not candidates:
        raise SystemExit("No iOS 18.6+ iPhone simulator is available.")
    return max(candidates)[2]


if __name__ == "__main__":
    print(select_iphone_simulator(json.load(sys.stdin)))
