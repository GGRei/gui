#!/usr/bin/env python3
import pathlib
import sys

if len(sys.argv) != 10:
    raise SystemExit(
        'usage: verify_final_link.py <log> <output> <v1|v3> '
        '<dynamic|static> <dev|s2|s3> <lane> <cc> <cxx> <report>'
    )

log_path, output, generation, mode, profile, lane, cc, cxx, report = sys.argv[1:]
if generation not in {'v1', 'v3'}:
    raise SystemExit(f'unsupported compiler generation: {generation}')
if mode not in {'dynamic', 'static'}:
    raise SystemExit(f'unsupported link mode: {mode}')
if profile not in {'dev', 's2', 's3'}:
    raise SystemExit(f'unsupported build profile: {profile}')
if lane not in {'ucrt64-gcc', 'ucrt64-clang', 'clang64-clang', 'mingw64-gcc'}:
    raise SystemExit(f'unsupported toolchain lane: {lane}')


def lexical_path(path):
    normalized = path.replace('\\', '/')
    while '//' in normalized:
        normalized = normalized.replace('//', '/')
    return normalized.rstrip('/').casefold()


def words(text):
    result = []
    token = []
    quote = None
    started = False
    index = 0
    while index < len(text):
        char = text[index]
        if quote is None and char in ' \t\r\n':
            if started:
                result.append(''.join(token))
                token = []
                started = False
            index += 1
            continue
        if char in "'\"":
            if quote is None:
                quote = char
                started = True
                index += 1
                continue
            if quote == char:
                quote = None
                index += 1
                continue
        if char == '\\' and quote != "'" and index + 1 < len(text):
            following = text[index + 1]
            if quote == '"':
                escapable = following in ('"', '\\')
            else:
                escapable = following in " \t\r\n'\"\\"
            if escapable:
                token.append(following)
                started = True
                index += 2
                continue
        token.append(char)
        started = True
        index += 1
    if quote is not None:
        raise ValueError('unterminated quote in showcc text')
    if started:
        result.append(''.join(token))
    return result


def define_count(tokens, macro):
    combined = '-D' + macro
    count = tokens.count(combined)
    if any(token.startswith(combined + '=') for token in tokens):
        raise SystemExit(f'assigned value is not allowed for -D{macro}')
    for index, token in enumerate(tokens):
        if token != '-D':
            continue
        if index + 1 >= len(tokens):
            raise SystemExit('dangling -D in final invocation')
        operand = tokens[index + 1]
        if operand.startswith(macro + '='):
            raise SystemExit(f'assigned value is not allowed for -D {macro}')
        if operand == macro:
            count += 1
    return count


command_prefix = {
    'v1': '> C compiler cmd: ',
    'v3': '  > ',
}[generation]
response_marker = {
    'v1': '> C compiler response file',
    'v3': '  > C++ linker response file',
}[generation]
response_prefix = response_marker + ' "'


def response_header_path(line, line_number):
    if not line.startswith(response_marker):
        return None
    if not line.startswith(response_prefix) or not line.endswith('\":'):
        raise SystemExit(f'malformed response-file header at line {line_number}')
    path = line[len(response_prefix):-2]
    if not path or '"' in path:
        raise SystemExit(f'malformed response-file path at line {line_number}')
    return path


lines = pathlib.Path(log_path).read_text(encoding='utf-8', errors='replace').splitlines()
commands = []
seen_response_paths = set()
index = 0
while index < len(lines):
    line = lines[index]
    line_number = index + 1
    response_path = response_header_path(line, line_number)
    if response_path is not None:
        if not commands or commands[-1]['line_index'] != index - 1:
            raise SystemExit(f'orphan response-file block at line {line_number}')
        response_key = lexical_path(response_path)
        if response_key in seen_response_paths:
            raise SystemExit(f'duplicate response-file block at line {line_number}')
        seen_response_paths.add(response_key)
        command = commands[-1]
        if command['response_path'] is not None:
            raise SystemExit(f'duplicate response-file block at line {line_number}')
        response_tokens = []
        if generation == 'v1':
            index += 1
            if index >= len(lines):
                raise SystemExit(f'truncated response-file block at line {line_number}')
            content = lines[index]
            if (content.startswith(command_prefix) or content.startswith(response_marker)
                    or content.startswith(('case:', 'phase:', 'required:', 'timeout_seconds:',
                                           'command:', 'exit_code:', '========'))):
                raise SystemExit(f'truncated response-file block at line {line_number}')
            try:
                response_tokens = words(content)
            except ValueError as error:
                raise SystemExit(
                    f'malformed response-file content at line {index + 1}: {error}'
                ) from error
            if not response_tokens:
                raise SystemExit(f'empty response-file block at line {line_number}')
        else:
            index += 1
            while index < len(lines) and lines[index].startswith('"'):
                content = lines[index]
                if not content.endswith('"'):
                    raise SystemExit(f'malformed response-file argument at line {index + 1}')
                try:
                    parsed = words(content)
                except ValueError as error:
                    raise SystemExit(
                        f'malformed response-file argument at line {index + 1}: {error}'
                    ) from error
                if len(parsed) != 1:
                    raise SystemExit(f'expected one response-file argument at line {index + 1}')
                response_tokens.extend(parsed)
                index += 1
            if not response_tokens:
                raise SystemExit(f'truncated response-file block at line {line_number}')
            index -= 1
        command['response_path'] = response_path
        command['response_tokens'] = response_tokens
    elif line.startswith(command_prefix):
        text = line[len(command_prefix):]
        try:
            tokens = words(text)
        except ValueError as error:
            raise SystemExit(f'malformed showcc command at line {line_number}: {error}') from error
        if not tokens:
            raise SystemExit(f'empty showcc command at line {line_number}')
        commands.append({
            'line_index': index,
            'tokens': tokens,
            'response_path': None,
            'response_tokens': None,
        })
    index += 1

