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
    'intel-modern': 'Intel iHD VA-API (Broadwell+); Vulkan rendering',
    'amd': 'AMD amdgpu/radeonsi (GCN and newer); Vulkan rendering',
    'radeon': 'Older AMD Radeon (r600/r300); GLES2 rendering',
    'nvidia-open': 'NVIDIA open kernel modules (Turing+); Vulkan rendering',
    'nvidia-closed': 'NVIDIA proprietary 580 branch (older supported GPUs); Vulkan rendering',
    'virtual': 'Virtual/software display (virtio, VMware, QXL); Mesa GLES2',
}
COLORS = {'red': '1;91', 'green': '1;92', 'yellow': '1;93', 'blue': '1;94', 'cyan': '1;96'}


def paint(color, message, stream):
    # Colors as in the installer, only on a terminal; NO_COLOR or TERM=dumb keep plain text.
    if os.environ.get('NO_COLOR') or os.environ.get('TERM', 'dumb') == 'dumb' or not stream.isatty():
        return message
    return f'\033[{COLORS[color]}m{message}\033[0m'


def text(path):
    try:
        return path.read_text().strip()
    except OSError:
        return ''


def input_bits(path):
    words = text(path).split()
    return int(words[-1], 16) if words else 0


def edid_size(edid):
    # Physical size in millimetres from the first detailed timing, otherwise from the
    # basic size in centimetres. Projectors report none; many TVs report only their
    # aspect ratio, such as 1600x900, which is no size either.
    if len(edid) < 128 or edid[:8] != b'\x00\xff\xff\xff\xff\xff\xff\x00':
        return []
    width, height = edid[66] | (edid[68] >> 4) << 8, edid[67] | (edid[68] & 0x0f) << 8
    if not (edid[54] or edid[55]) or not (width and height):
        width, height = edid[21] * 10, edid[22] * 10
    if (width, height) in {(16, 9), (16, 10), (160, 90), (160, 100), (1600, 900), (1600, 1000)}:
        return []
    return [width, height] if width and height else []


def firmware_list(path):
    return [line.strip() for line in text(path).splitlines() if line.strip() and not line.startswith('#')]


def saved_firmware_lists(root):
    # Portage applies a list named after a version only to that version; the plain name
    # applies to all of them. Lists kept aside by the installer end in .pre-install-system.
    return {path.name: firmware_list(path) for path in sorted((root / 'etc/portage/savedconfig/sys-kernel').glob('linux-firmware*'))
            if path.is_file() and not path.name.endswith('.pre-install-system')}


def firmware_files(base):
    # Files and links as linux-firmware lists them: relative, without compression suffix.
    return {re.sub(r'\.(xz|zst)$', '', str(path.relative_to(base))): path
            for path in sorted(base.rglob('*')) if path.is_file() or path.is_symlink()}


def firmware_size(entries, files):
    return sum(files[entry].stat().st_size for entry in entries
               if entry in files and files[entry].is_file() and not files[entry].is_symlink())


# Drivers that log every firmware file they load: with a complete kernel log, no such
# line means the device needs none (i915 on Sandy Bridge, for example).
LOGGING_DRIVERS = ('i915', 'iwlwifi')


def kernel_log():
    try:
        return subprocess.run(['dmesg'], capture_output=True, text=True, check=False).stdout
    except FileNotFoundError:
        return ''


