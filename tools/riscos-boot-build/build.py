#!/usr/bin/env python3
"""Build a universal RISC OS !Boot tree from official sources.

Downloads the sources listed in sources.json and composes them into a !Boot +
default hard-disc structure that boots on RISC OS 3.7 / 4.02 / 5.x.

Sources:
  The sources are listed in sources.json, which also records how each is placed:
    sources[]        name, file, url, sha256, strip, role -- what to fetch/extract
    placements[]     copy a subtree onto the disc: source+path (or repo) -> to
                     (a packages_in_rafs flag gates the RaFS vs plain !Packages ones)
    subtree_merges[] merge a tree add-missing (our copy wins overlaps): source+from -> to
    content_place[]  place each child of a container whole, where the disc lacks it
    exclude_root[]   root files to drop from the assembled disc

Switches:
  --[no-]risc-os-4-support      
        
        Patch the RO400 hook for RISC OS 4.02.

  --[no-]multi-rom-safe         
  
        Switch Choices.Boot per OS.

  --[no-]packages-in-rafs       
  
        RaFS-wrap !Packages for long names.

  --minimal             
  
        Boot structure only -- skip apps, content, and overlays.
"""
import os, sys, json, shutil, hashlib, subprocess, argparse
from pathlib import Path
import roextract

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DL = HERE / 'downloads'
WORK = HERE / 'build'
STAGE = WORK / '_stage'
OUT = WORK / 'disc'
LOCAL = HERE / 'local'


def log(m): print(m, flush=True)


def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def ensure_downloads(sources):
    DL.mkdir(parents=True, exist_ok=True)
    for s in sources:
        dest = DL / s['file']
        if dest.exists() and sha256(dest) == s['sha256']:
            log(f"  [cached] {s['file']}")
            continue
        log(f"  downloading {s['file']} ...")
        try:
            import urllib.request
            req = urllib.request.Request(s['url'], headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req) as r, open(dest, 'wb') as f:
                shutil.copyfileobj(r, f)
        except Exception as e:
            log(f"    urllib failed ({e}); falling back to curl")
            subprocess.run(['curl', '-sL', '-A', 'Mozilla/5.0', '-o', str(dest), s['url']], check=True)
        got = sha256(dest)
        if got != s['sha256']:
            sys.exit(f"sha256 mismatch for {s['file']}:\n  got  {got}\n  want {s['sha256']}")
        log(f"    verified {s['file']}")


def module_version(path):
    """Version float from a RISC OS module's help string, else None (not a module)."""
    try:
        data = open(path, 'rb').read()
    except OSError:
        return None
    if len(data) < 0x1c:
        return None
    help_off = int.from_bytes(data[0x14:0x18], 'little')
    if help_off == 0 or help_off + 1 >= len(data):
        return None
    end = data.find(b'\x00', help_off)
    s = data[help_off:end if end >= 0 else len(data)].decode('latin-1', 'replace')
    if '\t' not in s:
        return None
    tail = s.split('\t', 1)[1].strip()
    num = ''
    for ch in tail:
        if ch.isdigit() or ch == '.':
            num += ch
        elif num:
            break
    try:
        return float(num) if num else None
    except ValueError:
        return None


def replace_p(tgt_file, src_file, tgt_meta, src_meta):
    """Should PlingSystem's src replace HardDisc4's target? Mirrors Install_Update:
    replace only if the incoming file is strictly newer (module version, else datestamp)."""
    tv, sv = module_version(tgt_file), module_version(src_file)
    if tv is not None and sv is not None:
        return sv > tv, f"module version target={tv} src={sv}"
    ts = (tgt_meta or {}).get('stamp')
    ss = (src_meta or {}).get('stamp')
    if ts is not None and ss is not None:
        return ss > ts, f"datestamp target={ts} src={ss}"
    # Non-comparable: for the disc-based System resources, prefer PlingSystem's copy.
    return True, "no comparable metadata -> take PlingSystem (System resources)"


