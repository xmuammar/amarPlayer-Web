export const FREQUENCIES = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

export const PRESETS = {
  Flat:   [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  Bass:   [6, 5, 4, 2, 1, 0, -1, -1, -1, -1],
  Rock:   [4, 3, 1, -1, -2, 1, 3, 4, 4, 3],
  Pop:    [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2],
  Vocal:  [-3, -2, -1, 1, 3, 5, 5, 3, 1, -1],
  Treble: [-2, -2, -1, 0, 1, 2, 4, 5, 6, 6],
};

export class AudioEngine {
  constructor(audio) {
    this.audio = audio;
    this.context = null;
    this.source = null;
    this.filters = [];
    this.analyser = null;
    this.values = [...PRESETS.Flat];
  }

  async init() {
    if (this.context) {
      if (this.context.state === "suspended") await this.context.resume();
      return;
    }

    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) throw new Error("Web Audio API tidak didukung browser ini.");

    this.context = new AudioContext();
    this.source = this.context.createMediaElementSource(this.audio);

    this.filters = FREQUENCIES.map((frequency, index) => {
      const filter = this.context.createBiquadFilter();
      filter.type = "peaking";
      filter.frequency.value = frequency;
      filter.Q.value = 1.15;
      filter.gain.value = this.values[index];
      return filter;
    });

    this.analyser = this.context.createAnalyser();
    this.analyser.fftSize = 256;
    this.analyser.smoothingTimeConstant = 0.82;

    let node = this.source;
    for (const filter of this.filters) {
      node.connect(filter);
      node = filter;
    }
    node.connect(this.analyser);
    this.analyser.connect(this.context.destination);

    await this.context.resume();
  }

  async resume() {
    await this.init();
    if (this.context.state === "suspended") await this.context.resume();
  }

  async setBand(index, gain) {
    this.values[index] = Number(gain);
    await this.init();
    this.filters[index].gain.setTargetAtTime(Number(gain), this.context.currentTime, 0.01);
  }

  async applyValues(values) {
    this.values = values.map(Number);
    await this.init();
    this.values.forEach((gain, index) => {
      this.filters[index].gain.setTargetAtTime(gain, this.context.currentTime, 0.01);
    });
  }

  frequencyData() {
    if (!this.analyser) return null;
    const data = new Uint8Array(this.analyser.frequencyBinCount);
    this.analyser.getByteFrequencyData(data);
    return data;
  }
}
