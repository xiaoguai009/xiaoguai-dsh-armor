import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const legacyPluginIds = Object.freeze([
  "dsh-infinite-gen-4",
  "dsh-infinite-gen-3",
  "dsh-infinite-gen-2",
  "dsh-infinite-gen-1",
  "无限四代",
  "无限三代",
  "无限二代",
  "无限一代",
  "无限破甲",
]);

function scalarValue(text) {
  const value = text.trim();
  if (value.startsWith('"')) {
    const match = /^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$/.exec(value);
    if (!match) return null;
    try { return JSON.parse('"' + match[1] + '"'); } catch { return null; }
  }
  if (value.startsWith("'")) {
    const match = /^'((?:[^']|'')*)'\s*(?:#.*)?$/.exec(value);
    return match ? match[1].replace(/''/g, "'") : null;
  }
  const match = /^([^\s#\[\]{},&*!]+)\s*(?:#.*)?$/.exec(value);
  return match ? match[1] : null;
}

function describeLines(text) {
  let scalarIndent = null;
  return (text.match(/[^\r\n]*(?:\r\n|\n|\r|$)/g) || [])
    .filter((raw) => raw.length)
    .map((raw, index) => {
      const content = raw.replace(/[\r\n]+$/, "").replace(index === 0 ? /^\uFEFF/ : /$^/, "");
      const indent = /^ */.exec(content)[0].length;
      const empty = /^\s*(?:#.*)?$/.test(content);
      const inScalar = scalarIndent !== null && (empty || indent > scalarIndent);
      if (!inScalar && !empty) scalarIndent = null;
      // Literal/folded scalars may contain YAML-looking examples, not mounts.
      if (!inScalar && /:\s*[>|][+-]?[1-9]?\s*(?:#.*)?$/.test(content)) scalarIndent = indent;
      return { raw, content, indent, empty, inScalar };
    });
}

function nodeEnd(lines, start) {
  const indent = lines[start].indent;
  let end = start + 1;
  while (end < lines.length) {
    const line = lines[end];
    if (!line.empty && !line.inScalar && line.indent <= indent) break;
    end += 1;
  }
  // Retain comments/spacing immediately before the next unrelated node.
  while (end > start + 1 && lines[end - 1].empty) end -= 1;
  return end;
}

function mountLines(lines) {
  const sequenceLines = lines.flatMap((line, index) =>
    !line.empty && !line.inScalar && /^ *-\s/.test(line.content) ? [index] : []);
  if (!sequenceLines.length) return new Set();
  const rootIndent = Math.min(...sequenceLines.map((index) => lines[index].indent));
  const roots = sequenceLines.filter((index) => lines[index].indent === rootIndent);
  const mounts = new Set(roots);
  for (const start of roots) {
    const end = nodeEnd(lines, start);
    for (let cursor = start; cursor < end; cursor += 1) {
      const line = lines[cursor];
      const isInsert = cursor === start
        ? /^ *-\s+insert:\s*(?:#.*)?$/.test(line.content)
        : line.indent === rootIndent + 2 && /^ *insert:\s*(?:#.*)?$/.test(line.content);
      if (!isInsert || line.inScalar) continue;
      const insertEnd = cursor === start ? end : nodeEnd(lines, cursor);
      const children = sequenceLines.filter((index) => index > cursor && index < insertEnd);
      if (!children.length) continue;
      const childIndent = Math.min(...children.map((index) => lines[index].indent));
      for (const index of children) {
        if (lines[index].indent === childIndent) mounts.add(index);
      }
    }
  }
  return mounts;
}

/** Remove only sequence mappings with an exact matching plugin id. */
export function stripPluginMounts(yamlText, ids = legacyPluginIds) {
  const targets = new Set(ids);
  if (!targets.size || !yamlText) return yamlText;
  const lines = describeLines(yamlText);
  const mounts = mountLines(lines);
  const remove = new Set();
  for (let start = 0; start < lines.length; start += 1) {
    const line = lines[start];
    if (!mounts.has(start) || line.empty || line.inScalar) continue;
    const item = /^ *-\s+([^:]+):\s*(.*)$/.exec(line.content);
    if (!item) continue;
    const end = nodeEnd(lines, start);
    let id = item[1].trim() === "id" ? scalarValue(item[2]) : null;
    if (id === null) {
      for (let cursor = start + 1; cursor < end; cursor += 1) {
        const child = lines[cursor];
        if (child.inScalar || child.indent !== line.indent + 2) continue;
        const property = /^ *id:\s*(.*)$/.exec(child.content);
        if (property) { id = scalarValue(property[1]); break; }
      }
    }
    if (!targets.has(id)) continue;
    for (let cursor = start; cursor < end; cursor += 1) remove.add(cursor);
  }

  const retained = lines.filter((_, index) => !remove.has(index));
  // An insert wrapper with no remaining children must not become a null insert.
  const emptyInsert = new Set();
  for (let start = 0; start < retained.length; start += 1) {
    const line = retained[start];
    if (line.inScalar || !/^ *-\s+insert:\s*(?:#.*)?$/.test(line.content)) continue;
    const end = nodeEnd(retained, start);
    // Only change wrappers affected by this migration, not preexisting empties.
    const originalIndex = lines.indexOf(line);
    if (![...remove].some((index) => index > originalIndex && index < nodeEnd(lines, originalIndex))) continue;
    const children = retained.slice(start + 1, end).filter((child) => !child.empty);
    if (!children.length) {
      emptyInsert.add(start);
    } else if (!children.some((child) => /^ *-\s/.test(child.content))) {
      // Preserve wrapper options such as before/after while making insert empty.
      line.raw = line.raw.replace(/(insert:)\s*(?=#|[\r\n]|$)/, "$1 [] ");
    }
  }
  return retained.filter((_, index) => !emptyInsert.has(index)).map((line) => line.raw).join("");
}

function readPackage(profileDir) {
  const file = path.join(profileDir, "package.json");
  if (!fs.existsSync(file)) return null;
  const text = fs.readFileSync(file, "utf8");
  return { file, text, value: JSON.parse(text.replace(/^\uFEFF/, "")) };
}

export function isDshProfile(profileDir) {
  try {
    const pkg = readPackage(profileDir)?.value;
    return Boolean(pkg?.dsh?.profile && typeof pkg.dsh.profile === "object" && !Array.isArray(pkg.dsh.profile));
  } catch { return false; }
}

function writeBackedUp(file, text) {
  const backup = file + ".before-xiaoguai-migration.bak";
  if (!fs.existsSync(backup)) fs.copyFileSync(file, backup);
  const temporary = file + ".xiaoguai-migration.tmp";
  fs.writeFileSync(temporary, text, "utf8");
  fs.renameSync(temporary, file);
  return { file, backup };
}

function migrateYaml(file, ids) {
  if (!fs.existsSync(file)) return null;
  const text = fs.readFileSync(file, "utf8");
  const next = stripPluginMounts(text, ids);
  return next !== text ? writeBackedUp(file, next) : null;
}

function referenceId(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") return value.id || value.name;
  return null;
}

export function migrateProfile(profileDir, { pluginsDir, targetId = "xiaoguai-armor" } = {}) {
  const pkg = readPackage(profileDir);
  if (!pkg) return { profileDir, changed: false, files: [], skipped: "missing_package" };
  const ids = new Set(legacyPluginIds);
  const removedIds = new Set();
  let changed = false;
  const mark = (id) => { removedIds.add(id); changed = true; };
  for (const field of ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]) {
    const dependencies = pkg.value[field];
    if (!dependencies || typeof dependencies !== "object" || Array.isArray(dependencies)) continue;
    for (const [id, value] of Object.entries(dependencies)) {
      let legacy = ids.has(id) ? id : null;
      if (!legacy && pluginsDir && typeof value === "string" && value.startsWith("file:")) {
        const resolved = path.resolve(profileDir, value.slice(5));
        legacy = legacyPluginIds.find((old) => path.resolve(pluginsDir, old) === resolved);
      }
      if (legacy) { delete dependencies[id]; mark(legacy); }
    }
  }
  const profile = pkg.value.dsh?.profile;
  if (profile && typeof profile === "object") {
    if (Array.isArray(profile.bundles)) {
      // Third-party mounts must not also load as base bundles.
      profile.bundles = profile.bundles.filter((item) => {
        const id = referenceId(item);
        if (!ids.has(id) && id !== targetId) return true;
        mark(id);
        return false;
      });
    }
    if (Array.isArray(profile.plugins)) {
      profile.plugins = profile.plugins.filter((item) => {
        const id = referenceId(item);
        if (!ids.has(id)) return true;
        mark(id);
        return false;
      });
    } else if (profile.plugins && typeof profile.plugins === "object") {
      for (const id of legacyPluginIds) {
        if (!Object.hasOwn(profile.plugins, id)) continue;
        delete profile.plugins[id];
        mark(id);
      }
    }
  }
  const files = [];
  if (changed) {
    const indent = /^([\t ]+)"/m.exec(pkg.text)?.[1] || "  ";
    const eol = pkg.text.includes("\r\n") ? "\r\n" : "\n";
    const text = JSON.stringify(pkg.value, null, indent).replace(/\n/g, eol) + eol;
    files.push(writeBackedUp(pkg.file, text));
  }
  const patch = migrateYaml(path.join(profileDir, "cordis.patch.yml"), legacyPluginIds);
  if (patch) files.push(patch);
  return { profileDir, changed: files.length > 0, removedIds: [...removedIds], files };
}

export function migrateDshHome(dshHome, selectedProfiles = []) {
  const root = path.resolve(dshHome);
  const profilesRoot = path.join(root, "profiles");
  const names = fs.existsSync(profilesRoot) ? fs.readdirSync(profilesRoot) : [];
  const selected = new Set(selectedProfiles.map((profile) => path.resolve(profilesRoot, profile)));
  const profiles = [];
  for (const name of names) {
    if (name === "node_modules") continue;
    const directory = path.join(profilesRoot, name);
    if (selected.size && !selected.has(directory)) continue;
    if (!fs.statSync(directory).isDirectory() || !isDshProfile(directory)) continue;
    profiles.push(migrateProfile(directory, { pluginsDir: path.join(root, "plugins") }));
  }
  const extraPatches = [];
  for (const file of [path.join(root, "cordis.patch.yml"), path.join(profilesRoot, "node_modules", "cordis.patch.yml")]) {
    const result = migrateYaml(file, legacyPluginIds);
    if (result) extraPatches.push(result);
  }
  return { dshHome: root, profiles, extraPatches };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [, , dshHome, ...profiles] = process.argv;
    if (!dshHome) throw new Error("Usage: node scripts/lib/migrate.js <dshHome> [profileDir ...]");
    console.log(JSON.stringify(migrateDshHome(dshHome, profiles)));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