def merge_system(src_sys, tgt_sys, src_man, tgt_man, src_prefix, tgt_prefix):
    added = kept = replaced = 0
    for root, _dirs, files in os.walk(src_sys):
        rel = os.path.relpath(root, src_sys)
        for fn in files:
            src_file = Path(root) / fn
            relpath = fn if rel == '.' else f"{rel}/{fn}"
            tgt_file = tgt_sys / relpath
            if not tgt_file.exists():
                tgt_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_file, tgt_file)
                added += 1
                continue
            src_meta = src_man.get(f"{src_prefix}{relpath}")
            tgt_meta = tgt_man.get(f"{tgt_prefix}{relpath}")
            do, why = replace_p(tgt_file, src_file, tgt_meta, src_meta)
            log(f"    overlap {relpath}: {'REPLACE' if do else 'keep    '}  ({why})")
            if do:
                shutil.copy2(src_file, tgt_file)
                replaced += 1
            else:
                kept += 1
    log(f"  merged: {added} added, {replaced} replaced (newer), {kept} kept (target newer/equal)")


def write_basic64_fallback(out):
    """Housekeeping from !SysMerge: a fallback BASIC64 command in Boot.Library."""
    lib = out / '!Boot' / 'Library'
    lib.mkdir(parents=True, exist_ok=True)
    body = 'RMEnsure BASIC64 0 RMLoad System:Modules.BASIC64\n'
    (lib / 'BASIC64,feb').write_text(body)  # type &FEB = Obey


def patch_ro400_configure(out):
    """Give RISC OS 4.02 its native Configure (ROOL's HardDisc4 only stubs RO4).

    ROOL leaves RO400Hook.Res empty and its PreDesktop BootResources path doesn't
    descend to the shared 3.x resources, so on 4.02 !Configure never resolves
    ("You cannot reconfigure this machine"). Replicate RISCOS-Ltd's own RO4 boot:
    rewrite the path to descend RO400->RO370->...->base, and drop the genuine
    4.02 !Configure (from the RO439Boot download) into RO400Hook.Res.
    """
    pd = out / '!Boot' / 'RO400Hook' / 'Boot' / 'PreDesktop,feb'
    old = 'Path BootResources Boot:RO400Hook.Res.,<BootResources$Dir>.'
    new = ('Path BootResources Boot:RO400Hook.Res.,Boot:RO370Hook.Res.,'
           'Boot:RO360Hook.Res.,Boot:RO350Hook.Res.,Boot:RO310Hook.Res.,'
           '<BootResources$Dir>.')
    text = pd.read_text()
    if old not in text:
        sys.exit(f"patch_ro400_configure: expected path line not found in {pd}")
    pd.write_text(text.replace(old, new, 1))
    # The genuine RISC OS 4 Configure comes from the RISCOS-Ltd 4.39 recovery
    # boot (RO439Boot -- proprietary, downloaded, never committed).
    src_res = STAGE / 'RO439Boot' / '!Boot' / 'RO400Hook' / 'Res'
    res = out / '!Boot' / 'RO400Hook' / 'Res'
    res.mkdir(parents=True, exist_ok=True)
    for item in ('!Configure', 'Configure'):
        src = src_res / item
        if not src.exists():
            sys.exit(f"patch_ro400_configure: {item} missing at {src} "
                     "(RO439Boot download/extract failed?)")
        copytree(src, res / item)
    # RO439Boot's Configure.!InetSetup is a recovery stub (no !RunImage) that
    # would shadow our complete !InetSetup at !Boot.Resources.Configure and break
    # Configure->Internet. Drop it so the full one is used. Every other plugin is
    # complete and kept.
    stub_inet = res / 'Configure' / '!InetSetup'
    if stub_inet.exists() and not any(p.name.startswith('!RunImage')
                                      for p in stub_inet.iterdir()):
        shutil.rmtree(stub_inet)


