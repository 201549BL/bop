export const restPose = { pitch: 0, roll: 0, yaw: 0, lift: 0 };

const fullTurn = 2 * Math.PI;
// These downbeats are measured from the Aya Higuchi recording, including its rubato.
const waltzDownbeats = [0.74, 2.265, 3.975, 5.295, 6.895, 8.22, 9.54, 11.16, 12.72];
const heavyBeatSeconds = 60 / 128;
const latinBeatSeconds = 60 / 95;
const grooveStart = -0.56;
const grooveEnd = 3;
const grooveVariations = [
  { strength: 1, lean: 1, timing: -0.05 },
  { strength: 0.91, lean: -1, timing: -0.07 },
  { strength: 1.08, lean: 0.72, timing: -0.025 },
];
// Align the first nods to the soft accents and fit 24 pulses in the excerpt.
const ambientFirstBeat = 4.81;
const ambientBeatSeconds = 5 / 9;
const ambientGrooveStart = ambientFirstBeat + grooveStart * ambientBeatSeconds;
const ambientGroove = seatedGroove({ firstBeat: ambientFirstBeat, beatSeconds: ambientBeatSeconds, depth: 0.18, sway: 0.036 });

export const demoSongs = {
  ambient: {
    title: "New Direction",
    artist: "Kevin MacLeod",
    ...ambientGroove,
    variations: [
      { ...grooveVariations[0], drowsiness: 1.24, curiosity: 0.62 },
      { ...grooveVariations[1], drowsiness: 0.55, curiosity: 1.25 },
      { ...grooveVariations[2], drowsiness: 0.8, curiosity: 1.55 },
    ],
    react(seconds, variation) {
      return seconds < ambientGrooveStart
        ? ambientIntro(seconds, variation)
        : ambientGroove.react(seconds, variation);
    },
    loopReaction(seconds, variation, established) {
      return !established && seconds < ambientGrooveStart
        ? ambientIntro(seconds, variation)
        : ambientGroove.loopReaction(seconds, variation, established);
    },
  },
  classical: {
    title: "Waltz in A minor",
    artist: "Frédéric Chopin · Aya Higuchi",
    ...seatedGroove({
      firstBeat: waltzDownbeats[1],
      beatSeconds: (waltzDownbeats[2] - waltzDownbeats[1]) / 3,
      beatAtTime: waltzBeat,
      phraseBeats: 6,
      depth: 0.195,
      sway: 0.042,
    }),
  },
  heavy: {
    title: "EDM Detection Mode",
    artist: "Kevin MacLeod",
    ...seatedGroove({ firstBeat: 0.008 + heavyBeatSeconds, beatSeconds: heavyBeatSeconds, depth: 0.31, sway: 0.026 }),
  },
  funk: {
    title: "Got Funk",
    artist: "Kevin MacLeod",
    ...seatedGroove({ firstBeat: 0.925, beatSeconds: 60 / 98, depth: 0.235, sway: 0.054 }),
  },
  rock: {
    title: "Feelin Good",
    artist: "Kevin MacLeod",
    ...seatedGroove({ firstBeat: 0.49, beatSeconds: 60 / 131, depth: 0.273, sway: 0.032 }),
  },
  latin: {
    title: "Carnivale Intrigue",
    artist: "Kevin MacLeod",
    ...seatedGroove({ firstBeat: 0.08 + latinBeatSeconds, beatSeconds: latinBeatSeconds, depth: 0.225, sway: 0.065 }),
  },
};

function ambientIntro(seconds, { lean, drowsiness, curiosity }) {
  const drowse = ease(seconds, 0.35, 3.8) * (1 - ease(seconds, 4.04, 4.32)) * drowsiness;
  const wake = gesture(seconds, 4.12, 4.32, ambientGrooveStart) * curiosity;
  return {
    pitch: 0.15 * drowse - 0.09 * wake,
    roll: (-0.12 * drowse + 0.055 * wake) * lean,
    yaw: 0.13 * wake * lean,
    lift: -0.019 * drowse + 0.016 * wake,
  };
}

