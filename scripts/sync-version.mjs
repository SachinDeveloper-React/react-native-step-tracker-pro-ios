#!/usr/bin/env node
// Run by `npm version`: writes package.json's version into
// ios/Core/LibraryVersion.swift, which every iOS snapshot signs as
// `libraryVersion`. npm then commits both files together.
import { readFileSync, writeFileSync } from 'node:fs';

const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const file = new URL('../ios/Core/LibraryVersion.swift', import.meta.url);
const swift = readFileSync(file, 'utf8');
const next = swift.replace(/current = "[^"]*"/, `current = "${version}"`);
if (!next.includes(`current = "${version}"`)) throw new Error('LibraryVersion.current not found');
writeFileSync(file, next);
console.log(`LibraryVersion.current = ${version}`);