def drop_ro4_rompatch(out):
    """Remove ROOL's !!ROMPatch from the RISC OS 4 (RO400Hook) PreDesk sweep.

    On the RISCOS-Ltd RO4 ROM, ROOL's ROM-bug patcher is inapplicable and exits
    with a code large enough that BootRun's `Repeat` aborts the whole PreDesk
    sweep ("Repeat: Return code too large"). Since !!ROMPatch sorts first,
    nothing else runs -- networking never auto-starts. 3.7/5.x ROMs need it and
    exit cleanly. Diagnosed by spool-tracing the PreDesk sweep on 4.02; see Dev Diary.
    """
    predesk = out / '!Boot' / 'RO400Hook' / 'Boot' / 'PreDesk'
    run = predesk / '!!ROMPatch,feb'
    payload = predesk / 'ROMPatch'
    if run.exists():
        run.unlink()
    if payload.exists():
        shutil.rmtree(payload)


def patch_bootrun_per_os_bootcfg(out):
    """Per-OS Choices.Boot cache + unplug-mask snapshot, so one disc can switch
    RISC OS versions.

    RO<ver>Hook selects version-correct boot files, but SetChoices only copies
    them into the writable Choices.Boot when it's absent -- so on a shared disc
    the first OS to boot stamps Choices.Boot and the rest reuse it (wrong
    BootResources chain -> broken Configure). Inject a swap into BootRun (before
    SetChoices) that stashes the live Boot under its owner's OS tag and restores
    this OS's copy; BootOwner records the owner. Leaves Choices$Write untouched so
    app configs stay shared. (Choices.Internet is NOT cached per OS -- with one NIC
    and the shared disc-based !Internet, every ROM writes an identical Startup, so
    the config is the same across OSes; only the CMOS unplug mask below differs.)

    The same swap also SNAPSHOTS THE CMOS MODULE-UNPLUG MASK PER OS (via
    UnplugSwap), which is the one piece of CMOS that misfires across ROMs. *Unplug
    <name> (used by !Boot.Resources.!Internet.!Run and by interactive Configure to
    unplug the obsolete ROM Internet stack) sets the bit for that name's slot in
    the CURRENT ROM; the same name lands on a different bit per ROM (InternetA is
    &13 bit1 on 4.02 but bit3 on 3.7), so 4.02's bit would unplug one of 3.7's core
    network modules. Each OS must keep its OWN mask: on a swap we save the outgoing
    OS's 13 unplug bytes and restore the incoming OS's (clear if never seen).
    Clearing alone is NOT enough -- an OS doesn't necessarily re-assert its unplugs
    by name each boot (3.7 sets them via interactive Configure), so a cleared mask
    stays lost and its networking breaks. Only the 13 unplug locations are written
    -- filesystem/drive/monitor config is machine state shared across OSes and must
    NOT change (a full-CMOS swap clobbers it -> "Disc drive not known").

    Apply-timing: the unplug mask is consumed at ROM module-init, BEFORE !Boot, so
    the restore lands one boot too late (modules already inited from the outgoing
    mask). So on a real swap we prompt the user to restart (as MbufManager /
    Configure "reset them now" do); the restart boots clean because BootOwner now
    matches (DoSwap=no) and ROM-init reads the restored mask. TODO: replace the
    prompt with an automatic reset (reset-vector via OS_EnterOS; IOMD vs HAL differ).
    """
    br = out / '!Boot' / 'Utils' / 'BootRun,feb'
    # Place the UnplugSwap utility this patch calls (vendored tokenised BASIC).
    unplugswap = REPO / 'tools' / 'riscos-boot-build' / 'vendor' / 'UnplugSwap' / 'UnplugSwap,ffb'
    if not unplugswap.exists():
        sys.exit(f"patch_bootrun_per_os_bootcfg: {unplugswap} missing -- tokenise "
                 "vendor/UnplugSwap/Source,fff inside RISC OS (see its README) first")
    shutil.copy2(unplugswap, br.parent / 'UnplugSwap,ffb')
    anchor = '/<Boot$Dir>.Utils.SetChoices'
    inject = (
        "| --- Per-OS Choices.Boot + unplug-mask snapshot -------------------------\n"
        "| Stash the live Boot under its owner's OS tag, restore this OS's copy;\n"
        "| BootOwner records the owner. On a swap also snapshot the position-keyed\n"
        "| CMOS unplug mask per OS (misfires across ROMs). Rest of Choices/CMOS shared\n"
        "| (incl Choices.Internet -- identical across ROMs with one NIC).\n"
        "IfThere <Boot$Dir>.^.!Choices Then Set Boot$CfgDir <Boot$Dir>.^.!Choices Else Set Boot$CfgDir <Boot$Dir>.Choices\n"
        "Set Boot$OSTag RO<Boot$OSVersion>\n"
        "Set Boot$BootOwner none\n"
        "IfThere <Boot$CfgDir>.BootOwner Then Obey <Boot$CfgDir>.BootOwner\n"
        "Set Boot$DoSwap yes\n"
        'If "<Boot$BootOwner>" = "<Boot$OSTag>" Then Set Boot$DoSwap no\n'
        'If "<Boot$DoSwap>" = "yes" Then IfThere <Boot$CfgDir>.Boot Then Rename <Boot$CfgDir>.Boot <Boot$CfgDir>.Boot-<Boot$BootOwner>\n'
        'If "<Boot$DoSwap>" = "yes" Then IfThere <Boot$CfgDir>.Boot-<Boot$OSTag> Then Rename <Boot$CfgDir>.Boot-<Boot$OSTag> <Boot$CfgDir>.Boot\n'
        '| Per-OS unplug mask: save outgoing OS -> Unplug-<owner>, restore this OS\n'
        '| <- Unplug-<tag> (clear if never seen). Position-keyed, so each OS keeps\n'
        '| its own; clearing is not enough (3.7 sets its mask via interactive Config).\n'
        'If "<Boot$DoSwap>" = "yes" Then Set Unplug$Save <Boot$CfgDir>.Unplug-<Boot$BootOwner>\n'
        'If "<Boot$BootOwner>" = "none" Then Unset Unplug$Save\n'
        'If "<Boot$DoSwap>" = "yes" Then Set Unplug$Load <Boot$CfgDir>.Unplug-<Boot$OSTag>\n'
        'If "<Boot$DoSwap>" = "yes" Then /<Boot$Dir>.Utils.UnplugSwap\n'
        'Unset Unplug$Save\n'
        'Unset Unplug$Load\n'
        '| Record this OS as the owner. Two RISC OS gotchas here:\n'
        '|  1. Write UNCONDITIONALLY (not "If DoSwap.. Then Echo .. { > f }"): a\n'
        '|     redirect on a Then-command still OPENS+TRUNCATES the file when the If\n'
        '|     is false, so a guarded write would blank BootOwner on same-OS reboots.\n'
        '|     Writing every boot is correct anyway -- the owner is always this OS.\n'
        '|  2. No space before "{" -- "<tag> { >" echoes a trailing space, so\n'
        '|     BootOwner would read back "RO370 " and never match "RO370".\n'
        'Echo Set Boot$BootOwner <Boot$OSTag>{ > <Boot$CfgDir>.BootOwner }\n'
        '| The unplug mask is read at ROM module-init (before !Boot), so the restore\n'
        '| lands one boot too late -> prompt to restart (like MbufManager / Configure\n'
        '| "reset them now"). Skip the first-ever boot (owner=none, nothing swapped).\n'
        '| BootOwner is already written, so the restart boots clean (DoSwap=no) and\n'
        '| ROM-init reads the restored mask. Replace with an auto reset-vector later.\n'
        'Set Boot$DoPrompt <Boot$DoSwap>\n'
        'If "<Boot$BootOwner>" = "none" Then Set Boot$DoPrompt no\n'
        'If "<Boot$DoPrompt>" = "yes" Then Echo\n'
        'If "<Boot$DoPrompt>" = "yes" Then Error 0 RISC OS version changed: module-unplug mask restored for this OS. Please restart the machine now (press Reset) so the correct modules load.\n'
        'Unset Boot$DoPrompt\n'
        "Unset Boot$DoSwap\n"
        "Unset Boot$OSTag\n"
        "Unset Boot$BootOwner\n"
        "Unset Boot$CfgDir\n"
        "| ------------------------------------------------------------------------\n"
    )
    text = br.read_text()
    if anchor not in text:
        sys.exit(f"patch_bootrun_per_os_bootcfg: SetChoices call not found in {br}")
    if 'unplug-mask reset' in text:
        sys.exit(f"patch_bootrun_per_os_bootcfg: already patched in {br}")
    br.write_text(text.replace(anchor, inject + anchor, 1))


