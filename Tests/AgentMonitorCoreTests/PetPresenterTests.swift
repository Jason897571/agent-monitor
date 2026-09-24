import Foundation
import Testing

@testable import AgentMonitorCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func presenter(fade: FadePolicy = .default) -> PetPresenter {
    PetPresenter(fadePolicy: fade)
}

@Suite("pet poses")
struct PetPoseTests {

    @Test("no sessions means sleeping")
    func dormantSleeps() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        #expect(presenter.presentation(now: t0).pose == .sleeping)
    }

    @Test("a working agent means working")
    func busyWorks() {
        var presenter = presenter()
        presenter.observe(aggregate: .active(.busy), attention: .ignore, now: t0)
        // Skip past the waking animation.
        #expect(presenter.presentation(now: t0.addingTimeInterval(5)).pose == .working)
    }

    @Test("a blocked agent means alert")
    func waitingAlerts() {
        var presenter = presenter()
        presenter.observe(aggregate: .active(.waiting), attention: .interrupt, now: t0)
        #expect(presenter.presentation(now: t0.addingTimeInterval(5)).pose == .alert)
    }

    /// An idle agent is worth looking at only once the ladder says so — and stops being
    /// worth looking at again when the ladder decays.
    @Test("idle follows the attention ladder rather than a clock of its own")
    func idleFollowsLadder() {
        var quiet = presenter()
        quiet.observe(aggregate: .active(.idle), attention: .changeBlind, now: t0)
        #expect(quiet.presentation(now: t0.addingTimeInterval(5)).pose == .resting)

        var noticed = presenter()
        noticed.observe(aggregate: .active(.idle), attention: .makeAware, now: t0)
        #expect(noticed.presentation(now: t0.addingTimeInterval(5)).pose == .attentive)
    }

    @Test("leaving dormant plays a waking animation, then settles")
    func wakingThenSettles() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        presenter.observe(aggregate: .active(.busy), attention: .ignore, now: t0.addingTimeInterval(10))

        #expect(presenter.presentation(now: t0.addingTimeInterval(10)).pose == .waking)
        #expect(presenter.presentation(now: t0.addingTimeInterval(10.5)).pose == .waking)
        #expect(presenter.presentation(now: t0.addingTimeInterval(12)).pose == .working)
    }

    /// Going busy → idle → busy is not "waking"; only coming back from dormant is.
    @Test("state changes between live sessions do not replay the wake animation")
    func noSpuriousWaking() {
        var presenter = presenter()
        presenter.observe(aggregate: .active(.busy), attention: .ignore, now: t0)
        presenter.observe(aggregate: .active(.idle), attention: .changeBlind, now: t0.addingTimeInterval(30))
        #expect(presenter.presentation(now: t0.addingTimeInterval(30)).pose == .resting)
    }
}

@Suite("fading")
struct PetFadeTests {

