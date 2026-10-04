#!/usr/bin/env python3
"""Collect portable desktop settings; never change the running display configuration."""

import argparse
import json
import math
from pathlib import Path
import re
import sys


def normalize(value):
    fields = {'schema', 'outputs', 'machine', 'renderer', 'renderDevice', 'vaapi', 'keyboardLayout',
              'keyboardOptions', 'mouse', 'sensitivity', 'backlight', 'wireguardProfile'}
    if not isinstance(value, dict) or value.get('schema') != 1 or set(value) - fields:
        raise ValueError('display JSON needs schema=1 and an outputs list')
    outputs = value['outputs']
    if not isinstance(outputs, list) or not 0 <= len(outputs) <= 16:
        raise ValueError('configure between 0 and 16 outputs (0 uses compositor defaults)')
    result, names, assigned_tags = [], set(), set()
    for item in outputs:
        if not isinstance(item, dict) or set(item) - {'name', 'mode', 'scale', 'enabled', 'position', 'tags', 'color', 'edid'}:
            raise ValueError('invalid output entry')
        name = item.get('name', '')
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,63}', name) or name in names:
            raise ValueError(f'invalid or duplicate output name: {name!r}')
        position = item.get('position', 'auto')
        if not isinstance(position, str) or (position != 'auto' and not re.fullmatch(r'-?[0-9]{1,5},-?[0-9]{1,5}', position)):
            raise ValueError('position must be auto or X,Y in logical pixels')
        enabled, mode, scale = item.get('enabled', True), item.get('mode', 'preferred'), item.get('scale', 1)
        if not isinstance(enabled, bool):
            raise ValueError('enabled must be a boolean')
        if not isinstance(mode, str) or (mode != 'preferred' and not re.fullmatch(r'[1-9][0-9]{1,4}x[1-9][0-9]{1,4}(?:@[1-9][0-9]{0,3}(?:\.[0-9]{1,3})?)?', mode)):
            raise ValueError(f'invalid output mode: {mode!r}')
        if isinstance(scale, bool) or not isinstance(scale, (float, int)) or not math.isfinite(scale) or not 0.5 <= scale <= 4:
            raise ValueError('scale must be a finite number between 0.5 and 4')
        names.add(name)
        tags = item.get('tags', [])
        if not isinstance(tags, list) or any(type(t) is not int or not 1 <= t <= 10 or t in assigned_tags for t in tags) or len(set(tags)) != len(tags):
            raise ValueError('tags must be unique numbers from 1 to 10 across outputs')
        assigned_tags.update(tags)
        color, edid = item.get('color', 'srgb'), item.get('edid', '')
        if color not in ('srgb', 'wide') or not re.fullmatch(r'(?:[a-f0-9]{64})?', edid):
            raise ValueError('invalid color mode or EDID fingerprint')
        result.append({'name': name, 'enabled': enabled, 'mode': mode, 'scale': float(scale), 'position': position,
                       'tags': tags, 'color': color, 'edid': edid})
    if result and not any(item['enabled'] for item in result):
        raise ValueError('at least one output must be enabled')
    settings = {'schema': 1, 'outputs': result, 'machine': value.get('machine', {})}
    if not isinstance(settings['machine'], dict) or any(not isinstance(v, str) for v in settings['machine'].values()):
        raise ValueError('invalid machine description')
    defaults = {'renderer': 'auto', 'renderDevice': '', 'vaapi': 'auto', 'keyboardLayout': 'us',
                'keyboardOptions': 'grp:alt_shift_toggle', 'mouse': '', 'sensitivity': 0,
                'backlight': '', 'wireguardProfile': ''}
    for key, default in defaults.items():
        settings[key] = value.get(key, default)
    if settings['renderer'] not in ('auto', 'gles2', 'vulkan') or settings['vaapi'] not in ('auto', 'i965', 'iHD', 'radeonsi', 'nvidia'):
        raise ValueError('invalid renderer or video acceleration driver')
    for key in ('keyboardLayout', 'keyboardOptions', 'mouse', 'backlight', 'wireguardProfile'):
        if not isinstance(settings[key], str) or not re.fullmatch(r'[A-Za-z0-9_:+,.-]*', settings[key]):
            raise ValueError(f'invalid {key}')
    if not settings['keyboardLayout']:
        raise ValueError('keyboard layout must not be empty')
    if not re.fullmatch(r'(?:/dev/dri/(?:by-path/[A-Za-z0-9_:.-]+|renderD[0-9]+))?', settings['renderDevice']):
        raise ValueError('render device must be empty or a DRM render-node path')
    if type(settings['sensitivity']) not in (int, float) or not math.isfinite(settings['sensitivity']) or not -1 <= settings['sensitivity'] <= 1:
        raise ValueError('mouse sensitivity must be between -1 and 1')
    return settings