def copytree(src, dst):
    shutil.copytree(src, dst, dirs_exist_ok=True)


def _ro_leaf(name):
    """RISC OS leafname: drop a trailing ,xxx host filetype suffix if present."""
    if len(name) >= 4 and name[-4] == ',' and all(c in '0123456789abcdefABCDEF' for c in name[-3:]):
        return name[:-4]
    return name


def _ro_clash(path, want_dir):
    """True if path's parent already holds a *different-kind* object with the same
    RISC OS leafname (after dropping ,xxx). HostFS shows e.g. '!Help,fff' (file) and
    '!Help' (dir) both as '!Help', which RISC OS then can't copy to FileCore."""
    parent = path.parent
    if not parent.exists():
        return False
    want = _ro_leaf(path.name)
    for sib in parent.iterdir():
        if sib.name != path.name and _ro_leaf(sib.name) == want and sib.is_dir() != want_dir:
            return True
    return False


def merge_tree_add_missing(src_root, out_root):
    """Add files under src_root into out_root only where the target doesn't already
    have them -- so the existing (HardDisc4/ROOL) tree wins every overlap and this
    only ADDS what's missing (Acorn 3.7 content is always older than HardDisc4).
    Collision-safe: a source item is skipped when it would clash, by RISC OS leafname,
    with a different-kind target object (e.g. Acorn's '!Help/' dir vs HardDisc4's
    '!Help,fff' file) -- so overlapping apps keep the target's whole version rather
    than Frankenstein-merging the two into a copy-breaking duplicate."""
    added = kept = 0
    for root, dirs, files in os.walk(src_root):
        rel = os.path.relpath(root, src_root)
        tgt_dir = out_root if rel == '.' else out_root / rel
        if rel != '.' and _ro_clash(tgt_dir, want_dir=True):
            dirs[:] = []          # don't descend a dir that clashes with a target file
            kept += len(files)
            continue
        for fn in files:
            tgt = tgt_dir / fn
            if tgt.exists() or _ro_clash(tgt, want_dir=False):
                kept += 1
                continue
            tgt.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(Path(root) / fn, tgt)
            added += 1
    return added, kept


