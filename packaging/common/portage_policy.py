#!/usr/bin/env python3
"""Deploy layered inputs as native, single-file Portage configuration.

Ownership and interruption records live outside /etc/portage. No package manager
transactions, shell evaluation or package builds are performed by this helper.
"""

import argparse
import configparser
import copy
import difflib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import uuid


PACKAGE_FILES = {
    'package.use', 'package.env', 'package.accept_keywords', 'package.keywords',
    'package.mask', 'package.unmask', 'package.license', 'package.properties',
    'package.accept_restrict', 'package.bashrc',
}
PROFILE_FILES = {
    'use.mask', 'use.force', 'use.stable.mask', 'use.stable.force',
    'package.use', 'package.use.mask', 'package.use.force',
    'package.use.stable.mask', 'package.use.stable.force', 'package.mask',
    'package.unmask', 'package.accept_keywords', 'package.provided', 'packages',
    'package.bashrc',
}
CONFIG_FILES = PACKAGE_FILES | {'repos.conf', 'binrepos.conf'} | {
    'profile/' + name for name in PROFILE_FILES
}
INI_FILES = {'repos.conf', 'binrepos.conf'}
COMPILER_RULES = 'package.env/install-system-compiler'
LEGACY_POLLY_PREFIX = '# install-system-gcc: '


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def target_name(relative):
    parts = Path(relative).parts
    if not parts or relative.startswith('/') or '..' in parts:
        raise ValueError('unsafe policy path: ' + relative)
    name = '/'.join(parts[:2]) if parts[0] == 'profile' else parts[0]
    return name if name in CONFIG_FILES else None


def active_files(path):
    # Match Portage's recursive file traversal, including interleaved directories.
    if path.is_symlink():
        raise ValueError('symlinked configuration: ' + str(path))
    if path.is_file():
        yield path
    elif path.is_dir():
        for child in sorted(path.iterdir()):
            if child.name.startswith('.') or child.name.endswith('~') or (child.is_dir() and child.name in {
                'CVS', 'RCS', 'SCCS', '.git', '.hg', '.svn', '.bzr',
            }):
                continue
            if not child.is_file() and not child.is_dir():
                raise ValueError('unsupported configuration object: ' + str(child))
            yield from active_files(child)


def fragment(text):
    return text + '\n' if text and not text.endswith('\n') else text


def read_text(path):
    # Keep line endings and UTF-8 bytes intact; refuse undecodable input rather
    # than silently losing information. Backups also retain ignored files.
    with path.open(encoding='utf-8', newline='') as stream:
        return stream.read()


def order_key(value):
    # Directory traversal sorts each path component, not the joined pathname.
    return Path(value).parts


def ini_read(texts):
    parser = configparser.ConfigParser(interpolation=None)
    for text in texts:
        if text.strip():
            parser.read_string(text)
    return {'DEFAULT': dict(parser.defaults()), **{
        section: dict(values) for section, values in parser._sections.items()
    }}


def ini_text(values):
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_dict(values)
    stream = io.StringIO()
    parser.write(stream)
    return stream.getvalue()


def reconcile(blocks, text):
    """Keep local edits within their original ownership; reject crossed boundaries."""
    blocks = copy.deepcopy(blocks)
    old = [line for block in blocks for line in block['text'].splitlines(keepends=True)]
    new = text.splitlines(keepends=True)
    starts, owners, edits, insertions = [], [], {}, {}
    for index, block in enumerate(blocks):
        starts.append(len(owners))
        owners.extend([index] * len(block['text'].splitlines(keepends=True)))
    for tag, a, b, c, d in difflib.SequenceMatcher(a=old, b=new, autojunk=False).get_opcodes():
        if tag == 'equal':
            continue
        if a == b and (a == len(old) or a in starts):
            index = starts.index(a) if a in starts else len(blocks)
            order = blocks[index]['order'] if index < len(blocks) else 'zz-local'
            insertions.setdefault(index, []).append({
                'path': None, 'order': order, 'text': ''.join(new[c:d]),
            })
            continue
        touched = set(owners[a:b]) if a != b else {owners[a]}
        if len(touched) != 1:
            raise ValueError('local edit crosses managed fragments; resolve it before continuing')
        index = touched.pop()
        edits.setdefault(index, []).append((a - starts[index], b - starts[index], new[c:d]))
    result = []
    for index, block in enumerate(blocks):
        result.extend(insertions.get(index, []))
        lines = block['text'].splitlines(keepends=True)
        for a, b, replacement in reversed(edits.get(index, [])):
            lines[a:b] = replacement
        block['text'] = ''.join(lines)
        result.append(block)
    result.extend(insertions.get(len(blocks), []))
    if ''.join(block['text'] for block in result) != text:
        raise ValueError('could not preserve local configuration exactly')
    return result