def prompt(inventory, defaults=None, read=input, report=print):
    defaults = defaults or {}
    detected = inventory.get('outputs', [])
    report('Connected outputs (physical modes; scale is a separate preference):')
    for output in detected:
        report(f'  {output["name"]}: {", ".join(output["modes"]) or "mode list unavailable"}')
    count = int(read(f'How many displays should be configured? (0 = automatic) [{len(detected)}]: ') or len(detected))
    if not 0 <= count <= 16:
        raise ValueError('display count must be between 0 and 16')
    selected = []
    for index in range(count):
        suggested = detected[index]['name'] if index < len(detected) else ''
        name = read(f'Display {index + 1} connector [{suggested}]: ') or suggested
        matches = [item for item in detected if item['name'] == name]
        known = matches[0] if len(matches) == 1 else {}
        suggested_mode, suggested_scale, suggested_position = 'preferred', '1', 'auto'
        saved = next((o for o in defaults.get('outputs', []) if o['name'] == name and
                      o.get('edid') and o['edid'] == known.get('edid')), {})
        suggested_mode = saved.get('mode', suggested_mode)
        suggested_scale = str(saved.get('scale', suggested_scale))
        suggested_position = saved.get('position', suggested_position)
        mode = read(f'{name} physical resolution [preferred or WIDTHxHEIGHT@HZ; {suggested_mode}]: ') or suggested_mode
        scale = float(read(f'{name} scale [{suggested_scale}]: ') or suggested_scale)
        position = read(f'{name} position in logical pixels [auto or X,Y; {suggested_position}]: ') or suggested_position
        tag_default = ','.join(map(str, saved.get('tags', [])))
        tags = read(f'{name} workspace/tag numbers, comma-separated (- = unbound) [{tag_default}]: ') or tag_default
        if tags == '-':
            tags = ''
        color = read(f'{name} color mode: srgb or wide (requires a capable display) [{saved.get("color", "srgb")}]: ') or saved.get('color', 'srgb')
        selected.append({'name': name, 'mode': mode, 'scale': scale, 'position': position, 'enabled': True,
                         'tags': [int(t) for t in tags.split(',') if t], 'color': color, 'edid': known.get('edid', '')})
    chosen = {item['name'] for item in selected}
    for output in detected if count else []:
        if output['name'] not in chosen:
            selected.append({'name': output['name'], 'enabled': False, 'edid': output.get('edid', '')})
    settings = {**defaults, 'schema': 1, 'outputs': selected, 'machine': inventory.get('machine', {})}
    families = inventory.get('graphics', {}).get('families', [])
    safe = any(f in ('intel-legacy', 'radeon', 'virtual') for f in families)
    renderer = settings.get('renderer', 'gles2' if safe else 'auto')
    report('DWL/MPV renderer: auto lets the application choose; GLES2 supports older GPUs; Vulkan requires driver support. Hyprland uses its own renderer.')
    settings['renderer'] = read(f'DWL/MPV renderer [auto/gles2/vulkan; {renderer}]: ') or renderer
    device = settings.get('renderDevice', '')
    if len(inventory.get('gpus', [])) > 1:
        for gpu in inventory['gpus']:
            report(f'  {gpu.get("model") or gpu["slot"]}: {", ".join(gpu.get("render_nodes", [])) or "render node unavailable"}')
        answer = read(f'Preferred DWL /dev/dri/by-path/...-render node (- = automatic) [{device}]: ') or device
        settings['renderDevice'] = '' if answer == '-' else answer
    vaapi = settings.get('vaapi', 'i965' if families == ['intel-legacy'] else 'auto')
    settings['vaapi'] = read(f'VA-API driver [auto/i965/iHD/radeonsi/nvidia; {vaapi}]: ') or vaapi
    for key, label, default in [('keyboardLayout', 'Keyboard layouts, comma-separated', 'us'),
                                ('keyboardOptions', 'XKB options', 'grp:alt_shift_toggle'),
                                ('mouse', 'Optional mouse name (lowercase, spaces as hyphens; empty = default)', ''),
                                ('backlight', 'Backlight device (empty = automatic)', '')]:
        default = settings.get(key, default)
        answer = read(f'{label} (- clears optional fields) [{default}]: ') or default
        settings[key] = '' if answer == '-' else answer
    if settings['mouse']:
        default = settings.get('sensitivity', 0)
        settings['sensitivity'] = float(read(f'Mouse sensitivity -1 to 1 [{default}]: ') or default)
    # VPN identity is deliberately not inferred from the physical-machine preset.
    default = settings.get('wireguardProfile', '')
    answer = read(f'WireGuard device profile suffix, if already provisioned (- = none) [{default}]: ') or default
    settings['wireguardProfile'] = '' if answer == '-' else answer
    result = normalize(settings)
    report(json.dumps(result, indent=2))
    if read('Use these display settings? [y/N]: ').lower() not in ('y', 'yes'):
        raise ValueError('display settings were not confirmed')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', required=True, type=Path)
    parser.add_argument('--presets', type=Path)
    parser.add_argument('--saved', type=Path)
    parser.add_argument('--check-hardware', action='store_true')
    parser.add_argument('--input', type=Path)
    parser.add_argument('--check-target', type=Path)
    args = parser.parse_args()
    if args.input:
        result = normalize(json.loads(args.input.read_text()))
    else:
        with open('/dev/tty', 'r+') as tty:
            def read(message):
                tty.write(message)
                tty.flush()
                answer = tty.readline()
                if not answer:
                    raise ValueError('display prompt reached EOF')
                return answer.strip()
            def report(message):
                tty.write(message + '\n')
                tty.flush()
            inventory = json.loads(args.inventory.read_text())
            defaults = {}
            if args.saved and args.saved.is_file():
                data = json.loads(args.saved.read_text()).get('data', {})
                saved = json.loads(data.get('machineSettings') or '{}')
                if saved.get('machine') == inventory.get('machine'):
                    defaults = saved
            if not defaults and args.presets and args.presets.is_file():
                presets = json.loads(args.presets.read_text())['machinePresets']
                for name, preset in presets.items():
                    if all(inventory.get('machine', {}).get(k) == v for k, v in preset['match'].items()):
                        if read(f'Hardware matches the {name} preset. Use its preferences as suggestions? [y/N]: ').lower() in ('y', 'yes'):
                            defaults = preset['settings']
                        break
            result = prompt(inventory, defaults, read, report)
    if args.check_hardware:
        from hardware import probe
        current = probe()
        if result['machine'] and result['machine'] != current['machine']:
            raise ValueError('machine changed; review desktop settings')
        connected = {o['name']: o for o in current['outputs']}
        for output in result['outputs']:
            if output['name'] in connected and output['edid'] and output['edid'] != connected[output['name']]['edid']:
                raise ValueError('monitor identity changed; review desktop settings')
    if args.check_target:
        if normalize(json.loads(args.check_target.read_text())) != result:
            raise ValueError('deployed display preferences differ from the approved answers')
    else:
        print(json.dumps(result, sort_keys=True, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f'displays: {error}', file=sys.stderr)
        sys.exit(1)
