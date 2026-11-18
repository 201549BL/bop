import { demoSongs, restPose, tapPose } from "./demo-songs.js?v=4";

const stage = document.querySelector(".stage");
const bopCue = document.querySelector(".bop-cue");
const toyTrigger = document.querySelector(".toy-trigger");
const frames = document.querySelector(".toy-frames");
const canvas = document.querySelector(".toy-canvas");
const player = document.querySelector(".demo-player");
const transport = document.querySelector(".demo-transport");
const playbackButton = document.querySelector(".playback-button");
const nextButton = document.querySelector(".next-song");
const trackTitle = document.querySelector(".track-title");
const trackArtist = document.querySelector(".track-artist");
const playerError = document.querySelector(".player-error");
const playlistDrawer = document.querySelector(".playlist-drawer");
const playlistCard = document.querySelector(".demo-playlist");
const playlistSummary = document.querySelector(".playlist-summary");
const playlistContent = document.querySelector(".playlist-content");
const playlistCount = document.querySelector(".playlist-count");
const playlistTransfer = document.querySelector(".playlist-transfer");
const playlist = document.querySelector(".playlist-songs");
const status = document.querySelector("#demo-status");
const toyStatus = document.querySelector("#toy-status");
const audio = document.querySelector("#demo-audio");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const loopMode = new URLSearchParams(location.search).get("loop") === "1";

const tracks = Object.entries(demoSongs).map(([track, song]) => ({ ...song, track }));
const lastVariations = new Map();
const savedTracks = new Set();
const tapDuration = 750;
const bopCueDuration = 1350;
const playlistSaveDelay = 650;
const visiblePlaylistRows = 3;
const framesPerRow = 4;
const frameCount = framesPerRow ** 2;
const turnPerPixel = 0.015;
const coastTimeConstant = 130;
const minCoastSpeed = 0.00018;
const maxCoastSpeed = 0.014;
const sprite = new Image();
let spriteReady = false;
let tapStartedAt;
let animationRequest;
let lastDrawAt;
let bopCueTimeout;
let lastFrame = -1;
let bobblehead;
let drag;
let coast;
let pendingTurn = 0;
let suppressTap = false;
let remainingTracks = [];
let selectedTrack;
let variation;
let playing = false;
let playbackRequest = 0;
let grooveEstablished = false;

sprite.src = new URL("assets/bobblehead-frames.webp", document.baseURI).href;
sprite.decode().then(() => {
  spriteReady = true;
}).catch(() => {
  // The still image and beat controls are available without the sprite.
});

function draw(timestamp) {
  animationRequest = undefined;
  const tapAge = tapStartedAt === undefined ? tapDuration : timestamp - tapStartedAt;
  const tapping = tapAge < tapDuration;
  const turn = pendingTurn + coastTurn(timestamp);
  pendingTurn = 0;

  if (!tapping && tapStartedAt !== undefined) {
    tapStartedAt = undefined;
    toyStatus.textContent = "";
  }
  const animate = !reducedMotion.matches;
  let reaction;
  if (playing) {
    const time = audio.currentTime;
    saveTrack(time);
    if (animate) {
      reaction = loopMode && selectedTrack.loopReaction
        ? selectedTrack.loopReaction(time, variation, grooveEstablished)
        : selectedTrack.react(time, variation);
    }
  } else if (animate && tapping) {
    reaction = tapPose(Math.max(0, tapAge) / tapDuration);
  }

  const useFrames = !bobblehead && spriteReady && reaction?.frame !== undefined;
  stage.toggleAttribute("data-animate", useFrames);
  // Skip time spent offscreen without making the head jump to the latest pose.
  const elapsed = lastDrawAt === undefined ? 1 / 60 : Math.min(0.05, (timestamp - lastDrawAt) / 1000);
  const settling = bobblehead?.pose(reaction ?? restPose, turn, animate ? elapsed : 0);

  if (useFrames) {
    const frame = Math.min(frameCount - 1, Math.floor(reaction.frame * frameCount));
    if (frame !== lastFrame) {
      const x = (frame % framesPerRow) / (framesPerRow - 1) * 100;
      const y = Math.floor(frame / framesPerRow) / (framesPerRow - 1) * 100;
      frames.style.backgroundPosition = `${x}% ${y}%`;
      lastFrame = frame;
    }
  }

  if (playing || tapping || coast || settling) {
    lastDrawAt = timestamp;
    scheduleDraw();
  } else {
    lastDrawAt = undefined;
  }
}

