#!/usr/bin/env python3
"""Pre-ship gate for this mod: compile every script as the engine loads it, then run
every harness on the engine's own Lua.

    python tools/check-lua.py            # compile + local budget + all harnesses
    python tools/check-lua.py -v         # ...and each harness's full output

The compile/budget logic is NOT here. It lives in the gamma-anomaly-debug skill
(`scripts/check_lua.py`), because none of it is specific to this mod: the engine
prepends a two-local namespace header to every `.script` before loading it, which
leaves a file 198 locals rather than 200, and going over is a load-time syntax error
that takes the whole module down. See that script's docstring, and
`references/mod-authoring.md` §4, for the full account.

This file is only the project-specific half: where this mod's scripts are, and which
harnesses to run.

Requires the skill (set IQM_GAMMA_SKILL to override the search) and `pip install lupa`.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..'))
SCRIPTS = os.path.join(ROOT, 'gamedata', 'scripts')

SKILL_CANDIDATES = [
    os.environ.get('IQM_GAMMA_SKILL'),
    os.path.expanduser('~/.claude/skills/gamma-anomaly-debug'),
    os.path.expanduser('~/.config/claude/skills/gamma-anomaly-debug'),
]


def find_checker():
    for base in SKILL_CANDIDATES:
        if not base:
            continue
        p = os.path.join(base, 'scripts', 'check_lua.py')
        if os.path.isfile(p):
            return p
    sys.exit(
        "Can't find the gamma-anomaly-debug skill's scripts/check_lua.py.\n"
        "Looked in:\n  " + '\n  '.join(c for c in SKILL_CANDIDATES if c) + '\n'
        "Set IQM_GAMMA_SKILL to the skill directory, or run the checker directly:\n"
        "  python <skill>/scripts/check_lua.py            # from this repo root\n"
        "  python <skill>/scripts/check_lua.py --run tools/nav-harness/harness.lua")


def main():
    verbose = '-v' in sys.argv or '--verbose' in sys.argv
    checker = find_checker()
    py = sys.executable

    # 1. every shipped script, compiled the way the engine loads it
    rc = subprocess.run([py, checker, SCRIPTS], cwd=ROOT).returncode

    # 2. every harness, on the same VM.
    #
    # Run one per process so they cannot see each other's globals, and from the repo
    # root because the harnesses resolve the module they load relative to arg[0] --
    # which the checker sets for us.
    print('\n-- harnesses ---------------------------------------------------')
    failures = []
    for d in sorted(x for x in os.listdir(os.path.join(ROOT, 'tools'))
                    if x.endswith('-harness')):
        rel = os.path.join('tools', d, 'harness.lua')
        if not os.path.exists(os.path.join(ROOT, rel)):
            continue
        name = d[:-len('-harness')]
        proc = subprocess.run([py, checker, '--quiet', '--run', rel],
                              capture_output=True, text=True, cwd=ROOT)
        out = (proc.stdout or '') + (proc.stderr or '')
        if verbose:
            print(out.rstrip())

        tally = None
        for tally in re.finditer(r'(\d+) passed, (\d+) failed', out):
            pass
        if proc.returncode != 0:
            failures.append(name)
            print('  FAIL %-10s crashed:\n%s' % (name, out.strip()[-800:]))
        elif tally:
            passed, failed = int(tally.group(1)), int(tally.group(2))
            if failed:
                failures.append(name)
                for line in out.splitlines():
                    if line.strip().startswith('FAIL'):
                        print('       %s' % line.strip())
            print('  %-4s %-10s %d passed, %d failed'
                  % ('ok' if not failed else 'FAIL', name, passed, failed))
        else:
            # taskwork's harness is a state dump rather than an assertion suite
            print('  ok   %-10s ran clean (no assertion tally)' % name)

    print('')
    if failures:
        print('%d harness(es) failing: %s' % (len(failures), ', '.join(failures)))
    if rc:
        print('scripts failed to compile; they will not load in game')
    if not failures and not rc:
        print('all good')
    return 1 if (failures or rc) else 0


if __name__ == '__main__':
    sys.exit(main())