if not commands:
    raise SystemExit(f'no {generation} showcc commands found')

expanded_commands = []
for command in commands:
    tokens = command['tokens']
    response_indexes = [position for position, token in enumerate(tokens) if token.startswith('@')]
    if len(response_indexes) > 1:
        raise SystemExit('expected at most one response file per linker invocation')
    if response_indexes:
        if command['response_path'] is None:
            raise SystemExit('showcc invocation references a response file without a log block')
        response_index = response_indexes[0]
        response_reference = tokens[response_index][1:]
        if (not response_reference
                or lexical_path(response_reference) != lexical_path(command['response_path'])):
            raise SystemExit('response-file command/header path mismatch')
        if any(token.startswith('@') for token in command['response_tokens']):
            raise SystemExit('nested response files are not allowed')
        tokens = tokens[:response_index] + command['response_tokens'] + tokens[response_index + 1:]
    elif command['response_path'] is not None:
        raise SystemExit('response-file log block has no matching command reference')
    if any(token.startswith('@') for token in tokens):
        raise SystemExit('unexpanded response-file reference')
    expanded_commands.append(tokens)

if any(tokens[1:].count('-fuse-ld=lld') for tokens in expanded_commands if '-c' in tokens):
    raise SystemExit('LLD selection flag leaked into a compile-only command')

expected_output = lexical_path(output) if generation == 'v1' else 'out'
candidates = []
for tokens in expanded_commands:
    output_indexes = [position for position, token in enumerate(tokens) if token == '-o']
    if len(output_indexes) != 1:
        raise SystemExit(
            f'expected exactly one -o operand in showcc command, found {len(output_indexes)}'
        )
    output_index = output_indexes[0]
    if output_index + 1 >= len(tokens):
        raise SystemExit('missing operand after -o in showcc command')
    observed_output = lexical_path(tokens[output_index + 1])
    if observed_output == expected_output and '-c' not in tokens:
        candidates.append(tokens)
if len(candidates) != 1:
    raise SystemExit(f'expected exactly one final invocation, found {len(candidates)}')

argv = candidates[0]
expected_lld_count = 1 if (
    generation == 'v3' and profile == 's3' and lane == 'ucrt64-clang'
) else 0
if argv.count('-fuse-ld=lld') != expected_lld_count:
    raise SystemExit(
        f'LLD selection cardinality mismatch: {argv.count("-fuse-ld=lld")}'
    )
driver = lexical_path(argv[0])
expected_driver = lexical_path(cxx if mode == 'static' else cc)
errors = []
if mode == 'static':
    for token, expected in (('-static', 1), ('-liconv', 1)):
        if argv.count(token) != expected:
            errors.append(f'{token} cardinality')
    for macro in ('GLIB_STATIC_COMPILATION', 'GOBJECT_STATIC_COMPILATION'):
        if define_count(argv, macro) != 1:
            errors.append(f'-D{macro} cardinality')
    if argv.count('-lintl') < 1:
        errors.append('missing -lintl')
    if ('-lintl' in argv and '-liconv' in argv
            and argv.index('-liconv') <= max(
                index for index, token in enumerate(argv) if token == '-lintl'
            )):
        errors.append('-liconv order')
    if driver != expected_driver:
        errors.append('not expected C++ driver')
else:
    for token in ('-static', '-liconv'):
        if argv.count(token):
            errors.append(f'unexpected {token}')
    for macro in ('GLIB_STATIC_COMPILATION', 'GOBJECT_STATIC_COMPILATION'):
        if define_count(argv, macro):
            errors.append(f'unexpected -D{macro}')
    if driver != expected_driver:
        errors.append('not expected C driver')

pathlib.Path(report).write_text(
    'generation=' + generation + '\n'
    + 'profile=' + profile + '\n'
    + 'lane=' + lane + '\n'
    + 'requested_output=' + lexical_path(output) + '\n'
    + 'driver=' + driver + '\n'
    + 'argv=' + '\t'.join(argv) + '\n'
    + 'errors=' + ','.join(errors) + '\n',
    encoding='utf-8',
)
if errors:
    raise SystemExit('; '.join(errors))