    /// THE RED LINE. `idle` means an agent is waiting on *you*; fading it would hide
    /// the one state the user actually needs to see. If this test ever fails, the fade
    /// condition has been loosened from "is dormant" to something pose-shaped.
    @Test("a pet with live sessions never fades, no matter how long it sits")
    func liveSessionsNeverFade() {
        for state in SessionState.allCases {
            for attention in AttentionLevel.allCases {
                var presenter = presenter()
                presenter.observe(aggregate: .active(state), attention: attention, now: t0)
                let later = presenter.presentation(now: t0.addingTimeInterval(14 * 86_400))
                #expect(later.opacity == 1.0,
                        "state \(state) at \(attention) faded — fading must be dormant-only")
            }
        }
    }

    @Test("a sleeping pet fades after the delay, and not before")
    func dormantFadesAfterDelay() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)

        #expect(presenter.presentation(now: t0).opacity == 1.0)
        #expect(presenter.presentation(now: t0.addingTimeInterval(599)).opacity == 1.0)
        #expect(presenter.presentation(now: t0.addingTimeInterval(601)).opacity == 0.25)
    }

    /// Fading is not hiding: the pet stays put and stays reachable.
    @Test("fading never reaches invisible")
    func fadeNeverReachesZero() {
        let policy = FadePolicy(opacity: 0.0)
        #expect(policy.opacity > 0)
    }

    @Test("hovering restores it immediately")
    func hoverRestores() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        let faded = t0.addingTimeInterval(3600)
        #expect(presenter.presentation(now: faded).opacity == 0.25)
        #expect(presenter.presentation(now: faded, isHovered: true).opacity == 1.0)
    }

    @Test("waking up restores it immediately, without waiting for a fade-in")
    func wakingRestores() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        let faded = t0.addingTimeInterval(3600)
        #expect(presenter.presentation(now: faded).opacity == 0.25)

        presenter.observe(aggregate: .active(.busy), attention: .ignore, now: faded)
        #expect(presenter.presentation(now: faded).opacity == 1.0)
    }

    @Test("the fade can be switched off entirely")
    func fadeCanBeDisabled() {
        var presenter = presenter(fade: .never)
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        #expect(presenter.presentation(now: t0.addingTimeInterval(86_400)).opacity == 1.0)
    }

    @Test("falling asleep again restarts the fade clock")
    func fadeClockRestarts() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        presenter.observe(aggregate: .active(.busy), attention: .ignore, now: t0.addingTimeInterval(700))
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0.addingTimeInterval(800))
        // 700s after the *second* sleep, not 1500s after the first.
        #expect(presenter.presentation(now: t0.addingTimeInterval(1_200)).opacity == 1.0)
        #expect(presenter.presentation(now: t0.addingTimeInterval(1_500)).opacity == 0.25)
    }
}

@Suite("frame budget")
struct PetFrameRateTests {

    /// The energy contract: the most common state must also be the cheapest, and once
    /// faded there is nothing worth spending a frame on.
    @Test("a faded sleeping pet stops animating entirely")
    func fadedSleepPausesAnimation() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)

        let breathing = presenter.presentation(now: t0)
        #expect(breathing.pose == .sleeping)
        #expect(breathing.framesPerSecond == 2)

        let faded = presenter.presentation(now: t0.addingTimeInterval(3600))
        #expect(faded.framesPerSecond == 0)
        #expect(faded.isAnimating == false)
    }

    @Test("hovering a faded pet brings the animation back")
    func hoverResumesAnimation() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        let faded = t0.addingTimeInterval(3600)
        #expect(presenter.presentation(now: faded, isHovered: true).framesPerSecond > 0)
    }

    @Test("no pose asks for more than 24 fps")
    func frameRatesStayWithinBudget() {
        for state in SessionState.allCases {
            var presenter = presenter()
            presenter.observe(aggregate: .active(state), attention: .demandAttention, now: t0)
            let fps = presenter.presentation(now: t0.addingTimeInterval(5)).framesPerSecond
            #expect(fps <= 24, "\(state) asked for \(fps) fps")
        }
    }
}

@Suite("presentation scheduling")
struct PetSchedulingTests {

    @Test("a sleeping pet schedules its fade")
    func sleepSchedulesFade() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        let next = presenter.nextChange(now: t0)
        #expect(next == t0.addingTimeInterval(600))
    }

    /// The power lever: an already-faded pet with nothing pending must not keep a
    /// timer alive.
    @Test("a settled pet schedules nothing")
    func settledSchedulesNothing() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        #expect(presenter.nextChange(now: t0.addingTimeInterval(3600)) == nil)

        var working = presenter
        working.observe(aggregate: .active(.busy), attention: .ignore, now: t0)
        #expect(working.nextChange(now: t0.addingTimeInterval(60)) == nil)
    }

    @Test("waking schedules the end of its own animation")
    func wakingSchedulesSettle() {
        var presenter = presenter()
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        presenter.observe(aggregate: .active(.busy), attention: .ignore, now: t0.addingTimeInterval(10))
        let next = presenter.nextChange(now: t0.addingTimeInterval(10))
        #expect(next == t0.addingTimeInterval(11.2))
    }

    @Test("a disabled fade schedules nothing while asleep")
    func disabledFadeSchedulesNothing() {
        var presenter = presenter(fade: .never)
        presenter.observe(aggregate: .dormant, attention: .ignore, now: t0)
        #expect(presenter.nextChange(now: t0) == nil)
    }
}
