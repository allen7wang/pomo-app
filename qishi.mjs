export const audioDirectory = '../qishi-meditation-web/audio/';
const lastKey = 'habitica-pomodoro-web:qishi-last';

export function randomPreset(presets, excludingId) {
  if (!presets?.length) return null;
  const pool = excludingId && presets.length > 1
    ? presets.filter(preset => preset.id !== excludingId)
    : presets;
  return pool[Math.floor(Math.random() * pool.length)] ?? null;
}

export function trackGain(trackVolume, userVolume) {
  const user = Math.min(1, Math.max(0, Number(userVolume) || 0));
  const track = Number(trackVolume);
  return Math.min(1, Math.max(0, (Number.isFinite(track) ? track / 100 : 0) * user));
}

export function audioURL(file, pageURL) {
  return new URL(`${audioDirectory}${encodeURIComponent(file)}`, pageURL).href;
}

export function createAmbient({ presets, pageURL, createAudio, remember, recall }) {
  let players = [];
  let scene = null;
  let sessionId = null;
  let pending = false;
  let paused = false;
  let generation = 0;
  let previewPlayers = [];
  let previewTimer = 0;
  const memory = remember ?? (id => { try { sessionStorage.setItem(lastKey, id); } catch { /* private mode */ } });
  const remembered = recall ?? (() => { try { return sessionStorage.getItem(lastKey); } catch { return null; } });

  function release(list) {
    for (const audio of list) {
      audio.pause();
      audio.removeAttribute('src');
      try { audio.load(); } catch { /* already detached */ }
    }
  }

  function playTracks(tracks, volume, owner, gen, isPreview) {
    const created = [];
    for (const track of tracks) {
      const audio = createAudio();
      audio.preload = 'auto';
      audio.trackVolume = track.volume;
      audio.volume = trackGain(track.volume, volume);
      audio.addEventListener('ended', () => {
        if (generation !== gen || !owner.includes(audio)) return;
        try { audio.currentTime = 0; } catch { /* not seekable yet */ }
        if (isPreview || !paused) audio.play().catch(() => {});
      });
      audio.src = audioURL(track.file, pageURL);
      owner.push(audio);
      created.push(audio);
      audio.play().catch(() => {});
    }
    return created;
  }

  function stopScene() {
    generation += 1;
    release(players);
    players = [];
    scene = null;
    sessionId = null;
    pending = false;
    paused = false;
  }

  function startScene(volume) {
    const preset = randomPreset(presets, remembered());
    if (!preset) return null;
    stopScene();
    const gen = generation;
    scene = preset;
    paused = false;
    pending = true;
    playTracks(preset.tracks, volume, players, gen, false);
    memory(preset.id);
    return preset;
  }

  return {
    get scene() { return scene; },
    prepare(intent) {
      if (!intent.enabled) return stopScene();
      if (intent.running) {
        if (sessionId && sessionId === intent.sessionId && players.length) {
          paused = false;
          for (const audio of players) audio.play().catch(() => {});
          return scene;
        }
        return startScene(intent.volume);
      }
      if (intent.sessionId && (sessionId === intent.sessionId || pending)) {
        paused = true;
        for (const audio of players) audio.pause();
        return scene;
      }
      stopScene();
      return null;
    },
    reconcile(intent) {
      if (!intent.enabled || intent.phase !== 'focus') return stopScene();
      if (intent.running) {
        if (pending || sessionId === intent.sessionId) {
          sessionId = intent.sessionId;
          pending = false;
          paused = false;
          for (const audio of players) audio.volume = trackGain(audio.trackVolume, intent.volume);
          return scene;
        }
        return startScene(intent.volume);
      }
      if (intent.sessionId && (sessionId === intent.sessionId || pending)) {
        sessionId = intent.sessionId;
        pending = false;
        paused = true;
        for (const audio of players) audio.pause();
        return scene;
      }
      stopScene();
      return null;
    },
    setVolume(volume) {
      for (const audio of players) audio.volume = trackGain(audio.trackVolume, volume);
    },
    preview(volume) {
      clearTimeout(previewTimer);
      release(previewPlayers);
      previewPlayers = [];
      const preset = randomPreset(presets, null);
      if (!preset) return null;
      const gen = generation;
      playTracks(preset.tracks, volume, previewPlayers, gen, true);
      previewTimer = setTimeout(() => {
        release(previewPlayers);
        previewPlayers = [];
      }, 4000);
      return preset;
    },
    stop() { stopScene(); },
  };
}
