#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = join(scriptDirectory, "..");
const outputDirectory = join(
  repositoryRoot,
  "Sources",
  "ScoreAudioEngine",
  "Resources",
  "EngineeringScore",
  "Audio",
);

const sampleRate = 48_000;
const beatsPerMinute = 120;
const beatsPerBar = 4;
const secondsPerBeat = 60 / beatsPerMinute;

const sections = {
  intro: { id: "intro", bars: 4 },
  core: { id: "core", bars: 8 },
  outro: { id: "outro", bars: 4 },
};

const stems = ["pad", "pulse", "percussion", "motif"];

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value));
}

function deterministicNoise(index) {
  let value = (index + 1) >>> 0;
  value ^= value << 13;
  value ^= value >>> 17;
  value ^= value << 5;
  return ((value >>> 0) / 0xffffffff) * 2 - 1;
}

function sectionEnvelope(sectionID, frame, frameCount) {
  const twoSeconds = sampleRate * 2;
  const fourSeconds = sampleRate * 4;

  if (sectionID === "intro" && frame < twoSeconds) {
    const progress = frame / twoSeconds;
    return Math.sin((Math.PI / 2) * progress) ** 2;
  }

  if (sectionID === "outro" && frame > frameCount - fourSeconds) {
    const remaining = (frameCount - frame) / fourSeconds;
    return Math.sin((Math.PI / 2) * clamp(remaining, 0, 1)) ** 2;
  }

  return 1;
}

function stemSample(stemID, sectionID, frame, frameCount) {
  const time = frame / sampleRate;
  const beatFrames = sampleRate * secondsPerBeat;
  const frameInBeat = frame % beatFrames;
  const beatProgress = frameInBeat / beatFrames;
  const envelope = sectionEnvelope(sectionID, frame, frameCount);

  switch (stemID) {
    case "pad": {
      const fundamental = Math.sin(2 * Math.PI * 110 * time);
      const fifth = Math.sin(2 * Math.PI * 165 * time) * 0.45;
      return (fundamental + fifth) * 0.12 * envelope;
    }
    case "pulse": {
      const pulseEnvelope = Math.sin(Math.PI * beatProgress) ** 4;
      return Math.sin(2 * Math.PI * 220 * time) * 0.18 * pulseEnvelope * envelope;
    }
    case "percussion": {
      const burstFrames = Math.floor(sampleRate * 0.09);
      if (frameInBeat >= burstFrames) return 0;
      const burstProgress = frameInBeat / burstFrames;
      const burstEnvelope = Math.sin(Math.PI * burstProgress) ** 2;
      return deterministicNoise(frame) * 0.11 * burstEnvelope * envelope;
    }
    case "motif": {
      const motifFrequencies = [330, 392, 440, 392, 330, 294, 330, 392];
      const beatIndex = Math.floor(frame / beatFrames);
      const frequency = motifFrequencies[beatIndex % motifFrequencies.length];
      const noteEnvelope = Math.sin(Math.PI * beatProgress) ** 2;
      return Math.sin(2 * Math.PI * frequency * time) * 0.14 * noteEnvelope * envelope;
    }
    default:
      throw new Error(`Unknown stem ${stemID}`);
  }
}

function makePCM16Wav(samples) {
  const bytesPerSample = 2;
  const dataLength = samples.length * bytesPerSample;
  const buffer = Buffer.alloc(44 + dataLength);

  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(36 + dataLength, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * bytesPerSample, 28);
  buffer.writeUInt16LE(bytesPerSample, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(dataLength, 40);

  for (let index = 0; index < samples.length; index += 1) {
    const normalized = clamp(samples[index], -1, 1);
    const integer = Math.round(normalized * 32_767);
    buffer.writeInt16LE(integer, 44 + index * bytesPerSample);
  }

  return buffer;
}

mkdirSync(outputDirectory, { recursive: true });
for (const filename of readdirSync(outputDirectory)) {
  if (filename.endsWith(".wav")) {
    unlinkSync(join(outputDirectory, filename));
  }
}

const results = [];
const coreFrameCount = Math.round(
  sections.core.bars * beatsPerBar * secondsPerBeat * sampleRate,
);
for (const stem of stems) {
  const samples = new Float64Array(coreFrameCount);
  for (let frame = 0; frame < coreFrameCount; frame += 1) {
    samples[frame] = stemSample(stem, sections.core.id, frame, coreFrameCount);
  }

  const wav = makePCM16Wav(samples);
  const filename = `core_${stem}.wav`;
  writeFileSync(join(outputDirectory, filename), wav);
  results.push({
    filename,
    frames: coreFrameCount,
    sha256: createHash("sha256").update(wav).digest("hex"),
  });
}

for (const section of [sections.intro, sections.outro]) {
  const frameCount = Math.round(
    section.bars * beatsPerBar * secondsPerBeat * sampleRate,
  );
  const samples = new Float64Array(frameCount);
  for (let frame = 0; frame < frameCount; frame += 1) {
    let mixed = 0;
    for (const stem of stems) {
      mixed += stemSample(stem, section.id, frame, frameCount);
    }
    samples[frame] = mixed * 0.72;
  }

  const wav = makePCM16Wav(samples);
  const filename = `${section.id}.wav`;
  writeFileSync(join(outputDirectory, filename), wav);
  results.push({
    filename,
    frames: frameCount,
    sha256: createHash("sha256").update(wav).digest("hex"),
  });
}

for (const result of results) {
  process.stdout.write(`${result.filename}\t${result.frames}\t${result.sha256}\n`);
}
