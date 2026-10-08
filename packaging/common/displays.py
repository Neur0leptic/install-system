#!/usr/bin/env python3
"""Collect portable desktop settings; never change the running display configuration."""

import argparse
import json
import math
from pathlib import Path
import re
import sys

from hardware import paint, probe

# GPU families whose drivers are installed with Vulkan; the others render with GLES2.
VULKAN_FAMILIES = ('intel-modern', 'amd', 'nvidia-open', 'nvidia-closed')
SIDES = ('left', 'right', 'above', 'below')


def device_name(name):
    # DWL and Hyprland match input devices by name, lower-cased with hyphens for spaces.
    return ''.join('-' if c == ' ' else c.lower() if 'A' <= c <= 'Z' else c for c in name)


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
    for key in ('keyboardLayout', 'keyboardOptions', 'backlight', 'wireguardProfile'):
        if not isinstance(settings[key], str) or not re.fullmatch(r'[A-Za-z0-9_:+,.-]*', settings[key]):
            raise ValueError(f'invalid {key}')
    # Device names may contain slashes and parentheses, as in "TPPS/2 IBM TrackPoint".
    if not isinstance(settings['mouse'], str):
        raise ValueError('invalid mouse')
    settings['mouse'] = device_name(settings['mouse'])
    if not re.fullmatch(r'[a-z0-9_:+,./()-]*', settings['mouse']):
        raise ValueError('invalid mouse')
    if not settings['keyboardLayout']:
        raise ValueError('keyboard layout must not be empty')
    if not re.fullmatch(r'(?:/dev/dri/(?:by-path/[A-Za-z0-9_:.-]+|renderD[0-9]+))?', settings['renderDevice']):
        raise ValueError('render device must be empty or a DRM render-node path')
    if type(settings['sensitivity']) not in (int, float) or not math.isfinite(settings['sensitivity']) or not -1 <= settings['sensitivity'] <= 1:
        raise ValueError('mouse sensitivity must be between -1 and 1')
    return settings


def choose_mode(name, modes, suggested, read, report):
    # The kernel lists a display's modes native first and without refresh rates.
    modes = list(dict.fromkeys(modes))
    report(f'{name} resolutions:')
    for number, mode in enumerate(modes, 1):
        report(f'  {number}) {mode}' + (' (native)' if number == 1 else ''))
    report('To set a refresh rate, type WIDTHxHEIGHT@HZ, for example 2560x1440@144.')
    # "preferred" follows the display's native mode, so the suggestion names that mode.
    shown = f'native {modes[0] if modes else "mode"}' if suggested == 'preferred' else suggested
    answer = read(f'{name} resolution: number or WIDTHxHEIGHT@HZ [{shown}]: ')
    if not answer:
        return suggested
    if answer.isdigit():
        if not 1 <= int(answer) <= len(modes):
            raise ValueError(f'{name} has no resolution with that number')
        return modes[int(answer) - 1]
    return answer


def mode_size(mode, modes):
    # "preferred" stands for the native mode, which the kernel lists first.
    match = re.match(r'([0-9]+)x([0-9]+)', modes[0] if mode == 'preferred' and modes else mode)
    return (int(match[1]), int(match[2])) if match else None


def suggested_scale(size, size_mm):
    # Pixel density decides how large text appears. Laptop panels are viewed from closer,
    # so they get a denser target. Displays without a physical size and TV-sized ones,
    # watched from afar, follow the resolution instead.
    if not size:
        return 1.0
    if len(size_mm) == 2 and min(size_mm) > 0:
        diagonal = math.hypot(*size_mm) / 25.4
        if 10 <= diagonal <= 50:
            density = math.hypot(*size) / diagonal
            return min(3.0, max(1.0, round(density / (135 if diagonal < 20 else 110) * 4) / 4))
    return 1.0 if size[1] <= 1200 else 1.5 if size[1] <= 1600 else 2.0


def side_of(current, previous):
    # Saved positions suggest their side again, such as "right" for 1920,0 beside 0,0.
    if 'auto' in (current['position'], previous['position']):
        return 'right'
    (cx, cy), (px, py) = (map(int, o['position'].split(',')) for o in (current, previous))
    if abs(cx - px) >= abs(cy - py):
        return 'right' if cx >= px else 'left'
    return 'below' if cy > py else 'above'


def split_tags(count):
    # Ten tags in groups that are as even as possible: two displays get 1-5 and 6-10.
    size, extra = divmod(10, count)
    groups, start = [], 1
    for index in range(count):
        end = start + size + (index < extra)
        groups.append(list(range(start, end)))
        start = end
    return groups


