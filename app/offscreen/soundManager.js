let currentAmbientAudio = null;
let ambientSampleTimeout = null;
let myAudio = null;

let qishiPlayers = [];
let qishiSceneId = null;
let qishiPaused = false;
let qishiGen = 0;
let qishiPreviewPlayers = [];
let qishiPreviewTimeout = null;
let qishiPreviewGen = 0;

const QISHI_STREAM_BASE = "https://allen7wang.github.io/qishi-meditation-web/audio/";

function qishiTrackGain(trackVolume, userVolume) {
    const user = Math.min(1, Math.max(0, Number(userVolume) || 0));
    const track = Number(trackVolume);
    const ratio = Number.isFinite(track) ? track / 100 : 0;
    return Math.min(1, Math.max(0, ratio * user));
}

function qishiUrls(file) {
    return [
        chrome.runtime.getURL("audio/qishi/" + file),
        QISHI_STREAM_BASE + encodeURIComponent(file)
    ];
}

function stopCustomAmbient() {
    myAudio?.pause();
    if (currentAmbientAudio instanceof Audio) {
        currentAmbientAudio.pause();
        currentAmbientAudio.currentTime = 0;
    }
}

function playSound(soundFileName, volume, loop) {
    if (soundFileName && soundFileName !== "None") {
        myAudio = new Audio(chrome.runtime.getURL("../audio/" + soundFileName));

        console.log(loop, myAudio?.src, currentAmbientAudio?.src, currentAmbientAudio?.src == myAudio?.src, currentAmbientAudio?.paused)

        if (loop && currentAmbientAudio?.src == myAudio?.src && !currentAmbientAudio?.paused) {
            return;
        }

        if (loop && currentAmbientAudio?.src !== myAudio?.src || currentAmbientAudio.paused) {
            stopAmbientSound();
            currentAmbientAudio = myAudio;
        }

        myAudio.volume = volume ?? 1;
        myAudio?.play();
    }
}

function releasePlayers(players) {
    for (const audio of players) {
        audio.pause();
        audio.removeAttribute("src");
        try { audio.load(); } catch (e) {}
    }
}

function stopQishiPlayers() {
    qishiGen += 1;
    const old = qishiPlayers;
    qishiPlayers = [];
    qishiSceneId = null;
    qishiPaused = false;
    releasePlayers(old);
}

function stopQishiPreview() {
    qishiPreviewGen += 1;
    clearTimeout(qishiPreviewTimeout);
    qishiPreviewTimeout = null;
    const old = qishiPreviewPlayers;
    qishiPreviewPlayers = [];
    releasePlayers(old);
}

function attachQishiAudio(audio, file, gen, players, isPreview) {
    const urls = qishiUrls(file);
    let index = 0;
    const stillOwned = () => (isPreview ? qishiPreviewGen === gen : qishiGen === gen) && players.includes(audio);
    audio.preload = "auto";
    audio.addEventListener("ended", () => {
        if (!stillOwned()) return;
        try { audio.currentTime = 0; } catch (e) {}
        if (isPreview || !qishiPaused) audio.play().catch(() => {});
    });
    audio.addEventListener("error", () => {
        if (!stillOwned()) return;
        index += 1;
        if (index < urls.length) {
            audio.src = urls[index];
            if (isPreview || !qishiPaused) audio.play().catch(() => {});
        }
    });
    audio.src = urls[0];
}

function playQishiScene(tracks, volume, sceneId) {
    if (qishiSceneId === sceneId && qishiPlayers.length && !qishiPaused) {
        setQishiVolume(volume);
        return;
    }
    if (qishiSceneId === sceneId && qishiPlayers.length && qishiPaused) {
        qishiPaused = false;
        setQishiVolume(volume);
        for (const audio of qishiPlayers) audio.play().catch(() => {});
        return;
    }
    stopCustomAmbient();
    stopQishiPlayers();
    const gen = qishiGen;
    qishiSceneId = sceneId;
    qishiPaused = false;
    for (const track of tracks || []) {
        if (!track || !track.file) continue;
        const audio = new Audio();
        audio.dataset.trackVolume = String(track.volume);
        audio.volume = qishiTrackGain(track.volume, volume);
        qishiPlayers.push(audio);
        attachQishiAudio(audio, track.file, gen, qishiPlayers, false);
        audio.play().catch(() => {});
    }
}

function pauseQishi() {
    qishiPaused = true;
    for (const audio of qishiPlayers) audio.pause();
}

function setQishiVolume(volume) {
    for (const audio of qishiPlayers) {
        audio.volume = qishiTrackGain(audio.dataset.trackVolume, volume);
    }
}

function playQishiPreview(tracks, volume) {
    stopQishiPreview();
    const gen = qishiPreviewGen;
    for (const track of tracks || []) {
        if (!track || !track.file) continue;
        const audio = new Audio();
        audio.volume = qishiTrackGain(track.volume, volume);
        qishiPreviewPlayers.push(audio);
        attachQishiAudio(audio, track.file, gen, qishiPreviewPlayers, true);
        audio.play().catch(() => {});
    }
    qishiPreviewTimeout = setTimeout(stopQishiPreview, 3000);
}

function stopAmbientSound() {
    stopCustomAmbient();
    stopQishiPlayers();
    stopQishiPreview();
}

function playAmbientSample(soundName, volume) {
    stopAmbientSound();
    clearTimeout(ambientSampleTimeout);
    setTimeout(() => {
        playSound(soundName, volume, true);
    }, 100);
    ambientSampleTimeout = setTimeout(() => {
        stopAmbientSound();
    }, 3000);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "playSound") {
        playSound(message.soundFileName, message.volume, message.loop);
        sendResponse({ success: true });
    } else if (message.type === "stopAmbientSound") {
        stopAmbientSound();
        sendResponse({ success: true });
    } else if (message.type === "playAmbientSample") {
        playAmbientSample(message.soundFileName, message.volume);
        sendResponse({ success: true });
    } else if (message.type === "playQishiScene") {
        playQishiScene(message.tracks, message.volume, message.sceneId);
        sendResponse({ success: true, sceneId: qishiSceneId });
    } else if (message.type === "pauseQishi") {
        pauseQishi();
        sendResponse({ success: true });
    } else if (message.type === "setQishiVolume") {
        setQishiVolume(message.volume);
        sendResponse({ success: true });
    } else if (message.type === "playQishiPreview") {
        playQishiPreview(message.tracks, message.volume);
        sendResponse({ success: true });
    } else if (message.type === "stopQishiPreview") {
        stopQishiPreview();
        sendResponse({ success: true });
    }
});
