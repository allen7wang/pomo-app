// Pure helpers for the extension's Qishi random-scene ambient.
// Service worker loads this via importScripts. Node can require() it for checks.

function randomQishiPreset(presets, excludingId) {
    if (!presets || !presets.length) return null;
    var pool = presets;
    if (excludingId && presets.length > 1) {
        pool = presets.filter(function (preset) { return preset.id !== excludingId; });
    }
    if (!pool.length) return null;
    return pool[Math.floor(Math.random() * pool.length)];
}

function qishiTrackGain(trackVolume, userVolume) {
    var user = Math.min(1, Math.max(0, Number(userVolume) || 0));
    var track = Number(trackVolume);
    var ratio = isFinite(track) ? track / 100 : 0;
    return Math.min(1, Math.max(0, ratio * user));
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        randomQishiPreset: randomQishiPreset,
        qishiTrackGain: qishiTrackGain
    };
}