def arrange(selected, modes, saved, read, report):
    # Each display is placed beside the previous one; the pixel positions follow from the
    # answers, using the size the display has after scaling.
    report('Arrangement (where the displays stand on your desk):')
    sides, suggestions = [], []
    for previous, current in zip(selected, selected[1:]):
        suggested = side_of(current, previous)
        answer = read(f'Where is {current["name"]} relative to {previous["name"]}? left, right, above or below [{suggested}]: ') or suggested
        if answer not in SIDES:
            raise ValueError(f'answer left, right, above or below for {current["name"]}')
        sides.append(answer)
        suggestions.append(suggested)
    # Saved positions may carry offsets, such as 1920,200; they stay as they are while
    # the sides, resolutions and scales match the saved settings.
    if sides == suggestions and all(known.get('position', 'auto') != 'auto' and known.get('mode') == output['mode'] and
                                    known.get('scale') == output['scale'] for output, known in zip(selected, saved)):
        report('Positions: kept from the saved settings.')
    else:
        sizes = []
        for output in selected:
            width, height = mode_size(output['mode'], modes[output['name']]) or (0, 0)
            sizes.append((round(width / output['scale']), round(height / output['scale'])))
        positions = [(0, 0)]
        for side, (pw, ph), (cw, ch) in zip(sides, sizes, sizes[1:]):
            x, y = positions[-1]
            positions.append({'left': (x - cw, y), 'right': (x + pw, y), 'above': (x, y - ch), 'below': (x, y + ph)}[side])
        left, top = min(x for x, _ in positions), min(y for _, y in positions)
        for output, (x, y) in zip(selected, positions):
            output['position'] = f'{x - left},{y - top}'
    report('Tags (workspaces); switching to a tag moves to the display that holds it:')
    order = sorted(selected, key=lambda o: tuple(map(int, o['position'].split(','))))
    keep = all(known.get('tags') for known in saved)
    for output, group in zip(order, split_tags(len(order))):
        tags = output['tags'] if keep else group
        answer = read(f'Tags on {output["name"]}: comma-separated, - = none [{",".join(map(str, tags)) or "none"}]: ')
        output['tags'] = ([] if answer == '-' else [int(t) for t in answer.split(',') if t]) if answer else tags


def choose_mouse(inventory, current, read, report):
    detected = [device_name(name) for name in inventory.get('pointers', [])]
    if not detected:
        return current
    report('Pointing devices (all use the default speed):')
    for number, name in enumerate(detected, 1):
        report(f'  {number}) {name}')
    answer = read(f'Give one of them its own speed: number or name, - = none [{current or "none"}]: ')
    if not answer:
        return current
    if answer == '-':
        return ''
    if answer.isdigit():
        if not 1 <= int(answer) <= len(detected):
            raise ValueError('no pointing device has that number')
        return detected[int(answer) - 1]
    # A name also covers a mouse that is not connected during installation.
    return device_name(answer)


