#!/usr/bin/env python3
import collections, csv, pathlib, sys

results_path, compiler, report_path = map(pathlib.Path, sys.argv[1:4])
cc = compiler.name
expected = []

def add(name, phase, required='yes'):
    expected.append((name, phase, required))

add('vglyph_module_check', 'check')
add('c_dynamic_build', 'build'); add('c_dynamic_run', 'run')
add('pango_static_compile', 'build')
add('pango_static_noiconv_build', 'build', 'no')
add('pango_static_iconv_build', 'build')
add('pango_static_noiconv_iconv_boundary', 'oracle')
add('pango_static_iconv_run', 'run')
add('gettext_static_noiconv_build', 'build', 'no')
add('gettext_static_iconv_build', 'build')
add('gettext_static_noiconv_iconv_boundary', 'oracle')
add('gettext_static_iconv_run', 'run')

for generation in ('v1', 'v3'):
    for linkage in ('dynamic', 'static'):
        for profile in ('dev', 's2', 's3'):
            for build_pass in ('cold', 'warm'):
                name = f'vglyph_{generation}_{linkage}_{profile}_{build_pass}'
                add(name + '_build', 'build')
                if linkage == 'static': add(name + '_static_pe', 'pe')
                add(name + '_final_link', 'oracle')
                add(name + '_run', 'run')
                if profile == 's2': add(name + '_absent_flto', 'flags')
                if profile == 's3':
                    expect_flto = cc == 'gcc' or generation == 'v3'
                    add(name + ('_present_flto' if expect_flto else '_absent_flto'), 'flags')
                add(name + '_generated_c', 'artifact')
                add(name + '_response_file', 'artifact', 'no')
                if profile == 's3':
                    show = f'showcase_{generation}_{linkage}_{profile}_{build_pass}'
                    add(show + '_build', 'build')
                    if linkage == 'static': add(show + '_static_pe', 'pe')
                    add(show + '_final_link', 'oracle')
                    add(show + ('_present_flto' if expect_flto else '_absent_flto'), 'flags')
                    add(show + '_generated_c', 'artifact')
                    add(show + '_response_file', 'artifact', 'no')
add('windows_error_reporting', 'collect')

with results_path.open(newline='', encoding='utf-8') as stream:
    rows = list(csv.DictReader(stream, delimiter='\t'))
actual = [(r['case'], r['phase'], r['required']) for r in rows]
expected_counts, actual_counts = collections.Counter(expected), collections.Counter(actual)
errors = []
for key, count in sorted((expected_counts - actual_counts).items()): errors.append(f'missing {count} {key}')
for key, count in sorted((actual_counts - expected_counts).items()): errors.append(f'unknown/duplicate {count} {key}')
for row in rows:
    value = row['exit_code']
    if value in {'skipped', 'panic', ''}: errors.append(f'forbidden status {row["case"]}={value}')
    elif row['required'] == 'yes' and value != '0': errors.append(f'required failure {row["case"]}={value}')
    elif row['required'] == 'no' and value not in {'0', '1', 'absent'} and not value.isdigit():
        errors.append(f'invalid optional status {row["case"]}={value}')
pathlib.Path(report_path).write_text(
    f'expected={len(expected)}\nactual={len(rows)}\ncomplete={str(not errors).lower()}\n' +
    ''.join(f'error={error}\n' for error in errors), encoding='utf-8')
if errors: raise SystemExit('\n'.join(errors))