function scheduleDraw() {
  if (animationRequest === undefined) animationRequest = requestAnimationFrame(draw);
}

function coastTurn(timestamp) {
  if (!coast) return 0;
  if (reducedMotion.matches) {
    coast = undefined;
    return 0;
  }

  const elapsed = Math.max(0, timestamp - coast.lastTime);
  const speed = coast.speed * Math.exp(-elapsed / coastTimeConstant);
  // Integrate the decaying speed so the coast feels the same at any refresh rate.
  const turn = (coast.speed - speed) * coastTimeConstant;
  if (Math.abs(speed) < minCoastSpeed) {
    coast = undefined;
  } else {
    coast.speed = speed;
    coast.lastTime += elapsed;
  }
  return turn;
}

function saveTrack(time) {
  const song = selectedTrack;
  const { track } = song;
  const bopAtTime = loopMode ? song.loopBopAtTime : song.bopAtTime;
  if (bopAtTime === undefined || time < bopAtTime) return;

  grooveEstablished = true;
  if (savedTracks.has(track)) return;
  savedTracks.add(track);
  showBop();
  setTimeout(() => addToPlaylist(song), playlistSaveDelay);
}

function showBop() {
  stage.setAttribute("data-pulse", "");
  clearTimeout(bopCueTimeout);
  bopCueTimeout = setTimeout(() => stage.removeAttribute("data-pulse"), bopCueDuration);
  if (reducedMotion.matches || document.hidden) return;

  for (const animation of bopCue.getAnimations()) animation.cancel();
  bopCue.animate([
    { transform: "translateY(7px) rotate(-8deg) scale(.72)", opacity: 0 },
    { transform: "translateY(-4px) rotate(3deg) scale(1.14)", opacity: 1, offset: 0.48 },
    { transform: "rotate(-1deg) scale(.98)", opacity: 1, offset: 0.78 },
    { transform: "none", opacity: 1 },
  ], { duration: 405, easing: "ease-out" });
}

function setPlaylistExpanded(expanded) {
  if (!expanded && playlistContent.contains(document.activeElement)) playlistSummary.focus();
  playlistSummary.setAttribute("aria-expanded", String(expanded));
  playlistContent.inert = !expanded;
}

playlistSummary.addEventListener("click", () => {
  const expanded = playlistContent.inert;
  if (!expanded) {
    for (const element of [playlistDrawer, playlistCard, playlistTransfer]) {
      for (const animation of element.getAnimations()) animation.cancel();
    }
  }
  setPlaylistExpanded(expanded);
});

function addToPlaylist({ title, artist }) {
  const firstSave = playlistDrawer.hidden;
  const scrollTop = playlist.scrollTop;
  for (const element of [playlist.firstElementChild, playlistCount]) {
    for (const animation of element?.getAnimations() ?? []) animation.cancel();
  }
  const item = document.createElement("li");
  const note = document.createElement("span");
  note.className = "playlist-track-mark";
  note.setAttribute("aria-hidden", "true");
  note.textContent = "♪";
  const name = document.createElement("span");
  name.className = "playlist-track-name";
  name.textContent = title;
  const byline = document.createElement("span");
  byline.className = "playlist-track-artist";
  byline.textContent = artist;
  item.append(note, name, byline);
  playlist.prepend(item);
  const count = playlist.children.length;
  if (count > visiblePlaylistRows) playlist.tabIndex = 0;
  if (scrollTop > 0) playlist.scrollTop = scrollTop + item.getBoundingClientRect().height;
  playlistCount.textContent = count === 1 ? "1 song" : `${count} songs`;
  if (firstSave) {
    setPlaylistExpanded(true);
    playlistDrawer.hidden = false;
  }
  status.textContent = `${title} added to Recent bops.`;
  if (!document.hidden) animatePlaylistSave(item, note, firstSave);
}

