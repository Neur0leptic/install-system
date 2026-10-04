#!/usr/bin/env python3
"""Read CPU/RAM and display drivers; render the selected native Portage fragments."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
FAMILIES = ('intel-legacy', 'intel-modern', 'amd', 'radeon', 'nvidia-open', 'nvidia-closed', 'virtual')
DESCRIPTIONS = {
    'intel-legacy': 'Intel i965 VA-API (older Intel, including HD 3000); GLES2 rendering',
    'intel-modern': 'Intel iHD VA-API (Broadwell+); renderer selected separately',
    'amd': 'AMD amdgpu/radeonsi (GCN and newer)',
    'radeon': 'Older AMD Radeon (r600/r300); GLES2 rendering',
    'nvidia-open': 'NVIDIA open kernel modules (Turing+)',
    'nvidia-closed': 'NVIDIA proprietary 580 branch (older supported GPUs)',
    'virtual': 'Virtual/software display (virtio, VMware, QXL); Mesa GLES2',
}


def text(path):
    try:
        return path.read_text().strip()
    except OSError:
        return ''


def probe(proc=Path('/proc'), sysfs=Path('/sys'), root=None):
    cpus = len(os.sched_getaffinity(0))
    memory_match = re.search(r'^MemTotal:\s+(\d+)', text(proc / 'meminfo'), re.M)
    if not memory_match or int(memory_match[1]) <= 0:
        raise ValueError('available RAM could not be read from /proc/meminfo')
    memory = int(memory_match[1]) // 1024
    # One emerge at a time; reserve 1 GiB and budget 2 GiB per build worker.
    jobs = max(1, min(cpus, (memory - 1024) // 2048))
    vendor_match = re.search(r'^vendor_id\s*:\s*(\S+)', text(proc / 'cpuinfo'), re.M)
    vendor = vendor_match[1] if vendor_match else ''
    if vendor not in ('GenuineIntel', 'AuthenticAMD'):
        raise ValueError('CPU vendor could not be identified as Intel or AMD')
    gpus = []
    for path in sorted((sysfs / 'bus/pci/devices').glob('*')):
        if text(path / 'class').startswith('0x03'):
            try:
                model = subprocess.run(['lspci', '-Dnn', '-s', path.name], capture_output=True, text=True, check=False).stdout.strip()
            except FileNotFoundError:
                model = ''
            nodes = [f'/dev/dri/by-path/pci-{path.name}-render' for node in (path / 'drm').glob('renderD*')]
            gpus.append({'slot': path.name, 'vendor': text(path / 'vendor'), 'device': text(path / 'device'), 'model': model, 'render_nodes': nodes,
                         'driver': (path / 'driver').resolve().name if (path / 'driver').exists() else ''})
    outputs = []
    for path in sorted((sysfs / 'class/drm').glob('card*-*')):
        if text(path / 'status') != 'connected':
            continue
        try:
            edid = (path / 'edid').read_bytes()
        except OSError:
            edid = b''
        outputs.append({'name': path.name.split('-', 1)[1], 'modes': text(path / 'modes').splitlines(),
                        'edid': hashlib.sha256(edid).hexdigest() if edid else ''})
    saved = root is not None and any(p.is_file() for p in (root / 'etc/portage/savedconfig').glob('**/sys-kernel/linux-firmware*')
                                    if not p.name.endswith('.pre-install-system'))
    sof = any((p / 'driver').resolve().name.startswith('sof-audio')
              for p in (sysfs / 'bus/pci/devices').glob('*'))
    return {'schema': 1, 'resources': {'jobs': jobs, 'load': cpus, 'emerge_jobs': 1},
            'firmware_use': 'savedconfig' if saved else '-savedconfig', 'sof': sof,
            'cpu_vendor': vendor, 'gpus': gpus, 'outputs': outputs,
            'machine': {key: text(sysfs / 'class/dmi/id' / key) for key in ('sys_vendor', 'product_name', 'product_version')},
            'backlights': [p.name for p in sorted((sysfs / 'class/backlight').glob('*'))]}


def choose(plan, requested, read=input):
    families = list(dict.fromkeys(requested))
    for device in plan['gpus']:
        print(f'Detected: {device.get("model") or device["slot"]}; PCI {device["vendor"]}:{device.get("device", "?")}; kernel driver {device["driver"] or "unbound"}', file=sys.stderr)
    if not families:
        for device in plan['gpus']:
            vendor, driver = device['vendor'], device['driver']
            if vendor == '0x1002' and driver == 'amdgpu':
                family = 'amd'
            elif vendor == '0x8086' and driver == 'xe':
                family = 'intel-modern'
            elif vendor == '0x8086' and re.search(r'2nd Generation|Sandybridge|HD Graphics 3000', device.get('model', ''), re.I):
                family = 'intel-legacy'
            elif driver in ('virtio-pci', 'virtio_gpu', 'vmwgfx', 'qxl', 'bochs'):
                family = 'virtual'
            else:
                options = (('intel-legacy', 'intel-modern') if vendor == '0x8086' else
                           ('amd', 'radeon') if vendor == '0x1002' else
                           ('nvidia-open', 'nvidia-closed') if vendor == '0x10de' else FAMILIES)
                for index, option in enumerate(options, 1):
                    print(f'{index}) {DESCRIPTIONS[option]} [{option}]', file=sys.stderr)
                family = read('Graphics driver number (or policy name): ').strip()
                if family.isdigit() and 1 <= int(family) <= len(options):
                    family = options[int(family) - 1]
                if family not in options:
                    raise ValueError('choose an explicit supported graphics policy with --graphics')
            if family not in families:
                families.append(family)
    if not plan['gpus'] and not families:
        family = read('No PCI display found. Use virtual/software graphics? [y/N]: ').strip().lower()
        if family in ('y', 'yes'):
            families = ['virtual']
    if not families or any(f not in FAMILIES for f in families):
        raise ValueError('graphics selection is required; use --graphics FAMILY[,FAMILY]')
    if {'nvidia-open', 'nvidia-closed'} <= set(families):
        raise ValueError('NVIDIA GPUs must use one common kernel module variant')
    if len(families) > 1 and not requested:
        for index, family in enumerate(families, 1):
            print(f'{index}) {DESCRIPTIONS[family]}', file=sys.stderr)
        selected = read('Primary session GPU policy (all listed drivers will be installed) [1]: ').strip() or '1'
        if not selected.isdigit() or not 1 <= int(selected) <= len(families):
            raise ValueError('invalid primary GPU selection')
        families.insert(0, families.pop(int(selected) - 1))
    # With multiple GPUs, the first selected policy determines the session renderer.
    profile = ('intel-x220' if families[0] == 'intel-legacy' else
               'nvidia' if families[0].startswith('nvidia') else 'mesa')
    plan['graphics'] = {'families': families, 'profile': profile}
    for family in families:
        print(f'Selected: {DESCRIPTIONS[family]} [{family}]', file=sys.stderr)
    return plan


def render_text(content, plan):
    r = plan['resources']
    card_names = {'amd': 'amdgpu radeonsi', 'radeon': 'radeon r600 r300', 'virtual': 'virgl vmware'}
    cards = {'intel' if f.startswith('intel') else 'nvidia' if f.startswith('nvidia') else card_names[f]
             for f in plan['graphics']['families']}
    for key, value in {'BUILD_JOBS': r['jobs'], 'BUILD_LOAD': r['load'],
                       'EMERGE_JOBS': 1, 'VIDEO_CARDS': ' '.join(sorted(cards)),
                       'FIRMWARE_USE': plan['firmware_use']}.items():
        content = content.replace('@' + key + '@', str(value))
    if re.search(r'@[A-Z_]+@', content):
        raise ValueError('unexpanded hardware template')
    return content


def render(plan, destination, templates):
    for stage in ('resources', 'minimal', 'dwl', 'full'):
        sources = [templates / 'common' / stage]
        if stage == 'minimal' and plan['cpu_vendor'] == 'GenuineIntel':
            sources.append(templates / 'intel-cpu/minimal')
        if stage == 'minimal' and plan.get('sof'):
            sources.append(templates / 'sof/minimal')
        if stage in ('dwl', 'full'):
            sources += [templates / f / stage for f in plan['graphics']['families']]
        files = {}
        for source in sources:
            for path in sorted(source.rglob('*')):
                if path.is_file():
                    relative = path.relative_to(source)
                    files[relative] = files.get(relative, '') + render_text(path.read_text(), plan)
        for relative, content in files.items():
            path = destination / stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('probe', 'select', 'refresh-displays', 'field', 'render', 'template'))
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--graphics', default='')
    parser.add_argument('--non-interactive', action='store_true')
    parser.add_argument('--existing', action='store_true')
    parser.add_argument('--field')
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--template', type=Path)
    parser.add_argument('--templates', type=Path)
    parser.add_argument('--no-graphics', action='store_true')
    args = parser.parse_args()
    if args.action in ('probe', 'select'):
        def answer(message):
            if args.non_interactive:
                raise ValueError(message + 'supply --graphics to the installer')
            with open('/dev/tty', 'r+') as tty:
                tty.write(message)
                tty.flush()
                return tty.readline()
        plan = probe(root=Path('/') if args.existing else None) if args.action == 'probe' else json.loads(args.plan.read_text())
        if args.no_graphics:
            plan['graphics'] = {'families': [], 'profile': 'auto'}
        else:
            plan = choose(plan, args.graphics.split(',') if args.graphics else [], answer)
        print(json.dumps(plan, sort_keys=True, indent=2))
        return
    plan = json.loads(args.plan.read_text())
    if plan.get('schema') != 1:
        raise ValueError('unsupported hardware settings')
    if args.action == 'refresh-displays':
        current = probe()
        for key in ('outputs', 'backlights', 'machine'):
            plan[key] = current[key]
        print(json.dumps(plan, sort_keys=True, indent=2))
    elif args.action == 'render':
        render(plan, args.destination, args.templates)
    elif args.action == 'template':
        print(render_text(args.template.read_text(), plan), end='')
    else:
        value = plan
        for key in args.field.split('.'):
            value = value[key]
        print(json.dumps(value) if isinstance(value, (list, dict)) else value)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'hardware: {error}', file=sys.stderr)
        sys.exit(1)
