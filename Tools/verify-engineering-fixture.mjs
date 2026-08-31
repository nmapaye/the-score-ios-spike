#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const fixtureRoot = resolve(
  scriptDirectory,
  "..",
  "Sources",
  "ScoreAudioEngine",
  "Resources",
  "EngineeringScore",
);
const manifestPath = join(fixtureRoot, "pack.json");
const pack = JSON.parse(readFileSync(manifestPath, "utf8"));

function fail(message) {
  process.stderr.write(`Fixture error: ${message}\n`);
  process.exitCode = 1;
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

const assets = [
  ...pack.stems.map((stem) => stem.asset),
  ...(pack.intro ? [pack.intro] : []),
  ...(pack.outro ? [pack.outro] : []),
];

const seen = new Set();
const verified = [];
for (const asset of assets) {
  if (seen.has(asset.resourceName)) {
    fail(`duplicate resource ${asset.resourceName}`);
    continue;
  }
  seen.add(asset.resourceName);

  const path = resolve(fixtureRoot, asset.resourceName);
  const relativePath = relative(fixtureRoot, path);
  if (relativePath.startsWith(`..${sep}`) || relativePath === "..") {
    fail(`resource escapes fixture root: ${asset.resourceName}`);
    continue;
  }
  if (!existsSync(path)) {
    fail(`missing resource ${asset.resourceName}`);
    continue;
  }
  if (!realpathSync(path).startsWith(`${realpathSync(fixtureRoot)}${sep}`)) {
    fail(`resolved resource escapes fixture root: ${asset.resourceName}`);
    continue;
  }

  const wav = readFileSync(path);
  if (wav.toString("ascii", 0, 4) !== "RIFF" || wav.toString("ascii", 8, 12) !== "WAVE") {
    fail(`${asset.resourceName} is not a RIFF/WAVE file`);
    continue;
  }
  const channels = wav.readUInt16LE(22);
  const sampleRate = wav.readUInt32LE(24);
  const bitsPerSample = wav.readUInt16LE(34);
  const dataBytes = wav.readUInt32LE(40);
  const bytesPerFrame = channels * (bitsPerSample / 8);
  const frames = dataBytes / bytesPerFrame;
  const hash = sha256(wav);

  if (sampleRate !== pack.grid.sampleRate) {
    fail(`${asset.resourceName} has sample rate ${sampleRate}`);
  }
  if (frames !== asset.exactFrameCount) {
    fail(`${asset.resourceName} has ${frames} frames; expected ${asset.exactFrameCount}`);
  }
  if (hash !== asset.sha256) {
    fail(`${asset.resourceName} SHA-256 mismatch`);
  }
  verified.push({ resourceName: asset.resourceName, hash });
}

const canonicalAssets = verified
  .sort((left, right) => left.resourceName.localeCompare(right.resourceName))
  .map((asset) => `${asset.resourceName}:${asset.hash}\n`)
  .join("");
const contentHash = sha256(Buffer.from(canonicalAssets, "utf8"));
if (pack.integrityHash !== contentHash) {
  fail(`pack integrityHash should be ${contentHash}`);
}

if (!process.exitCode) {
  process.stdout.write(
    `VALID ${pack.id}: ${verified.length} audio assets, integrity ${contentHash}\n`,
  );
}