function animatePlaylistSave(item, note, firstSave) {
  const move = !reducedMotion.matches;
  const showNewSong = !playlistContent.inert && playlist.scrollTop === 0;
  const flightDuration = 800;
  if (move) animatePlaylistTransfer(showNewSong ? note : playlistCount, flightDuration);

  if (firstSave && move) {
    const height = playlistDrawer.getBoundingClientRect().height;
    const timing = { duration: 500, easing: "cubic-bezier(.22, .8, .28, 1)" };
    playlistDrawer.animate([{ height: "0px" }, { height: `${height}px` }], timing);
    playlistCard.animate([{ transform: "translateY(-18px)" }, { transform: "none" }], timing);
  }

  if (!showNewSong) {
    playlistCount.animate([
      { color: "var(--accent)" },
      { color: "var(--accent)", offset: 0.55 },
      { color: "var(--quiet)" },
    ], { delay: move ? flightDuration : 0, duration: 1600 });
    return;
  }

  const highlight = { backgroundColor: "var(--row-highlight)" };
  const entry = move ? { opacity: 0, transform: "translateX(12px)" } : {};
  item.animate([
    { ...highlight, ...entry },
    { ...highlight, opacity: 1, transform: "none", offset: 0.18 },
    { ...highlight, offset: 0.68 },
    { backgroundColor: "transparent" },
  ], { delay: move ? flightDuration - 100 : 0, duration: 1920, fill: "backwards" });
}

function animatePlaylistTransfer(destination, duration) {
  for (const animation of playlistTransfer.getAnimations()) animation.cancel();

  const stageBounds = stage.getBoundingClientRect();
  const cue = bopCue.getBoundingClientRect();
  const target = destination.getBoundingClientRect();
  const fromX = cue.left + cue.width / 2 - stageBounds.left;
  const fromY = cue.top + cue.height / 2 - stageBounds.top;
  const toX = target.left + target.width / 2 - stageBounds.left;
  const toY = target.top + target.height / 2 - stageBounds.top;
  const position = (x, y, angle, scale) =>
    `translate(${x}px, ${y}px) translate(-50%, -50%) rotate(${angle}deg) scale(${scale})`;

  playlistTransfer.animate([
    { transform: position(fromX, fromY, 12, 0.5), opacity: 0 },
    { transform: position(fromX + 9, fromY - 17, 14, 1), opacity: 1, offset: 0.22, easing: "cubic-bezier(.42, 0, .68, 1)" },
    { transform: position(toX, toY, -7, 0.87), opacity: 1, offset: 0.9 },
    { transform: position(toX, toY, 0, 0.65), opacity: 0 },
  ], { duration });
}

function setPlaying(active) {
  playing = active;
  transport.toggleAttribute("data-playing", active);
  playbackButton.setAttribute("aria-label", active ? "Pause song" : "Play song");
  scheduleDraw();
}

function takeNextTrack() {
  if (remainingTracks.length === 0) remainingTracks = [...tracks];

  const choices = remainingTracks.length > 1
    ? remainingTracks.filter((song) => song !== selectedTrack)
    : remainingTracks;
  const next = choices[Math.floor(Math.random() * choices.length)];
  remainingTracks.splice(remainingTracks.indexOf(next), 1);
  return next;
}

function pauseTrack() {
  playbackRequest++;
  audio.pause();
  setPlaying(false);
}

async function playTrack(song) {
  const request = ++playbackRequest;
  playerError.hidden = true;
  if (selectedTrack !== song || !audio.hasAttribute("src")) {
    audio.pause();
    selectedTrack = song;
    grooveEstablished = false;
    const options = song.variations.filter((option) => option !== lastVariations.get(song));
    variation = options[Math.floor(Math.random() * options.length)];
    lastVariations.set(song, variation);
    status.textContent = "";
    trackTitle.textContent = song.title;
    trackArtist.textContent = song.artist;
    audio.src = `assets/demo-${song.track}.mp3`;
    setPlaying(false);
  }

  try {
    await audio.play();
  } catch (error) {
    if (request === playbackRequest && error.name !== "AbortError") showPlaybackError();
  }
}

function showPlaybackError() {
  setPlaying(false);
  playerError.hidden = false;
  playerError.textContent = `Couldn’t play ${selectedTrack.title}.`;
}

playbackButton.addEventListener("click", () => {
  if (audio.paused) void playTrack(selectedTrack ?? takeNextTrack());
  else pauseTrack();
});

