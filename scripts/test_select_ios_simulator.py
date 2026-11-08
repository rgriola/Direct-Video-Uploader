import unittest

from select_ios_simulator import select_iphone_simulator


RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime."
DEVICE_PREFIX = "com.apple.CoreSimulator.SimDeviceType."


def runtime(identifier, version, available=True):
    return {
        "identifier": RUNTIME_PREFIX + identifier,
        "version": version,
        "isAvailable": available,
    }


def device(udid, device_type="iPhone-18", available=True, state="Shutdown"):
    return {
        "udid": udid,
        "deviceTypeIdentifier": DEVICE_PREFIX + device_type,
        "isAvailable": available,
        "state": state,
    }


def listing(*entries):
    return {
        "runtimes": [item[0] for item in entries],
        "devices": {item[0]["identifier"]: item[1] for item in entries},
    }


class SimulatorSelectionTests(unittest.TestCase):
    def test_device_specific_runtime_identifier_uses_runtime_version(self):
        simulators = listing(
            (runtime("iOS-27-2-iPhone19-4", "27.2"), [device("duo")]),
        )
        self.assertEqual(select_iphone_simulator(simulators), "duo")

    def test_newest_version_wins_over_device_suffix_and_booted_state(self):
        simulators = listing(
            (runtime("iOS-27-2-iPhone19-4", "27.2"), [device("duo", state="Booted")]),
            (runtime("iOS-27-3", "27.3"), [device("newer")]),
        )
        self.assertEqual(select_iphone_simulator(simulators), "newer")

    def test_booted_device_wins_when_versions_match(self):
        simulators = listing(
            (runtime("iOS-27-2", "27.2"), [device("z-shutdown")]),
            (runtime("iOS-27-2-iPhone19-4", "27.2"), [device("a-booted", state="Booted")]),
        )
        self.assertEqual(select_iphone_simulator(simulators), "a-booted")

    def test_version_components_are_compared_numerically(self):
        simulators = listing(
            (runtime("iOS-18-9", "18.9"), [device("older")]),
            (runtime("iOS-18-10", "18.10"), [device("newer")]),
        )
        self.assertEqual(select_iphone_simulator(simulators), "newer")

    def test_requires_available_iphone_and_supported_available_runtime(self):
        simulators = listing(
            (runtime("iOS-18-5", "18.5"), [device("too-old", state="Booted")]),
            (runtime("iOS-18-6", "18.6"), [device("supported")]),
            (
                runtime("iOS-27-0", "27.0"),
                [device("ipad", device_type="iPad-Pro"), device("unavailable", available=False)],
            ),
            (runtime("iOS-27-2", "27.2", available=False), [device("unavailable-runtime")]),
            (runtime("watchOS-27-2", "27.2"), [device("wrong-platform")]),
        )
        self.assertEqual(select_iphone_simulator(simulators), "supported")

    def test_fails_when_no_supported_iphone_is_available(self):
        simulators = listing(
            (runtime("iOS-18-5", "18.5"), [device("too-old")]),
            (runtime("iOS-27-0", "27.0"), [device("ipad", device_type="iPad-Pro")]),
        )
        with self.assertRaisesRegex(SystemExit, r"No iOS 18\.6\+ iPhone simulator"):
            select_iphone_simulator(simulators)

    def test_malformed_runtime_version_fails_explicitly(self):
        simulators = listing((runtime("iOS-27-2", "27.beta"), [device("invalid")]))
        with self.assertRaises(ValueError):
            select_iphone_simulator(simulators)


if __name__ == "__main__":
    unittest.main()
