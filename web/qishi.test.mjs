import assert from 'node:assert/strict';
import test from 'node:test';
import { audioURL, createAmbient, randomPreset, trackGain } from './qishi.mjs';

test('random scene avoids the previous one when another exists', () => {
  const presets = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];
  for (let i = 0; i < 40; i += 1) assert.notEqual(randomPreset(presets, 'a').id, 'a');
  assert.equal(randomPreset([{ id: 'only' }], 'only').id, 'only');
  assert.equal(randomPreset([], 'a'), null);
});

test('track gain is preset ratio times user volume', () => {
  assert.equal(trackGain(50, 0.4), 0.2);
  assert.equal(trackGain(80, 2), 0.8);
  assert.equal(trackGain(0, 1), 0);
});

test('audio stays on the private site beside this app', () => {
  const url = audioURL('fallen-leaf-rain.mp3', 'https://workbench.example.test/habitica-pomodoro-web/');
  assert.equal(url, 'https://workbench.example.test/qishi-meditation-web/audio/fallen-leaf-rain.mp3');
});

test('pause keeps the scene and the next focus does not repeat it', () => {
  const made = [];
  const remembered = [];
  const ambient = createAmbient({
    presets: [{ id: 'a', name: '甲', tracks: [{ file: 'a.mp3', volume: 50 }] }, { id: 'b', name: '乙', tracks: [{ file: 'b.mp3', volume: 40 }] }],
    pageURL: 'https://example.test/habitica-pomodoro-web/',
    createAudio: () => {
      const audio = {
        preload: '', volume: 1, src: '', paused: true, trackVolume: 0,
        play() { this.paused = false; return Promise.resolve(); },
        pause() { this.paused = true; },
        removeAttribute() { this.src = ''; },
        load() {},
        addEventListener() {},
      };
      made.push(audio);
      return audio;
    },
    remember: id => remembered.push(id),
    recall: () => remembered.at(-1) ?? null,
  });
  const first = ambient.prepare({ enabled: true, running: true, sessionId: null, volume: 0.5 });
  ambient.reconcile({ enabled: true, running: true, phase: 'focus', sessionId: 's1', volume: 0.5 });
  ambient.prepare({ enabled: true, running: false, sessionId: 's1', volume: 0.5 });
  assert.equal(made[0].paused, true);
  assert.equal(ambient.scene.id, first.id);
  ambient.prepare({ enabled: true, running: true, sessionId: 's1', volume: 0.5 });
  assert.equal(made.length, 1);
  assert.equal(made[0].paused, false);
  ambient.reconcile({ enabled: true, running: false, phase: 'short', sessionId: null, volume: 0.5 });
  const second = ambient.prepare({ enabled: true, running: true, sessionId: null, volume: 0.5 });
  assert.notEqual(second.id, first.id);
});