nextButton.addEventListener("click", () => {
  void playTrack(takeNextTrack());
});

audio.addEventListener("playing", () => {
  if (!audio.paused) setPlaying(true);
});
audio.addEventListener("pause", () => {
  if (audio.paused) setPlaying(false);
});
audio.addEventListener("timeupdate", () => {
  if (playing && !audio.paused) saveTrack(audio.currentTime);
});
audio.addEventListener("error", () => {
  if (audio.error) showPlaybackError();
});

toyTrigger.addEventListener("click", (event) => {
  if (playing || (event.detail > 0 && suppressTap)) return;

  tapStartedAt = performance.now();
  toyStatus.textContent = "The bobblehead nodded.";
  scheduleDraw();
});

toyTrigger.addEventListener("pointerdown", (event) => {
  if (!bobblehead || !event.isPrimary || event.button !== 0) return;

  suppressTap = false;
  coast = undefined;
  drag = { id: event.pointerId, lastX: event.clientX, lastTime: event.timeStamp, speed: 0, turning: false };
  toyTrigger.setPointerCapture(event.pointerId);
});

toyTrigger.addEventListener("pointermove", (event) => {
  if (!bobblehead || drag?.id !== event.pointerId) return;

  const distance = event.clientX - drag.lastX;
  if (!drag.turning && Math.abs(distance) < 4) return;

  const turn = distance * turnPerPixel;
  const elapsed = Math.max(8, event.timeStamp - drag.lastTime);
  drag.speed += (turn / elapsed - drag.speed) * Math.min(1, elapsed / 32);
  drag.turning = true;
  drag.lastX = event.clientX;
  drag.lastTime = event.timeStamp;
  stage.setAttribute("data-dragging", "");
  pendingTurn += turn;
  scheduleDraw();
});

function finishDrag(event) {
  if (drag?.id !== event.pointerId) return;

  const releaseDelay = event.timeStamp - drag.lastTime;
  if (event.type === "pointerup" && drag.turning && releaseDelay < 80 && !reducedMotion.matches) {
    const speed = Math.max(-maxCoastSpeed, Math.min(maxCoastSpeed, drag.speed));
    if (Math.abs(speed) >= minCoastSpeed) {
      coast = { speed: speed * Math.exp(-releaseDelay / 90), lastTime: performance.now() };
      scheduleDraw();
    }
  }

  suppressTap = drag.turning;
  drag = undefined;
  stage.removeAttribute("data-dragging");
}

toyTrigger.addEventListener("pointerup", finishDrag);
toyTrigger.addEventListener("pointercancel", finishDrag);
toyTrigger.addEventListener("lostpointercapture", finishDrag);

toyTrigger.addEventListener("keydown", (event) => {
  if (!bobblehead || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;

  switch (event.key) {
    case "ArrowLeft":
      pendingTurn -= Math.PI / 12;
      break;
    case "ArrowRight":
      pendingTurn += Math.PI / 12;
      break;
    case "Home":
      pendingTurn = 0;
      bobblehead.resetTurn();
      break;
    default:
      return;
  }
  event.preventDefault();
  coast = undefined;
  scheduleDraw();
});

setPlaying(false);
player.hidden = false;
toyTrigger.hidden = false;

import("./bobblehead.js?v=2").then(({ loadBobblehead }) => loadBobblehead(canvas)).then((model) => {
  function syncModel() {
    const available = model.isAvailable();
    bobblehead = available ? model : undefined;
    stage.toggleAttribute("data-live-model", available);
    toyTrigger.setAttribute("aria-label", available ? "Rotate or nod the AirPods bobblehead" : "Give the bobblehead a nod");
    if (available) {
      toyTrigger.setAttribute("aria-describedby", "toy-controls");
    } else {
      toyTrigger.removeAttribute("aria-describedby");
      drag = undefined;
      coast = undefined;
      pendingTurn = 0;
      suppressTap = false;
      stage.removeAttribute("data-dragging");
    }
    scheduleDraw();
  }

  canvas.addEventListener("webglcontextlost", syncModel);
  canvas.addEventListener("webglcontextrestored", () => {
    model.restoreLighting();
    syncModel();
  });
  syncModel();
}).catch(() => {
  // Keep the rendered bobblehead playable when the live model is unavailable.
});