def polly_text(text, changed, restore):
    lines = text.splitlines(keepends=True)
    disabled = changed['disabled'].splitlines(keepends=True)
    edited = lines != disabled
    matched = {}
    for part in difflib.SequenceMatcher(a=disabled, b=lines, autojunk=False).get_matching_blocks():
        matched.update((part.a + i, part.b + i) for i in range(part.size))
    for index in changed['indices']:
        if index not in matched or (edited and disabled.count(disabled[index]) != 1):
            raise ValueError('temporary no_polly line changed or became ambiguous; preserve/reconcile package.env')
    if restore:
        before = changed['before'].splitlines(keepends=True)
        for index in changed['indices']:
            lines[matched[index]] = before[index]
    return ''.join(lines)


class Policy:
    def __init__(self, root, state):
        self.root = Path(root).resolve()
        self.state = Path(state).absolute()
        self.safe(self.state)
        self.records = self.safe(self.state / 'portage-flat.json')
        self.journal = self.safe(self.state / 'portage-flat.pending.json')
        self.receipts = self.safe(self.state / 'portage-files')
        self.observed = {}

    @staticmethod
    def safe(path):
        if path.resolve() != path.absolute():
            raise ValueError('symlinked configuration path: ' + str(path))
        return path

    def path(self, relative):
        return self.safe(self.root / 'etc/portage' / relative)

    def read_state(self):
        if not self.records.exists():
            return {'version': 1, 'files': {}}
        data = json.loads(self.records.read_text())
        self.validate_state(data)
        return data

    @staticmethod
    def validate_state(data):
        if not isinstance(data, dict):
            raise ValueError('invalid flat Portage ownership record')
        if data.get('version') != 1 or not isinstance(data.get('files'), dict):
            raise ValueError('invalid flat Portage ownership record')
        for name, entry in data['files'].items():
            if name not in CONFIG_FILES or not isinstance(entry, dict):
                raise ValueError('invalid Portage ownership destination')
            if name in INI_FILES:
                if not isinstance(entry.get('ini'), dict):
                    raise ValueError('invalid repository ownership record: ' + name)
                for relative, block in entry['ini'].items():
                    if target_name(relative) != name or not isinstance(block, dict):
                        raise ValueError('invalid repository ownership path: ' + name)
                    if not re.fullmatch('[0-9a-f]{64}', block.get('source', '')) or not (block.get('expected') is None or isinstance(block.get('expected'), dict)):
                        raise ValueError('invalid repository ownership hash: ' + name)
            else:
                if not isinstance(entry.get('blocks'), list):
                    raise ValueError('invalid Portage rule ownership record: ' + name)
                seen = set()
                for block in entry['blocks']:
                    if not isinstance(block, dict) or not isinstance(block.get('text'), str) or not isinstance(block.get('order'), str):
                        raise ValueError('invalid Portage rule block: ' + name)
                    relative = block.get('path')
                    if relative is not None:
                        if target_name(relative) != name or relative in seen or not re.fullmatch('[0-9a-f]{64}', block.get('source', '')):
                            raise ValueError('invalid Portage ownership path: ' + name)
                        seen.add(relative)
        changed = data.get('polly_disabled')
        if changed is not None:
            if not isinstance(changed, dict) or changed.get('path') != COMPILER_RULES or not isinstance(changed.get('before'), str) or not isinstance(changed.get('disabled'), str) or not isinstance(changed.get('indices'), list):
                raise ValueError('invalid temporary no_polly record')
            before, disabled = changed['before'].splitlines(keepends=True), changed['disabled'].splitlines(keepends=True)
            indices = changed['indices']
            if any(not isinstance(i, int) for i in indices) or len(before) != len(disabled) or len(set(indices)) != len(indices) or any(i < 0 or i >= len(before) or disabled[i] != '# ' + before[i] for i in indices):
                raise ValueError('invalid temporary no_polly lines')

    @staticmethod
    def mkdir(path, mode):
        missing = []
        parent = path
        while not parent.exists():
            missing.append(parent)
            parent = parent.parent
        for directory in reversed(missing):
            directory.mkdir(mode=mode)
            directory.chmod(mode)  # The installer's private umask must not hide /etc.
            Policy.sync_directory(directory.parent)

    @staticmethod
    def sync_directory(path):
        fd = os.open(path, os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    @staticmethod
    def atomic(path, text, mode=0o644, owner=None, directory_mode=0o700):
        Policy.mkdir(path.parent, directory_mode)
        fd, temporary = tempfile.mkstemp(prefix='.install-system.', dir=path.parent)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', newline='') as stream:
                stream.write(text)
                stream.flush()
                if owner is not None:
                    os.fchown(stream.fileno(), *owner)
                os.fchmod(stream.fileno(), mode)
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            Policy.sync_directory(path.parent)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    @staticmethod
    def fingerprint(path):
        if path.is_symlink():
            raise ValueError('symlinked configuration: ' + str(path))
        if not path.exists():
            return None
        if path.is_file():
            return 'file:' + hashlib.sha256(path.read_bytes()).hexdigest()
        if not path.is_dir():
            raise ValueError('unsupported configuration object: ' + str(path))
        hasher = hashlib.sha256()
        root_info = path.stat()
        hasher.update(str((root_info.st_mode & 0o7777, root_info.st_uid, root_info.st_gid)).encode() + b'\0')
        for child in sorted(path.rglob('*')):
            hasher.update(str(child.relative_to(path)).encode() + b'\0')
            info = child.lstat()
            hasher.update(str((info.st_mode & 0o7777, info.st_uid, info.st_gid)).encode() + b'\0')
            if child.is_symlink():
                hasher.update(b'link:' + os.readlink(child).encode())
            elif child.is_file():
                hasher.update(child.read_bytes())
            elif not child.is_dir():
                raise ValueError('unsupported backup object: ' + str(child))
            hasher.update(b'\0')
        return 'dir:' + hasher.hexdigest()

    def operation(self, path, text):
        self.safe(path)
        before = self.fingerprint(path)
        if str(path) in self.observed and before != self.observed[str(path)]:
            raise ValueError('configuration changed during preparation: ' + str(path))
        after = None if text is None else 'file:' + digest(text)
        if before == after:
            return None
        mode, owner = 0o644, None
        if path.exists():
            info = path.stat()
            owner = [info.st_uid, info.st_gid]
            if path.is_file():
                mode = info.st_mode & 0o777
            else:
                for child in active_files(path):
                    child_info = child.stat()
                    permissions = child_info.st_mode & 0o777
                    if info.st_uid != 0 and child_info.st_uid != info.st_uid and not permissions & 0o004:
                        raise ValueError('private fragment ownership conflicts with the merged file: ' + str(child))
                    mode &= permissions
                    if child_info.st_gid != info.st_gid and not permissions & 0o004:
                        mode &= ~0o040
                # Do not expose data previously protected by directory traversal.
                for directory in [path, *[p for p in path.rglob('*') if p.is_dir() and not p.is_symlink()]]:
                    permissions = directory.stat().st_mode
                    if not permissions & 0o010:
                        mode &= ~0o040
                    if not permissions & 0o001:
                        mode &= ~0o004
        return {'path': str(path), 'before': before, 'text': text, 'after': after,
                'mode': mode, 'owner': owner}

    @staticmethod
    def sync_backup(path):
        objects = [path, *path.rglob('*')] if path.is_dir() else [path]
        for child in reversed(objects):
            if not child.is_symlink():
                fd = os.open(child, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)

    @staticmethod
    def remaining_original(path, backup):
        # rmtree itself can be interrupted. A remaining subset of the verified
        # original can be cleaned up; new or edited data must never be discarded.
        for child in [path, *path.rglob('*')]:
            original = backup / child.relative_to(path)
            try:
                current, saved = child.lstat(), original.lstat()
            except FileNotFoundError:
                return False
            if (current.st_mode, current.st_uid, current.st_gid) != (saved.st_mode, saved.st_uid, saved.st_gid):
                return False
            if child.is_symlink():
                if os.readlink(child) != os.readlink(original):
                    return False
            elif child.is_file() and child.read_bytes() != original.read_bytes():
                return False
        return True

    def transact(self, data, operations):
        if self.journal.exists():
            raise ValueError('an interrupted Portage migration must be recovered before preparing another transaction')
        operations = [op for op in operations if op is not None]
        if not operations and data == self.read_state():
            return
        token = uuid.uuid4().hex
        for index, op in enumerate(operations):
            op['backup'] = str(self.state / 'portage-backups' / token / str(index))
            op['holding'] = str(Path(op['path']).with_name('.install-system-old-' + token + '-' + str(index)))
        pending = {'version': 1, 'root': str(self.root), 'directory': str(self.state),
                   'token': token, 'state': data, 'operations': operations}
        self.atomic(self.journal, json.dumps(pending), 0o600)
        self.recover()

    def recover(self):
        if not self.journal.exists():
            return
        pending = json.loads(self.journal.read_text())
        if pending.get('version') != 1 or pending.get('root') != str(self.root) or pending.get('directory') != str(self.state) or not re.fullmatch('[0-9a-f]{32}', pending.get('token', '')):
            raise ValueError('invalid Portage migration journal; keep it for recovery')
        token = pending['token']
        self.validate_state(pending['state'])
        # Validate every destination and prepare every backup before replacing
        # the first configuration file. This is recoverable, not tree-atomic.
        for index, op in enumerate(pending['operations']):
            path = self.safe(Path(op['path']))
            allowed = {self.path(name) for name in CONFIG_FILES}
            relative = str(path.relative_to(self.receipts)) if path.is_relative_to(self.receipts) else ''
            receipt = relative.endswith('.sha256') and target_name(relative.removesuffix('.sha256')) is not None
            if path not in allowed and path != self.path('sets') and not (
                path.parent in {self.path('sets'), self.receipts / 'sets'} and path.name.startswith('install-')
            ) and not receipt:
                raise ValueError('invalid Portage migration destination: ' + str(path))
            if op['backup'] != str(self.state / 'portage-backups' / token / str(index)) or op['holding'] != str(path.with_name('.install-system-old-' + token + '-' + str(index))):
                raise ValueError('invalid Portage backup location')
            if op['after'] != (None if op['text'] is None else 'file:' + digest(op['text'])):
                raise ValueError('invalid Portage migration output')
            current = self.fingerprint(path)
            holding = self.safe(Path(op['holding']))
            if current not in (op['before'], op['after']) and not (
                current is None and self.fingerprint(holding) == op['before']
            ):
                raise ValueError('configuration changed during interrupted migration: ' + str(path))
        retired_sets = {Path(op['path']).name.removesuffix('.sha256')
                        for op in pending['operations']
                        if Path(op['path']).parent == self.receipts / 'sets' and op['text'] is None}
        refs = self.safe(self.root / 'var/lib/portage/world_sets')
        if retired_sets and refs.exists() and {'@' + name for name in retired_sets} & set(read_text(refs).split()):
            raise ValueError('an installer set is still selected; keep the migration journal and backups')
        if pending['operations']:
            manifest = self.safe(self.state / 'portage-backups' / token / 'manifest.json')
            if not manifest.exists():
                details = [{key: value for key, value in op.items() if key != 'text'}
                           for op in pending['operations']]
                self.atomic(manifest, json.dumps(details, indent=2) + '\n', 0o600)
        for op in pending['operations']:
            path = self.safe(Path(op['path']))
            backup = self.safe(Path(op['backup']))
            holding = self.safe(Path(op['holding']))
            current = self.fingerprint(path)
            if op['before'] is not None:
                if not backup.exists():
                    if current == op['after']:
                        raise ValueError('migration backup is missing; keep the journal: ' + str(path))
                    original = path if current is not None else holding
                    self.mkdir(backup.parent, 0o700)
                    temporary = backup.with_name(backup.name + '.copying')
                    if temporary.exists():
                        # Preserve an interrupted copy rather than discarding it.
                        os.replace(temporary, temporary.with_name(temporary.name + '.interrupted-' + uuid.uuid4().hex))
                    if original.is_dir():
                        shutil.copytree(original, temporary, symlinks=True)
                    else:
                        shutil.copy2(original, temporary)
                    objects = [original, *original.rglob('*')] if original.is_dir() else [original]
                    for child in objects:
                        copied = temporary / child.relative_to(original) if child != original else temporary
                        info = child.lstat()
                        os.chown(copied, info.st_uid, info.st_gid, follow_symlinks=False)
                        if not child.is_symlink():
                            copied.chmod(info.st_mode & 0o7777)
                    if self.fingerprint(temporary) != op['before']:
                        raise ValueError('Portage backup verification failed: ' + str(path))
                    self.sync_backup(temporary)
                    os.replace(temporary, backup)
                    self.sync_directory(backup.parent)
                if self.fingerprint(backup) != op['before']:
                    raise ValueError('Portage backup changed: ' + str(backup))
                if current not in (None, op['after']) and self.fingerprint(path) != op['before']:
                    raise ValueError('configuration changed during backup: ' + str(path))
        # Recheck all paths after copying, before the first replacement.
        for op in pending['operations']:
            path = self.safe(Path(op['path']))
            current = self.fingerprint(path)
            if current not in (op['before'], op['after']) and not (
                current is None and self.fingerprint(Path(op['holding'])) == op['before']
            ):
                raise ValueError('configuration changed during backup: ' + str(path))
        for op in pending['operations']:
            path, backup, holding = map(lambda key: self.safe(Path(op[key])), ('path', 'backup', 'holding'))
            current = self.fingerprint(path)
            if current not in (op['before'], op['after']) and not (
                current is None and self.fingerprint(holding) == op['before']
            ):
                raise ValueError('configuration changed before replacement: ' + str(path))
            if current != op['after']:
                if current is not None and path.is_dir():
                    os.replace(path, holding)
                    self.sync_directory(path.parent)
                if op['text'] is None:
                    if path.exists():
                        path.unlink()
                        self.sync_directory(path.parent)
                else:
                    directory_mode = 0o755 if path in {self.path(name) for name in CONFIG_FILES} else 0o700
                    self.atomic(path, op['text'], op['mode'], op['owner'], directory_mode)
            if holding.exists():
                if self.fingerprint(backup) != op['before'] or not self.remaining_original(holding, backup):
                    raise ValueError('original directory/backup changed: ' + str(holding))
                shutil.rmtree(holding)
                self.sync_directory(holding.parent)
        self.atomic(self.records, json.dumps(pending['state'], indent=2) + '\n', 0o600)
        self.journal.unlink()
        self.sync_directory(self.journal.parent)

    def receipt(self, relative):
        path = self.safe(self.receipts / (relative + '.sha256'))
        if not path.is_file():
            return None
        value = path.read_text().strip()
        if not re.fullmatch('[0-9a-f]{64}', value):
            raise ValueError('invalid policy receipt: ' + str(path))
        return value

    def entry(self, name, data):
        path = self.path(name)
        observed = self.fingerprint(path)
        existing = data['files'].get(name)
        if path.is_dir():
            if existing is not None:
                raise ValueError('flat configuration was replaced by a directory: ' + str(path))
            blocks = []
            for child in active_files(path):
                relative = name + '/' + str(child.relative_to(path))
                source = self.receipt(relative)
                blocks.append({'path': relative if source else None,
                               'order': str(child.relative_to(path)),
                               'source': source, 'text': fragment(read_text(child))})
            existing = {'blocks': blocks}
            if name in INI_FILES:
                existing = {'ini': {block['path']: {
                    'source': block['source'],
                    'expected': ini_read([block['text']]) if digest(block['text']) == block['source'] else None,
                } for block in blocks if block['path']}}
                text = ini_text(ini_read([block['text'] for block in blocks]))
            else:
                text = ''.join(block['text'] for block in blocks)
        else:
            text = read_text(path) if path.exists() else ''
            if existing is None:
                existing = {'ini': {}} if name in INI_FILES else {'blocks': [
                    {'path': None, 'order': '', 'text': text}
                ] if text else []}
            elif name not in INI_FILES:
                existing = {'blocks': reconcile(existing['blocks'], text)}
        if name == 'package.env' and 'polly_disabled' not in data:
            # Older installers kept the temporary GCC-pass marker in their
            # compiler fragment. Move that bookkeeping out of package.env.
            for block in existing['blocks']:
                if block['path'] != COMPILER_RULES:
                    continue
                old = block['text']
                lines = old.splitlines(keepends=True)
                indices = [i for i, line in enumerate(lines) if line.startswith(LEGACY_POLLY_PREFIX)]
                if indices:
                    before = ''.join(line[len(LEGACY_POLLY_PREFIX):] if line.startswith(LEGACY_POLLY_PREFIX) else line for line in lines)
                    disabled = ''.join('# ' + line[len(LEGACY_POLLY_PREFIX):] if line.startswith(LEGACY_POLLY_PREFIX) else line for line in lines)
                    data['polly_disabled'] = {'path': COMPILER_RULES, 'before': before,
                                              'disabled': disabled, 'indices': indices}
                    block['text'] = disabled
                    if block['source'] == digest(old):
                        block['source'] = digest(before)
                    text = ''.join(item['text'] for item in existing['blocks'])
        data['files'][name] = existing
        if self.fingerprint(path) != observed:
            raise ValueError('configuration changed during reading: ' + str(path))
        self.observed[str(path)] = observed
        return existing, text

    def migrate(self, configs_only=False, check_only=False):
        data = self.read_state()
        operations = []
        # Prepare and parse every destination before changing any of them.
        for name in sorted(CONFIG_FILES):
            path = self.path(name)
            if path.is_dir():
                _, text = self.entry(name, data)
                operations.append(self.operation(path, text if text else None))
                records = data['files'][name]
                relatives = records['ini'] if name in INI_FILES else (
                    block['path'] for block in records['blocks'] if block['path']
                )
                operations.extend(self.operation(self.receipts / (relative + '.sha256'), None)
                                  for relative in relatives)
        if not configs_only:
            operations.extend(self.migrate_sets(check_only))
        if not check_only:
            self.transact(data, operations)
        return sum(op is not None for op in operations)

    def migrate_sets(self, check_only=False):
        directory = self.path('sets')
        self.observed[str(directory)] = self.fingerprint(directory)
        refs_path = self.safe(self.root / 'var/lib/portage/world_sets')
        refs = set(refs_path.read_text().split()) if refs_path.exists() else set()
        for receipt in (self.receipts / 'sets').glob('install-*.sha256'):
            name = receipt.name.removesuffix('.sha256')
            if '@' + name in refs and not self.path('sets/' + name).is_file():
                raise ValueError('selected installer set is missing; restore it before migration: ' + name)
        if not directory.exists():
            return []
        owned = {}
        for path in active_files(directory):
            if path.name.endswith('.metadata'):
                continue
            relative = str(path.relative_to(self.root / 'etc/portage'))
            if path.parent == directory and path.name.startswith('install-') and self.receipt(relative):
                owned[path.name] = path
        if not owned:
            return []
        # Never break an unrelated user set that refers to an installer set.
        unrelated = [path for path in active_files(directory) if not path.name.endswith('.metadata')]
        config = self.path('sets.conf')
        if config.exists():
            unrelated.extend(active_files(config))
        for path in unrelated:
            if path not in owned.values():
                refs = {reference for line in read_text(path).splitlines()
                        for reference in re.findall(r'@([^\s]+)', line.split('#', 1)[0])}
                if refs & owned.keys():
                    raise ValueError('user set refers to an installer set; preserve/reconcile it: ' + str(path))
        from portage._sets.files import StaticFileSet, WorldSelectedSet
        from portage.dep import Atom
        expanded = {}

        def expand(name, visiting=()):
            if name in visiting:
                raise ValueError('recursive package set: ' + name)
            path = self.path('sets/' + name)
            if not path.is_file():
                raise ValueError('missing referenced package set: ' + name)
            group = StaticFileSet(str(path))
            items = list(group)
            if group.errors:
                raise ValueError('invalid package set: ' + '; '.join(group.errors))
            result = set()
            for item in items:
                if str(item).startswith('@'):
                    child = str(item)[1:]
                    if child in owned:
                        result.update(expand(child, (*visiting, name)))
                    else:
                        result.add('@' + child)  # Preserve the user's independent group.
                else:
                    atom = Atom(str(item), allow_repo=True)
                    # Preserve explicit slot/repository choices, not build-time USE or
                    # version constraints that normal emerge selection does not retain.
                    value = atom.cp
                    if atom.slot:
                        value += ':' + atom.slot
                    if atom.repo:
                        value += '::' + atom.repo
                    result.add(value)
            return result

        for name in owned:
            expanded[name] = expand(name)
        # Capture the removals before editing world. A later configuration edit
        # must not become part of a newly inferred installer-owned deletion.
        if set(directory.iterdir()) == set(owned.values()):
            operations = [self.operation(directory, None)]
        else:
            operations = [self.operation(path, None) for path in owned.values()]
        operations.extend(self.operation(self.receipts / ('sets/' + name + '.sha256'), None)
                          for name in owned)
        if self.fingerprint(directory) != self.observed[str(directory)]:
            raise ValueError('package sets changed during migration preparation')
        self.safe(self.root / 'var/lib/portage/world')
        world = WorldSelectedSet(str(self.root) + '/')
        if not check_only:
            world.lock()
        try:
            world.load()
            errors = world._pkgset.errors + world._setset.errors
            if errors:
                raise ValueError('invalid world selection: ' + '; '.join(errors))
            old = set(map(str, world))
            selected = {name for name in owned if '@' + name in old}
            new = old - {'@' + name for name in selected}
            for name in selected:
                new.update(expanded[name])
            if new != old and not check_only:
                # Native world locking/validation; world is written BEFORE world_sets.
                backup = self.state / 'portage-backups' / uuid.uuid4().hex
                self.mkdir(backup, 0o700)
                for filename in ('world', 'world_sets'):
                    original = self.safe(self.root / 'var/lib/portage' / filename)
                    if original.exists():
                        shutil.copy2(original, backup / filename)
                        info = original.stat()
                        os.chown(backup / filename, info.st_uid, info.st_gid)
                        (backup / filename).chmod(info.st_mode & 0o7777)
                        if self.fingerprint(original) != self.fingerprint(backup / filename):
                            raise ValueError('world backup verification failed')
                self.sync_backup(backup)
                # Portage's normal atom validation, locks and atomic writes. Make
                # the package selections durable before dropping any old set ref.
                packages = {item for item in new if not item.startswith('@')}
                if packages != {item for item in old if not item.startswith('@')}:
                    world._pkgset.replace(packages)
                    self.sync_backup(self.root / 'var/lib/portage/world')
                    self.sync_directory(self.root / 'var/lib/portage')
                world._setset.replace({item for item in new if item.startswith('@')})
                self.sync_backup(self.root / 'var/lib/portage/world_sets')
                self.sync_directory(self.root / 'var/lib/portage')
                world.load()
                if not new.issubset(set(map(str, world))):
                    raise ValueError('world selection verification failed; installer sets were kept')
        finally:
            if not check_only:
                world.unlock()
        return operations

    def prepare(self, inputs):
        data = self.read_state()
        entries = {}
        for path in sorted(inputs.rglob('*')):
            self.safe(path)
            if not path.is_file() and not path.is_dir():
                raise ValueError('unsupported policy input: ' + str(path))
            if path.is_file():
                relative = str(path.relative_to(inputs))
                name = target_name(relative)
                if name is None:
                    raise ValueError('not a single-file policy input: ' + relative)
                entries.setdefault(name, []).append((relative, fragment(read_text(path))))
        operations = []
        for name, changes in entries.items():
            entry, text = self.entry(name, data)
            if name in INI_FILES:
                values = ini_read([text])
                for relative, incoming in changes:
                    desired = ini_read([incoming])
                    record = entry['ini'].get(relative)
                    if record and record['source'] == digest(incoming):
                        record['expected'] = desired
                        continue  # Retain edits to the same deployed policy.
                    previous = record['expected'] if record else {}
                    if previous is None:
                        raise ValueError('edited repository policy changed upstream: ' + relative)
                    for section in dict.fromkeys([*previous, *desired]):
                        current = values.setdefault(section, {})
                        before, after = previous.get(section, {}), desired.get(section, {})
                        for key in dict.fromkeys([*before, *after]):
                            old, new, actual = before.get(key), after.get(key), current.get(key)
                            if new == old or actual == new:
                                continue
                            if actual != old and actual is not None:
                                raise ValueError('local repository policy conflict: ' + name + ' [' + section + '] ' + key)
                            if new is None:
                                current.pop(key, None)
                            else:
                                current[key] = new
                    entry['ini'][relative] = {'source': digest(incoming), 'expected': desired}
                rendered = ini_text(values)
                # Do not rewrite an already single-file INI merely for formatting.
                output = text if ini_read([text]) == values else rendered
            else:
                blocks = entry['blocks']
                if 'polly_disabled' in data and any(relative == COMPILER_RULES for relative, _ in changes):
                    compiler = next((block for block in blocks if block['path'] == COMPILER_RULES), None)
                    if compiler is None:
                        raise ValueError('temporary compiler rules are missing; preserve/reconcile package.env')
                    # An explicit earlier compiler-policy deployment starts that
                    # pass afresh, like replacing its former fragment did. Never
                    # leak the later GCC pass's temporary comments into it.
                    compiler['text'] = polly_text(compiler['text'], data['polly_disabled'], restore=True)
                    data.pop('polly_disabled')
                for relative, incoming in changes:
                    block = next((item for item in blocks if item['path'] == relative), None)
                    if block:
                        if block['source'] == digest(incoming):
                            continue
                        if digest(block['text']) != block['source'] and block['text'] != incoming:
                            raise ValueError('local Portage policy conflict: ' + relative)
                        block['text'], block['source'] = incoming, digest(incoming)
                    else:
                        order = relative[len(name):].lstrip('/')
                        block = {'path': relative, 'order': order,
                                 'source': digest(incoming), 'text': incoming}
                        index = next((i for i, item in enumerate(blocks) if order_key(item['order']) > order_key(order)), len(blocks))
                        blocks.insert(index, block)
                for block in blocks[:-1]:
                    block['text'] = fragment(block['text'])
                output = ''.join(item['text'] for item in blocks)
            operations.append(self.operation(self.path(name), output))
        return data, operations

    def check(self, relative, incoming):
        name = target_name(relative)
        if name is None or not self.path(name).is_file():
            return False
        data = self.read_state()
        if name not in data['files']:
            return False
        entry, _ = self.entry(name, data)
        if name in INI_FILES:
            block = entry['ini'].get(relative)
        else:
            block = next((item for item in entry['blocks'] if item['path'] == relative), None)
        return block is not None and block['source'] == digest(fragment(incoming))

    def retire(self, known):
        data = self.read_state()
        operations = []
        for name in list(data['files']):
            entry, text = self.entry(name, data)
            if name in INI_FILES:
                # Repository definitions are permanent registration, not transient
                # application policy. Never unregister an overlay as stale input.
                continue
            kept = []
            for block in entry['blocks']:
                if block['path'] and block['path'] not in known:
                    if digest(block['text']) == block['source']:
                        continue
                    print('Keeping edited retired Portage rules: ' + block['path'], file=sys.stderr)
                    block['path'] = None
                kept.append(block)
            entry['blocks'] = kept
            output = ''.join(item['text'] for item in kept)
            operations.append(self.operation(self.path(name), output if kept or output else None))
        self.transact(data, operations)

    def toggle(self, enabled):
        data = self.read_state()
        entry, text = self.entry('package.env', data)
        block = next((item for item in entry['blocks'] if item['path'] == COMPILER_RULES), None)
        if block is None:
            raise ValueError('compiler package.env ownership is missing; preserve/reconcile it before the compiler pass')
        changed = data.get('polly_disabled')
        lines = block['text'].splitlines(keepends=True)
        if changed:
            lines = polly_text(block['text'], changed, restore=enabled).splitlines(keepends=True)
        if not enabled:
            if changed:
                return
            indices = [i for i, line in enumerate(lines)
                       if not line.lstrip().startswith('#') and re.search(r'\sno_polly(?:\s|$)', line.split('#', 1)[0])]
            before = block['text']
            for i in indices:
                lines[i] = '# ' + lines[i]
            data['polly_disabled'] = {'path': COMPILER_RULES, 'before': before,
                                     'disabled': ''.join(lines), 'indices': indices}
        else:
            data.pop('polly_disabled', None)
        block['text'] = ''.join(lines)
        output = ''.join(item['text'] for item in entry['blocks'])
        self.transact(data, [self.operation(self.path('package.env'), output)])


def selected_packages(root, atoms):
    import portage
    from portage._sets import load_default_config
    from portage.dep import match_from_list
    trees = portage.create_trees(config_root=str(root), target_root=str(root))
    tree = trees[next(iter(trees))]
    settings = tree['vartree'].settings
    config = load_default_config(settings, tree)
    selected = config.getSetAtoms('selected') | config.getSetAtoms('system')
    vardb = tree['vartree'].dbapi
    for atom in atoms:
        matches = [vardb._pkg_str(cpv, None) for cpv in vardb.match(atom)]
        # Missing packages are handled by the installer's incomplete-stage logic.
        if matches and not any(match_from_list(choice, matches) for choice in selected):
            print('Package is not selected in world or system: ' + atom, file=sys.stderr)
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('migrate', 'apply', 'check', 'retire', 'toggle', 'selected'))
    parser.add_argument('--root', type=Path, default=Path('/'))
    parser.add_argument('--state', type=Path)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--relative')
    parser.add_argument('--configs-only', action='store_true')
    parser.add_argument('--check-only', action='store_true')
    parser.add_argument('--enabled', choices=('yes', 'no'))
    args = parser.parse_args()
    if args.action == 'apply' and (args.input is None or not args.input.is_dir()):
        parser.error('apply requires an input directory')
    if args.action == 'check' and not args.relative:
        parser.error('check requires --relative')
    if args.action == 'toggle' and args.enabled is None:
        parser.error('toggle requires --enabled yes|no')
    if args.check_only and args.action not in ('apply', 'migrate'):
        parser.error('--check-only is supported for apply and migrate only')
    state = args.state or args.root / 'var/lib/install-system'
    policy = Policy(args.root, state)
    if args.check_only:
        if policy.journal.exists():
            raise ValueError('an interrupted migration is pending; keep its journal and resume without --check-only')
        if args.action == 'apply':
            policy.prepare(args.input)
        else:
            policy.migrate(args.configs_only, check_only=True)
            print('Portage migration validated; no files were changed')
        return 0
    if args.action == 'selected':
        return 0 if selected_packages(policy.root, sys.stdin.read().splitlines()) else 1
    if args.action == 'check':
        if policy.journal.exists():
            return 1
        return 0 if policy.check(args.relative, sys.stdin.read()) else 1
    policy.mkdir(state, 0o700)
    with policy.safe(state / 'portage-flat.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        policy.recover()
        if args.action == 'migrate':
            if policy.migrate(args.configs_only):
                print('Portage layout migrated; originals: ' + str(state / 'portage-backups'))
        elif args.action == 'apply':
            data, operations = policy.prepare(args.input)
            if not args.check_only:
                policy.transact(data, operations)
        elif args.action == 'retire':
            policy.retire(set(sys.stdin.read().splitlines()))
        elif args.action == 'toggle':
            policy.toggle(args.enabled == 'yes')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, configparser.Error, KeyError, TypeError) as error:
        print('install-system: ' + str(error), file=sys.stderr)
        sys.exit(1)