def suggested_firmware(files, sysfs=Path('/sys'), modules_dir=Path('/lib/modules', os.uname().release),
                       modinfo='modinfo', log=None):
    # Drivers declare the firmware they may request, but only their newest API versions:
    # iwlwifi asks for 6000-6 and falls back to 6000-4. The kernel log names what was
    # loaded; without that, the whole family before the version number is kept.
    declared = {}
    for driver in sysfs.glob('bus/*/devices/*/driver'):
        driver = driver.resolve()
        declared[(driver / 'module').resolve().name if (driver / 'module').exists() else driver.name] = set()
    try:
        records = (modules_dir / 'modules.builtin.modinfo').read_bytes().split(b'\0')
    except OSError:
        records = []
    for record in records:
        module, _, field = record.decode(errors='replace').partition('.')
        if module in declared and field.startswith('firmware='):
            declared[module].add(field[len('firmware='):])
    for module in sorted(declared):
        try:
            result = subprocess.run([modinfo, '-F', 'firmware', module], capture_output=True, text=True, check=False)
        except FileNotFoundError:
            break
        declared[module].update(line for line in result.stdout.splitlines() if line)
    log = kernel_log() if log is None else log
    # The log drops its oldest lines first. While the PCI bus scan that precedes every
    # driver is still there, so are the drivers' firmware lines.
    complete = 'Linux version' in log or 'root bus resource' in log
    loaded = {word.strip(',:;()"\'[]') for line in log.splitlines() if 'fail' not in line.lower()
              for word in line.split()} - {''}
    regular = {path.resolve(): name for name, path in files.items() if path.is_file() and not path.is_symlink()}
    chosen = set()
    for module, names in declared.items():
        prefixes = {family for name in names
                    if (family := re.sub(r'[0-9][0-9.]*\.[A-Za-z0-9]+$', '', name)) and family != name}
        family = [entry for entry in files if entry in names or any(entry.startswith(prefix) for prefix in prefixes)]
        seen = [entry for entry in family if complete and
                any(entry == word or entry.endswith(('/' + word, '-' + word)) for word in loaded)]
        if seen:
            # Keep what was loaded with its other API versions, such as a matching .pnvm.
            stems = {re.sub(r'(-[0-9][0-9.]*)?\.[A-Za-z0-9]+$', '', entry) for entry in seen}
            family = [entry for entry in family if any(entry.startswith((stem + '-', stem + '.')) for stem in stems)]
        elif complete and module in LOGGING_DRIVERS:
            family = []
        for entry in family:
            chosen.add(entry)
            if files[entry].is_symlink() and files[entry].resolve() in regular:
                chosen.add(regular[files[entry].resolve()])
    return sorted(chosen)


def choose_firmware(plan, root, read, interactive, base=Path('/lib/firmware'), **detection):
    # The chosen list gets the plain name, so it applies to every linux-firmware version.
    lists = saved_firmware_lists(root) if root is not None else {}
    files = firmware_files(base) if base.is_dir() else {}
    def megabytes(entries):
        size = firmware_size(entries, files) / 1048576
        return f'{size:.1f} MB' if size < 10 else f'{size:.0f} MB'
    suggested = suggested_firmware(files, **detection) if files else []
    chosen = None
    # A plain-named list is the user's own file; the installer writes only lists it chose.
    plan['firmware_owner'] = 'user' if 'linux-firmware' in lists else 'installer'
    if 'linux-firmware' in lists:
        chosen = lists['linux-firmware']
    elif lists and len({tuple(entries) for entries in lists.values()}) == 1:
        chosen = next(iter(lists.values()))
    elif lists and interactive:
        options = [(f'{name}: {len(entries)} files, {megabytes(entries)}', entries) for name, entries in lists.items()]
        if suggested:
            options.append((f'suggested for this computer: {len(suggested)} files, {megabytes(suggested)}', suggested))
        options.append((f'all firmware: {megabytes(list(files))}', None))
        default = min(range(len(lists)), key=lambda index: len(options[index][1])) + 1
        print(paint('blue', 'Saved firmware lists differ; the chosen one applies to every linux-firmware version:', sys.stderr), file=sys.stderr)
        for number, (label, _) in enumerate(options, 1):
            print(f'{number}) {label}', file=sys.stderr)
        answer = read(f'Firmware list number [{default}]: ').strip() or str(default)
        if not answer.isdigit() or not 1 <= int(answer) <= len(options):
            raise ValueError('invalid firmware list number')
        chosen = options[int(answer) - 1][1]
    elif not lists and suggested and interactive:
        answer = read(f'Install only the firmware this computer\'s drivers use: {len(suggested)} files, {megabytes(suggested)} '
                      f'instead of {megabytes(list(files))}? [Y/n]: ').strip().lower()
        chosen = None if answer in ('n', 'no') else suggested
    plan['firmware_list'] = chosen
    # Without a choice, saved version-specific lists keep working as before.
    keep_saved = chosen is None and lists and not interactive
    plan['firmware_use'] = 'savedconfig' if chosen is not None or keep_saved else '-savedconfig'
    summary = (f'{len(chosen)} listed file{"" if len(chosen) == 1 else "s"}' if chosen is not None else
               'saved version-specific lists' if keep_saved else 'all')
    print(paint('green', f'Firmware: {summary}', sys.stderr), file=sys.stderr)
    return plan