def prompt(inventory, defaults=None, read=input, report=print, desktop='dwl', keep_wireguard=False):
    # Only preferences are asked. The renderer and color mode follow the GPU; video
    # decoding, backlight and render device stay automatic unless saved settings or a
    # preset name them.
    defaults = defaults or {}
    detected = inventory.get('outputs', [])
    families = inventory.get('graphics', {}).get('families', [])
    renderer = defaults.get('renderer') or ('vulkan' if families[:1] and families[0] in VULKAN_FAMILIES
                                            else 'gles2' if families else 'auto')
    # DWL uses wide color only where a display supports it and otherwise keeps sRGB.
    # Hyprland's template forces it, so new displays start with sRGB there.
    color = 'wide' if renderer == 'vulkan' and desktop == 'dwl' else 'srgb'
    report('Press Enter to accept the suggestion in brackets.')
    if len(detected) > 1:
        report('Connected displays:')
        for output in detected:
            report(f'  {output["name"]} (native {output["modes"][0] if output["modes"] else "mode unknown"})')
    outputs, selected, saved, modes = [], [], [], {}
    for output in detected:
        name = output['name']
        modes[name] = output.get('modes', [])
        known = next((o for o in defaults.get('outputs', []) if o['name'] == name and
                      o.get('edid') and o['edid'] == output.get('edid')), {})
        # A display the saved settings keep off stays off unless the answer turns it on.
        if known.get('enabled') is False and \
                read(f'{name} is turned off in the saved settings. Keep it off? [Y/n]: ').lower() not in ('n', 'no'):
            # Its saved settings stay for the day it is turned on again.
            outputs.append({**known, 'name': name, 'enabled': False, 'edid': output.get('edid', '')})
            continue
        mode = choose_mode(name, modes[name], known.get('mode', 'preferred'), read, report)
        scale = known.get('scale') or suggested_scale(mode_size(mode, modes[name]), output.get('size_mm', []))
        scale = float(read(f'{name} scale: how large everything appears, 1 = normal, 2 = double [{scale:g}]: ') or scale)
        selected.append({'name': name, 'mode': mode, 'scale': scale, 'position': known.get('position', 'auto'),
                         'enabled': True, 'tags': known.get('tags', []), 'color': known.get('color', color),
                         'edid': output.get('edid', '')})
        outputs.append(selected[-1])
        saved.append(known)
    # Placement and tag routing only matter with more than one display in use.
    several = len(selected) > 1
    if several:
        arrange(selected, modes, saved, read, report)
    # Tags belong to the displays in use; a turned-off display keeps only the unused ones.
    used = {tag for output in selected for tag in output['tags']}
    for output in outputs:
        if output['enabled'] is False:
            output['tags'] = [tag for tag in output.get('tags', []) if tag not in used]
    settings = {**defaults, 'schema': 1, 'outputs': outputs, 'machine': inventory.get('machine', {}), 'renderer': renderer}
    settings.setdefault('vaapi', 'i965' if families == ['intel-legacy'] else 'auto')
    layouts = settings.get('keyboardLayout', 'us')
    settings['keyboardLayout'] = read(f'Keyboard layouts: one or more, comma-separated, e.g. us or us,de,tr; the first is the default [{layouts}]: ') or layouts
    options = settings.get('keyboardOptions', 'grp:alt_shift_toggle')
    if ',' in settings['keyboardLayout']:
        answer = read(f'Keyboard options: grp:alt_shift_toggle switches layouts with Alt+Shift, - = none [{options or "none"}]: ') or options
        options = '' if answer == '-' else answer
    settings['keyboardOptions'] = options
    settings['mouse'] = choose_mouse(inventory, settings.get('mouse', ''), read, report)
    if settings['mouse']:
        default = settings.get('sensitivity', 0)
        settings['sensitivity'] = float(read(f'{settings["mouse"]} speed: -1 = slowest, 0 = default, 1 = fastest [{default:g}]: ') or default)
    # The WireGuard stage asks for the VPN identity. Only a profile already saved for this
    # computer is kept; presets never name one.
    if not keep_wireguard:
        settings['wireguardProfile'] = ''
    result = normalize(settings)
    native = {o['name']: o['modes'][0] if o.get('modes') else 'native mode' for o in detected}
    report('Summary:')
    for output in result['outputs']:
        if not output['enabled']:
            report(f'  {output["name"]}: off')
            continue
        details = [f'{native.get(output["name"], "native mode")} (native)' if output['mode'] == 'preferred' else output['mode'],
                   f'scale {output["scale"]:g}']
        if several:
            details += [f'position {output["position"]}', 'tags ' + (','.join(map(str, output['tags'])) or 'none')]
        details.append(('wide color where supported' if desktop == 'dwl' else 'wide color') if output['color'] == 'wide' else 'sRGB')
        report(f'  {output["name"]}: {", ".join(details)}')
    if not result['outputs']:
        report('  Displays: automatic')
    report(f'  Graphics: renderer {result["renderer"]}, video decoding {result["vaapi"]}'
           + (f', {result["renderDevice"]}' if result['renderDevice'] else '')
           + (f', brightness {result["backlight"]}' if result['backlight'] else ''))
    report(f'  Keyboard: {result["keyboardLayout"]}' + (f' ({result["keyboardOptions"]})' if result['keyboardOptions'] else ''))
    report('  Pointer speed: ' + (f'{result["mouse"]} {result["sensitivity"]:g}' if result['mouse'] else 'default'))
    if result['wireguardProfile']:
        report(f'  WireGuard: {result["wireguardProfile"]}')
    if read('Save these settings? [y/N]: ').lower() not in ('y', 'yes'):
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
    # Keeps a WireGuard profile that the saved settings of this computer already name.
    parser.add_argument('--wireguard-profiles', action='store_true')
    parser.add_argument('--desktop', choices=('dwl', 'hyprland'), default='dwl')
    args = parser.parse_args()
    if args.input:
        result = normalize(json.loads(args.input.read_text()))
    else:
        # A terminal cannot seek, so it gets separate read and write streams ('r+' fails).
        with open('/dev/tty') as tty_in, open('/dev/tty', 'w') as tty_out:
            # Yes/no decisions are yellow, section headings blue and suggestions cyan.
            def read(message):
                suggestion = re.fullmatch(r'(.*)(\[[^\[\]]*\]): ', message, re.S)
                if message.endswith(('[y/N]: ', '[Y/n]: ')):
                    message = paint('yellow', message, tty_out)
                elif suggestion:
                    message = suggestion[1] + paint('cyan', suggestion[2], tty_out) + ': '
                tty_out.write(message)
                tty_out.flush()
                answer = tty_in.readline()
                if not answer:
                    raise ValueError('display prompt reached EOF')
                return answer.strip()
            def report(message):
                tty_out.write((paint('blue', message, tty_out) if message.endswith(':') else message) + '\n')
                tty_out.flush()
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
                        if read(f'Saved settings "{name}" match this computer model. Use them as suggestions? [y/N]: ').lower() in ('y', 'yes'):
                            defaults = preset['settings']
                        break
            result = prompt(inventory, defaults, read, report, args.desktop, args.wireguard_profiles)
    if args.check_hardware:
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
        print(paint('red', f'displays: {error}', sys.stderr), file=sys.stderr)
        sys.exit(1)
