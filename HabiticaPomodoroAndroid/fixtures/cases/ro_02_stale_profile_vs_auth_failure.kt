// RO-02 (v2.1.4): an older role/profile response cannot undo a newer 401 from
// any feature, an older profile failure cannot replace that newer error, a
// profile refresh dispatched afterwards restores the role, and after A-B-A a
// retired profile response never overwrites the current account's role.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaGate

fun main() {
    val dir = newTempDir("ro-02")
    seedSettings(dir)
    seedTopThree(dir, ownedStore())
    val vm = newVm(dir) { installManualClock() }
    expect(vm.state.value.profile != null, "precondition: role loaded")

    // Older successful profile vs newer 401 from scoring.
    HabiticaAPI.profile = HabiticaAPI.profile.copy(level = 12)
    val slowProfile = HabiticaAPI.hold("fetchProfile")
    vm.refreshProfile()
    HabiticaAPI.replyFor = { name -> if (name.startsWith("scoreTask:")) reply(401) else null }
    vm.scoreHabiticaTask("habits", habitItem("rejected-score"), "up")
    expectEq(vm.state.value.profile, null, "the newer 401 revokes the role")
    expectEq(vm.state.value.profileError, HabiticaGate.AUTH_FAILED, "authentication failure shown")
    slowProfile.complete(Unit)
    expectEq(vm.state.value.profile, null, "the older profile success cannot restore it")
    expectEq(vm.state.value.profileError, HabiticaGate.AUTH_FAILED, "nor clear the authentication error")
    expectEq(vm.state.value.profileLoading, false, "loading indicator settles")

    // Older profile failure vs the newer authentication error.
    val failingProfile = HabiticaAPI.hold("fetchProfile")
    HabiticaAPI.replyFor = { name -> if (name == "fetchProfile") reply(500) else if (name.startsWith("scoreTask:")) reply(401) else null }
    vm.refreshProfile()
    vm.scoreHabiticaTask("habits", habitItem("rejected-again"), "up")
    failingProfile.complete(Unit)
    expectEq(vm.state.value.profileError, HabiticaGate.AUTH_FAILED, "an older HTTP 500 cannot replace the newer 401")

    // A newly dispatched successful profile refresh restores authentication and clears the error.
    HabiticaAPI.replyFor = { null }
    HabiticaAPI.profile = HabiticaAPI.profile.copy(level = 14)
    vm.refreshProfile()
    expectEq(vm.state.value.profile?.level, 14, "new profile adopted")
    expectEq(vm.state.value.profileError, null, "old error cleared by a request dispatched after it")

    // After A-B-A the retired profile response never overwrites the current role.
    HabiticaAPI.profile = HabiticaAPI.profile.copy(level = 1)
    val retired = HabiticaAPI.hold("fetchProfile")
    vm.refreshProfile()
    vm.updateSettings { it.copy(uid = OTHER_UID) }
    vm.updateSettings { it.copy(uid = FIXTURE_UID) }
    HabiticaAPI.profile = HabiticaAPI.profile.copy(level = 9)
    vm.refreshProfile()
    expectEq(vm.state.value.profile?.level, 9, "fresh connection loads its own role")
    retired.complete(Unit)
    expectEq(vm.state.value.profile?.level, 9, "retired profile response cannot overwrite it")
    expectEq(vm.state.value.profileError, null, "nor its status")
    println("RO-02 OK")
}