def pointers(sysfs):
    # Mice and pointing sticks report relative X/Y. Touchpads report absolute X/Y
    # with the pointer property but without the direct (touchscreen) property.
    names = []
    for device in sorted((sysfs / 'class/input').glob('event*/device')):
        relative = input_bits(device / 'capabilities/rel') & 3 == 3
        touchpad = input_bits(device / 'capabilities/abs') & 3 == 3 and input_bits(device / 'properties') & 3 == 1
        name = text(device / 'name')
        if (relative or touchpad) and name and name not in names:
            names.append(name)
    return names


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
                        'edid': hashlib.sha256(edid).hexdigest() if edid else '', 'size_mm': edid_size(edid)})
    saved = root is not None and any(p.is_file() for p in (root / 'etc/portage/savedconfig').glob('**/sys-kernel/linux-firmware*')
                                    if not p.name.endswith('.pre-install-system'))
    sof = any((p / 'driver').resolve().name.startswith('sof-audio')
              for p in (sysfs / 'bus/pci/devices').glob('*'))
    return {'schema': 1, 'resources': {'jobs': jobs, 'load': cpus, 'emerge_jobs': 1},
            'firmware_use': 'savedconfig' if saved else '-savedconfig', 'sof': sof,
            'cpu_vendor': vendor, 'gpus': gpus, 'outputs': outputs,
            'machine': {key: text(sysfs / 'class/dmi/id' / key) for key in ('sys_vendor', 'product_name', 'product_version')},
            'backlights': [p.name for p in sorted((sysfs / 'class/backlight').glob('*'))],
            'pointers': pointers(sysfs)}


def choose(plan, requested, read=input):
    families = list(dict.fromkeys(requested))
    for device in plan['gpus']:
        print(paint('cyan', f'Detected: {device.get("model") or device["slot"]}; PCI {device["vendor"]}:{device.get("device", "?")}; kernel driver {device["driver"] or "unbound"}', sys.stderr), file=sys.stderr)
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
        print(paint('green', f'Selected: {DESCRIPTIONS[family]} [{family}]', sys.stderr), file=sys.stderr)
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
        # The chosen firmware list has the plain name, so it applies to every version.
        firmware = destination / stage / 'savedconfig/sys-kernel/linux-firmware'
        if stage == 'minimal' and plan.get('firmware_list') is not None and plan.get('firmware_owner') != 'user':
            firmware.parent.mkdir(parents=True, exist_ok=True)
            firmware.write_text('# Firmware to install; linux-firmware leaves out every other file.\n'
                                + ''.join(f'{entry}\n' for entry in plan['firmware_list']))
        elif stage == 'minimal':
            firmware.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('probe', 'select', 'firmware', 'refresh-displays', 'field', 'render', 'template'))
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
    if args.action in ('probe', 'select', 'firmware'):
        def answer(message):
            if args.non_interactive:
                raise ValueError(message + 'supply --graphics to the installer')
            # A terminal cannot seek, so it gets separate read and write streams ('r+' fails).
            with open('/dev/tty') as tty_in, open('/dev/tty', 'w') as tty_out:
                tty_out.write(paint('yellow', message, tty_out))
                tty_out.flush()
                return tty_in.readline()
        if args.action == 'firmware':
            plan = choose_firmware(json.loads(args.plan.read_text()), Path('/') if args.existing else None,
                                   answer, not args.non_interactive)
            print(json.dumps(plan, sort_keys=True, indent=2))
            return
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
        for key in ('outputs', 'backlights', 'machine', 'pointers'):
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
        print(paint('red', f'hardware: {error}', sys.stderr), file=sys.stderr)
        sys.exit(1)
