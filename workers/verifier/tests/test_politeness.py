from verifier.politeness import HostThrottle


class FakeClock:
    def __init__(self):
        self.now = 100.0
        self.slept: list[float] = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds


def test_spaces_requests_to_the_same_host():
    clock = FakeClock()
    throttle = HostThrottle(5.0, clock=clock, sleep=clock.sleep)

    throttle.wait("acme.example")
    clock.now += 2.0
    throttle.wait("acme.example")

    assert clock.slept == [3.0]


def test_does_not_delay_a_different_host_or_a_host_already_rested():
    clock = FakeClock()
    throttle = HostThrottle(5.0, clock=clock, sleep=clock.sleep)

    throttle.wait("acme.example")
    throttle.wait("other.example")
    clock.now += 6.0
    throttle.wait("acme.example")

    assert clock.slept == []