def _target_has(tgt_dir, name):
    """True if tgt_dir already holds an object with the same RISC OS leafname
    (ignoring the ,xxx type suffix) as `name`."""
    if not tgt_dir.exists():
        return False
    want = _ro_leaf(name)
    return any(_ro_leaf(p.name) == want for p in tgt_dir.iterdir())


def place_children_add_missing(src_container, tgt_container):
    """Place each immediate child of src_container into tgt_container WHOLE (the entire
    file or app directory), but only where tgt_container lacks that RISC OS leafname.
    This adds the apps/content the authoritative disc doesn't have WITHOUT ever
    descending into an existing app to splice files together -- app-merging is what
    duplicated !Flasher's !Help. The more authoritative target (HardDisc4/ROOL) keeps
    its whole app on every overlap; only genuinely-missing items are added."""
    added = kept = 0
    if not src_container.exists():
        return added, kept
    tgt_container.mkdir(parents=True, exist_ok=True)
    for child in sorted(src_container.iterdir()):
        if _target_has(tgt_container, child.name):
            kept += 1
            continue
        dst = tgt_container / child.name
        if child.is_dir():
            copytree(child, dst)
        else:
            shutil.copy2(child, dst)
        added += 1
    return added, kept


def main():
    ap = argparse.ArgumentParser(description="Build the universal RISC OS !Boot tree.")
    ap.add_argument('--packages-in-rafs', action=argparse.BooleanOptionalAction,
                    default=False, dest='packages_in_rafs',
                    help="wrap !Packages in a RaFS volume so it gets long names on a "
                         "10-char (E-format) FileCore. Needed for RISC OS < 4.00. Off by "
                         "default (--no-packages-in-rafs); a plain !Packages is placed.")
    ap.add_argument('--risc-os-4-support', action=argparse.BooleanOptionalAction,
                    default=True, dest='ro4_support',
                    help="patch the RO400 hook so RISC OS 4.02 gets its native Configure "
                         "(BootResources descent + real 4.02 !Configure from RO439Boot) and "
                         "drop ROOL's !!ROMPatch, which aborts the RO4 PreDesk sweep. Touches "
                         "only RO400Hook, so it's inert on 3.7/5.x. On by default; "
                         "--no-risc-os-4-support for a vanilla ROOL boot.")
    ap.add_argument('--multi-rom-safe', action=argparse.BooleanOptionalAction,
                    default=True, dest='multi_rom_safe',
                    help="cache Choices.Boot per OS so one disc can be shared across RISC OS "
                         "versions without the first-booted OS stamping everyone's boot. On by "
                         "default; --no-multi-rom-safe to leave Choices.Boot shared.")
    ap.add_argument('--minimal', action='store_true',
                    help="boot structure only -- skip apps, content, and local overlays. "
                         "Compose with the patch flags to isolate a boot/OS/emulator problem "
                         "from the app payload.")
    args = ap.parse_args()
    packages_in_rafs = args.packages_in_rafs
    ro4_support = args.ro4_support
    multi_rom_safe = args.multi_rom_safe
    minimal = args.minimal
    log("== !Packages mode: "
        f"{'RaFS-wrapped (real 10-char E-format FileCore)' if packages_in_rafs else 'plain (native long names -- HostFS or F-format FileCore)'} ==")
    enabled = [n for n, on in (('risc-os-4-support', ro4_support),
                               ('multi-rom-safe', multi_rom_safe)) if on]
    log(f"== boot patches: {', '.join(enabled) if enabled else 'none (vanilla ROOL boot)'} ==")
    if minimal:
        log("== MINIMAL build: boot structure only (no apps/content/overlays) ==")

    cfg = json.load(open(HERE / 'sources.json'))
    sources = cfg['sources']
    byname = {s['name']: s for s in sources}

    log("== 1. download + verify official sources ==")
    ensure_downloads(sources)

    if WORK.exists():
        shutil.rmtree(WORK)
    STAGE.mkdir(parents=True)

    log("== 2. extract archives with HostFS ,xxx names ==")
    man = {}
    for s in sources:
        man[s['name']] = roextract.extract(DL / s['file'], STAGE / s['name'],
                                           strip=s.get('strip', ''), only=s.get('extract_only'))
        typed = sum(1 for v in man[s['name']].values() if v and v.get('ftype') is not None)
        log(f"  {s['name']}: {len(man[s['name']])} files ({typed} typed)")

    log("== 3. lay HardDisc4 down as the disc root ==")
    copytree(STAGE / 'HardDisc4', OUT)

    log("== 4. merge PlingSystem !System -> !Boot.Resources.!System (newest-wins) ==")
    merge_system(
        STAGE / 'PlingSystem' / '!System',
        OUT / '!Boot' / 'Resources' / '!System',
        man['PlingSystem'], man['HardDisc4'],
        src_prefix='!System/',
        tgt_prefix='!Boot/Resources/!System/',
    )
    write_basic64_fallback(OUT)

    log("== 4b. boot-structure patches ==")
    if ro4_support:
        patch_ro400_configure(OUT)
        log("  RO400Hook -> full BootResources descent + real 4.02 !Configure (from RO439Boot)")
        drop_ro4_rompatch(OUT)
        log("  RO400Hook -> dropped ROOL !!ROMPatch from PreDesk (aborts the RO4 sweep)")
    if multi_rom_safe:
        patch_bootrun_per_os_bootcfg(OUT)
        log("  BootRun -> caches Choices.Boot per OS (shared disc switches RISC OS versions)")
    if not (ro4_support or multi_rom_safe):
        log("  (none enabled -- vanilla ROOL boot)")

    log("== 5. place apps (PackMan/PartMgr in Utilities, StrongED/Zap in Apps, RaFS) ==")
    for p in ([] if minimal else cfg.get('placements', [])):
        if 'packages_in_rafs' in p and p['packages_in_rafs'] != packages_in_rafs:
            log(f"  (skip {p['to']} -- needs packages_in_rafs={p['packages_in_rafs']}, "
                f"building packages_in_rafs={packages_in_rafs})")
            continue
        src = REPO / p['repo'] if 'repo' in p else STAGE / p['source'] / p['path']
        dst = OUT / p['to']
        if not src.exists():
            sys.exit(f"placement source missing: {src}")
        dst.parent.mkdir(parents=True, exist_ok=True)
        copytree(src, dst)
        log(f"  {p.get('source', p.get('repo'))}{('/' + p['path']) if 'path' in p else ''} -> {p['to']}")

    log("== 5b. place whole apps/content the authoritative disc lacks (Acorn 3.7 games/sound/movies/manuals; NO app-merging) ==")
    for m in ([] if minimal else cfg.get('content_place', [])):
        src = STAGE / m['source'] / m['container']
        if not src.exists():
            sys.exit(f"content_place source missing: {m['source']}/{m['container']}")
        added, kept = place_children_add_missing(src, OUT / m['container'])
        log(f"  {m['source']} -> {m['container']}: +{added} placed whole, {kept} kept (authoritative already had)")

    log("== 5c. subtree merges (app-bundled !System/!Boot deps, add-missing so ROOL wins overlaps) ==")
    for m in ([] if minimal else cfg.get('subtree_merges', [])):
        src = STAGE / m['source'] / m['from']
        if not src.exists():
            sys.exit(f"subtree_merge source missing: {m['source']}/{m['from']}")
        added, kept = merge_tree_add_missing(src, OUT / m['to'])
        log(f"  {m['source']}/{m['from']} -> {m['to']}: +{added} added, {kept} kept")

    log("== 6. apply local overlays (local/*/ each mirrors disc paths; e.g. acorn = Browse+media, rafs-config) ==")
    # `*.example` dirs are committed placeholder templates, never overlaid.
    overlays = [] if minimal else (sorted(p for p in LOCAL.glob('*')
                      if p.is_dir() and not p.name.endswith('.example')) if LOCAL.exists() else [])
    if not overlays:
        log("  (no local/*/ overlays present)")
    for ov in overlays:
        copytree(ov, OUT)
        log(f"  applied overlay from local/{ov.name}/")

    log("== 7. prune excluded root files ==")
    for ex in cfg.get('exclude_root', []):
        hits = list(OUT.glob(ex)) + list(OUT.glob(ex + ',???'))  # bare or ,xxx-typed, root only
        if not hits:
            log(f"  (no match for {ex})")
        for p in hits:
            p.unlink() if p.is_file() else shutil.rmtree(p)
            log(f"  removed {p.relative_to(OUT)}")

    log(f"\nDONE. Disc tree: {OUT}")
    log("Deploy: copy its contents onto a fresh FileCore disc via RPCEmu HostFS.")


if __name__ == '__main__':
    main()