export function tapPose(phase) {
  const perk = gesture(phase, 0, 0.13, 0.27);
  const nod = gesture(phase, 0.12, 0.33, 0.58);
  const recoil = gesture(phase, 0.43, 0.62, 0.89);
  return {
    pitch: -0.08 * perk + 0.33 * nod - 0.13 * recoil,
    roll: 0.09 * perk - 0.055 * nod + 0.08 * recoil,
    yaw: 0.095 * gesture(phase, 0.1, 0.45, 0.93),
    lift: 0.012 * perk - 0.026 * nod + 0.026 * recoil,
    frame: phase,
  };
}

function seatedGroove({
  firstBeat, beatSeconds, depth, sway, phraseBeats = 4,
  beatAtTime = (seconds) => (seconds - firstBeat) / beatSeconds,
}) {
  return {
    bopAtTime: firstBeat + grooveEnd * beatSeconds,
    loopBopAtTime: firstBeat + 2.65 * beatSeconds,
    variations: grooveVariations,
    react(seconds, { strength, lean, timing }) {
      const beats = beatAtTime(seconds);
      if (!Number.isFinite(beats) || beats < grooveStart) return restPose;

      const sinceStart = beats - grooveStart;
      const beat = sinceStart % phraseBeats + grooveStart;
      if (beat >= grooveEnd) return restPose;

      const envelope = ease(beat, grooveStart, -0.19) * (1 - ease(beat, 2.15, 2.63));
      const rebound = gesture(beat, 2.33, 2.69, grooveEnd);
      const pitch = depth * strength * grooveEngagement(beat) * envelope * seatedDip(beat - timing) - 0.034 * rebound;
      const direction = Math.floor(sinceStart / phraseBeats) % 2 === 0 ? lean : -lean;
      const drift = sway * direction * envelope * Math.sin(0.9 * (beat + 0.42));
      return seatedPose(pitch, drift);
    },
    loopReaction(seconds, { strength, lean, timing }, established) {
      const beats = beatAtTime(seconds, true);
      const arrival = established ? 1 : ease(beats, grooveStart, -0.19);
      const engagement = established ? 1 : grooveEngagement(beats);
      const accent = 0.95 + 0.05 * Math.cos((beats - 2) * fullTurn / 4);
      const pitch = depth * strength * arrival * engagement * accent * seatedDip(beats - timing);
      const drift = sway * lean * arrival * Math.sin((beats + 0.42) * fullTurn / 8);
      return seatedPose(pitch, drift);
    },
  };
}

function grooveEngagement(beat) {
  return 0.45 + 0.55 * ease(beat, -0.08, 1.92);
}

function seatedDip(phase) {
  // A quicker dip and slower rise, with no stop between nods.
  const swing = phase - 0.069 * (1 - Math.cos(phase * fullTurn));
  return 0.14 + 0.43 * (1 + Math.cos(swing * fullTurn));
}

function seatedPose(pitch, drift) {
  return {
    pitch,
    roll: drift,
    yaw: 0.45 * drift,
    lift: -0.025 * pitch,
    // Favor progressively deeper frames of the fallback sprite as the chin drops.
    frame: pitch < -0.014 ? 0.66 : 0.34 * Math.min(1, Math.max(0, pitch / 0.31)),
  };
}

function waltzBeat(seconds, continuous = false) {
  const firstDownbeat = waltzDownbeats[0];
  const lastDownbeat = waltzDownbeats.at(-2);
  if (continuous && (seconds < firstDownbeat || seconds >= lastDownbeat)) {
    // Treat the end and intro as one bar between the last and first measured downbeats.
    const clipLength = waltzDownbeats.at(-1);
    const beforeFirst = seconds < firstDownbeat;
    const time = beforeFirst ? seconds + clipLength : seconds;
    const progress = (time - lastDownbeat) / (clipLength + firstDownbeat - lastDownbeat);
    const lastBarBeat = 3 * (waltzDownbeats.length - 3);
    return beforeFirst ? 3 * (progress - 2) : lastBarBeat + 3 * progress;
  }
  const nextBar = waltzDownbeats.findIndex((downbeat) => downbeat > seconds);
  if (nextBar <= 0) return NaN;

  const start = waltzDownbeats[nextBar - 1];
  const progress = (seconds - start) / (waltzDownbeats[nextBar] - start);
  return 3 * (nextBar - 2 + progress);
}

function ease(value, start, end) {
  const t = Math.max(0, Math.min(1, (value - start) / (end - start)));
  return t * t * (3 - 2 * t);
}

function gesture(time, start, peak, end) {
  return ease(time, start, peak) * (1 - ease(time, peak, end));
}
