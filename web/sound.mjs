// End sounds and the single-track ambient loop. Only files packaged in ./audio are offered.
export const soundLabel = name => ({ None: '无', Chime: '合成提示音' })[name] ?? name.replace(/\.mp3$/, '');

export function soundURL(name, pageURL) {
  return new URL(`audio/${encodeURIComponent(name)}`, pageURL).href;
}

export function createSounds({ pageURL, createAudio = () => new Audio() }) {
  let context;
  let effect = null;
  let loop = null;
  let loopKey = '';
  let loopPaused = false;
  let previewTimer = 0;

  function chime(volume) {
    if (context?.state !== 'running') return;
    for (const [index, pitch] of [659, 880].entries()) {
      const start = context.currentTime + index * 0.16;
      const tone = context.createOscillator();
      const gain = context.createGain();
      tone.frequency.value = pitch;
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, 0.26 * volume), start + 0.04);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.38);
      tone.connect(gain).connect(context.destination);
      tone.start(start);
      tone.stop(start + 0.4);
    }
  }

  function release(audio) {
    if (!audio) return;
    audio.pause();
    audio.removeAttribute('src');
    try { audio.load(); } catch { /* already detached */ }
  }

  function stopLoop() {
    release(loop);
    loop = null;
    loopKey = '';
    loopPaused = false;
  }

  return {
    /** Must run inside a user gesture once so later sounds may play. */
    unlock() {
      try {
        const Context = globalThis.AudioContext || globalThis.webkitAudioContext;
        if (Context) {
          context ??= new Context();
          if (context.state === 'suspended') void context.resume().catch(() => {});
        }
      } catch { /* audio disabled */ }
    },
    play(name, volume, maxMs = 0) {
      clearTimeout(previewTimer);
      release(effect);
      effect = null;
      if (!name || name === 'None') return;
      if (name === 'Chime') return chime(volume);
      const audio = createAudio();
      audio.volume = Math.min(1, Math.max(0, volume));
      audio.src = soundURL(name, pageURL);
      audio.play().catch(() => {});
      effect = audio;
      if (maxMs) previewTimer = setTimeout(() => { if (effect === audio) { release(audio); effect = null; } }, maxMs);
    },
    stopPreview() {
      clearTimeout(previewTimer);
      release(effect);
      effect = null;
    },
    /** Loops `name` while a focus runs; pause keeps the position, anything else stops it. */
    reconcile({ name, volume, running, sessionId }) {
      if (!name || name === 'None' || !sessionId) return stopLoop();
      const key = `${sessionId}/${name}`;
      if (loopKey !== key) {
        stopLoop();
        if (!running) return;
        loop = createAudio();
        loop.loop = true;
        loop.src = soundURL(name, pageURL);
        loopKey = key;
        loopPaused = true;
      }
      loop.volume = Math.min(1, Math.max(0, volume));
      if (running && loopPaused) { loopPaused = false; loop.play().catch(() => {}); }
      else if (!running && !loopPaused) { loopPaused = true; loop.pause(); }
    },
    stopLoop,
  };
}
