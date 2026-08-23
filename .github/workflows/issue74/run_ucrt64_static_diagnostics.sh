#!/usr/bin/env bash

set -uo pipefail

if [ "$#" -ne 4 ]; then
	echo "usage: $0 <gcc|clang> <v.exe> <gui-dir> <artifact-dir>" >&2
	exit 2
fi

cc="$1"
v_exe="$2"
gui_dir="$3"
artifact_root="$4"

case "$cc" in
	gcc|clang) ;;
	*)
		echo "unsupported compiler: $cc" >&2
		exit 2
		;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
probe_c="$script_dir/pango_probe.c"
gettext_probe_c="$script_dir/gettext_probe.c"
probe_v="$script_dir/vglyph_probe.v"
showcase_v="$gui_dir/examples/showcase.v"

: "${MINGW_PREFIX:?MINGW_PREFIX is not set; run this script from an MSYS2 UCRT64 shell}"
for required_path in "$v_exe" "$probe_c" "$gettext_probe_c" "$probe_v" "$showcase_v"; do
	if [ ! -f "$required_path" ]; then
		echo "required diagnostic input not found: $required_path" >&2
		exit 2
	fi
done

out_dir="$artifact_root/$cc"
logs_dir="$out_dir/logs"
bin_dir="$out_dir/bin"
pe_dir="$out_dir/pe"
pkgconfig_dir="$out_dir/pkgconfig"
generated_dir="$out_dir/generated"
probes_dir="$out_dir/probes"
results_file="$out_dir/results.tsv"
summary_file="$out_dir/summary.md"
marker_file="$out_dir/.diagnostic-start"

mkdir -p "$logs_dir" "$bin_dir" "$pe_dir" "$pkgconfig_dir" "$generated_dir" "$probes_dir" || exit 2
touch "$marker_file"
cp "$probe_c" "$gettext_probe_c" "$probe_v" "$probes_dir/"
printf 'case\tphase\trequired\texit_code\n' > "$results_file"

declare -A case_rc=()
declare -a pango_cflags=()
declare -a pango_dynamic_libs=()
declare -a pango_static_libs=()
required_failures=0
last_rc=0

to_unix_path() {
	local path="$1"
	if [[ "$path" =~ ^[A-Za-z]:[\\/] ]] && command -v cygpath >/dev/null 2>&1; then
		cygpath -u "$path"
	else
		printf '%s\n' "$path"
	fi
}

run_command() {
	local name="$1"
	local phase="$2"
	local required="$3"
	shift 3
	local log_file="$logs_dir/$name.log"
	local command_rc

	{
		printf 'case: %s\nphase: %s\nrequired: %s\ncommand:' "$name" "$phase" "$required"
		printf ' %q' "$@"
		printf '\n'
	} | tee "$log_file"

	"$@" 2>&1 | tee -a "$log_file"
	command_rc=${PIPESTATUS[0]}
	printf 'exit_code: %s\n' "$command_rc" | tee -a "$log_file"
	printf '%s\t%s\t%s\t%s\n' "$name" "$phase" "$required" "$command_rc" >> "$results_file"
	case_rc["$name"]="$command_rc"
	last_rc="$command_rc"
	if [ "$required" = yes ] && [ "$command_rc" -ne 0 ]; then
		required_failures=$((required_failures + 1))
	fi
	return 0
}

record_skipped() {
	local name="$1"
	local phase="$2"
	local reason="$3"
	printf 'case: %s\nphase: %s\nskipped: %s\n' "$name" "$phase" "$reason" | tee "$logs_dir/$name.log"
	printf '%s\t%s\tno\tskipped\n' "$name" "$phase" >> "$results_file"
}

inspect_pe() {
	local name="$1"
	local executable="$2"
	local report="$pe_dir/$name.txt"
	if [ ! -f "$executable" ]; then
		return 0
	fi
	{
		echo "file: $executable"
		if command -v file >/dev/null 2>&1; then
			file "$executable"
		fi
		sha256sum "$executable"
		stat -c 'size_bytes: %s' "$executable"
		echo
		echo 'objdump -p:'
		objdump -p "$executable"
	} > "$report" 2>&1
	echo "PE imports for $name:"
	grep -i 'DLL Name' "$report" || true
}

run_built_executable() {
	local name="$1"
	local required="$2"
	local executable="$3"
	local build_rc="$4"
	if [ "$build_rc" -eq 0 ] && [ -f "$executable" ]; then
		run_command "${name}_run" run "$required" "$executable"
	else
		record_skipped "${name}_run" run "build exit code $build_rc"
	fi
}

run_v_build() {
	local name="$1"
	local required="$2"
	local source="$3"
	shift 3
	local executable="$bin_dir/$name.exe"
	local build_rc
	local -a command=(
		"$v_exe"
		-cc "$cc"
		-d sokol_d3d11
		-nocache
		-keepc
		-no-retry-compilation
		-showcc
		-show-c-output
	)
	command+=("$@")
	command+=(-o "$executable" "$source")
	run_command "${name}_build" build "$required" "${command[@]}"
	build_rc="$last_rc"
	inspect_pe "$name" "$executable"
	last_rc="$build_rc"
}

write_environment_report() {
	local report="$out_dir/environment.txt"
	local name
	{
		echo '=== runner ==='
		cmd.exe /c ver 2>&1 || true
		uname -a || true
		printf 'nproc: '
		nproc 2>/dev/null || true
		df -h . || true
		powershell.exe -NoProfile -Command \
			'Get-CimInstance Win32_ComputerSystem | Select-Object NumberOfLogicalProcessors,TotalPhysicalMemory | Format-List; Get-PSDrive -PSProvider FileSystem | Format-Table -AutoSize' \
			2>&1 || true

		echo
		echo '=== selected environment ==='
		for name in MSYSTEM MINGW_PREFIX MSYS2_LOCATION PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CFLAGS CPPFLAGS LDFLAGS VFLAGS ImageOS ImageVersion RUNNER_OS RUNNER_ARCH; do
			printf '%s=%s\n' "$name" "${!name-}"
		done

		echo
		echo '=== command resolution ==='
		for name in v gcc clang ld nm objdump pkg-config pkgconf; do
			printf '%s: ' "$name"
			command -v "$name" 2>&1 || true
		done
		where.exe v.exe gcc.exe clang.exe ld.exe pkg-config.exe pkgconf.exe 2>&1 || true

		echo
		echo '=== versions and revisions ==='
		"$v_exe" version 2>&1 || true
		"$cc" --version 2>&1 || true
		gcc --version 2>&1 || true
		clang --version 2>&1 || true
		ld --version 2>&1 || true
		pkgconf --version 2>&1 || true
		git -C "$(dirname "$v_exe")" rev-parse HEAD 2>&1 || true
		git -C "$gui_dir" rev-parse HEAD 2>&1 || true
		git -C "$HOME/.vmodules/vglyph" rev-parse HEAD 2>&1 || true

		echo
		echo '=== installed packages ==='
		pacman -Q | sort
		for name in \
			"$MINGW_PREFIX/lib/libintl.a" \
			"$MINGW_PREFIX/lib/libiconv.a" \
			"$MINGW_PREFIX/lib/libpangoft2-1.0.a"; do
			pacman -Qo "$name" 2>&1 || true
		done

		echo
		echo '=== pkgconf pangoft2 ==='
		pkgconf --modversion pangoft2 2>&1 || true
		pkgconf --variable=prefix pangoft2 2>&1 || true
		pkgconf --path pangoft2 pango gobject-2.0 glib-2.0 2>&1 || true
		pkgconf --print-requires pangoft2 2>&1 || true
		pkgconf --print-requires-private pangoft2 2>&1 || true
		pkgconf --cflags --libs pangoft2 2>&1 || true
		pkgconf --static --cflags --libs pangoft2 2>&1 || true
		pkgconf --static --simulate pangoft2 2>&1 || true
		pkgconf --static --digraph pangoft2 2>&1 || true

		echo
		echo '=== libintl/libiconv symbol boundary ==='
		nm -u "$MINGW_PREFIX/lib/libintl.a" 2>&1 | grep -Ei 'iconv' || true
		nm -g --defined-only "$MINGW_PREFIX/lib/libiconv.a" 2>&1 | grep -Ei 'iconv' || true
	} > "$report" 2>&1
	cat "$report"
}

copy_pkgconfig_metadata() {
	local pc_path
	local unix_path
	while IFS= read -r pc_path; do
		[ -n "$pc_path" ] || continue
		unix_path="$(to_unix_path "$pc_path")"
		if [ -f "$unix_path" ]; then
			cp "$unix_path" "$pkgconfig_dir/$(basename "$unix_path")"
		fi
	done < <(pkgconf --path pangoft2 pango gobject-2.0 glib-2.0 2>/dev/null || true)
	pkgconf --cflags pangoft2 > "$pkgconfig_dir/pangoft2.cflags.txt" 2>&1 || true
	pkgconf --libs pangoft2 > "$pkgconfig_dir/pangoft2.dynamic-libs.txt" 2>&1 || true
	pkgconf --static --libs pangoft2 > "$pkgconfig_dir/pangoft2.static-libs.txt" 2>&1 || true
	find "$MINGW_PREFIX/lib/pkgconfig" -maxdepth 1 -type f \
		\( -iname '*intl*.pc' -o -iname '*iconv*.pc' \) -print \
		> "$pkgconfig_dir/intl-iconv-pc-files.txt" 2>&1 || true
}

copy_generated_files() {
	local -a roots=("$PWD")
	local candidate
	local destination
	local manifest="$generated_dir/manifest.tsv"
	local generated_dir_abs
	local unix_candidate
	local source_file
	local index=0
	generated_dir_abs="$(cd "$generated_dir" && pwd)"
	printf 'index\tsource\tartifact\n' > "$manifest"
	for candidate in "${RUNNER_TEMP-}" "${TMP-}" "${TEMP-}"; do
		[ -n "$candidate" ] || continue
		unix_candidate="$(to_unix_path "$candidate")"
		if [ -d "$unix_candidate" ]; then
			roots+=("$unix_candidate")
		fi
	done
	while IFS= read -r -d '' source_file; do
		index=$((index + 1))
		destination="$(printf '%03d' "$index")_$(basename "$source_file")"
		cp "$source_file" "$generated_dir/$destination"
		printf '%s\t%s\t%s\n' "$index" "$source_file" "$destination" >> "$manifest"
	done < <(
		find "${roots[@]}" -maxdepth 8 -type f -newer "$marker_file" \
			! -path "$generated_dir_abs/*" \
			\( -name '*.tmp.c' -o -name '*.tmp.c.rsp' -o -name '*.rsp' \) \
			-print0 2>/dev/null || true
	)
}

write_rsp_order_report() {
	local report="$out_dir/rsp-link-order.txt"
	local rsp_file
	local sequence
	local status
	local found=0
	{
		echo 'Expected positive-control order: -lintl ... -liconv'
		for rsp_file in "$generated_dir"/*.rsp; do
			[ -f "$rsp_file" ] || continue
			found=1
			sequence="$(grep -Eo -- '-lintl|-liconv' "$rsp_file" 2>/dev/null | paste -sd ' ' -)"
			case "$sequence" in
				*'-lintl'*'-liconv'*) status='PASS: a later -liconv follows -lintl' ;;
				*'-lintl'*) status='OBSERVED: -lintl without a later -liconv' ;;
				*'-liconv'*) status='OBSERVED: -liconv without -lintl' ;;
				*) status='NOT OBSERVED' ;;
			esac
			printf '\nfile: %s\nsequence: %s\nstatus: %s\n' "$(basename "$rsp_file")" "${sequence:-none}" "$status"
		done
		if [ "$found" -eq 0 ]; then
			echo 'No V response file was retained; inspect the command logs and generated-file manifest.'
		fi
	} > "$report"
	cat "$report"
}

write_summary() {
	local no_iconv_rc="${case_rc[c_static_noiconv_build]:-not-run}"
	local with_iconv_rc="${case_rc[c_static_iconv_build]:-not-run}"
	local gettext_no_iconv_rc="${case_rc[gettext_static_noiconv_build]:-not-run}"
	local gettext_with_iconv_rc="${case_rc[gettext_static_iconv_build]:-not-run}"
	local v_no_iconv_rc="${case_rc[vglyph_static_noprod_noiconv_build]:-not-run}"
	local v_with_iconv_rc="${case_rc[vglyph_static_noprod_iconv_build]:-not-run}"
	local v_prod_rc="${case_rc[vglyph_static_prod_iconv_build]:-not-run}"
	local showcase_noprod_rc="${case_rc[showcase_static_noprod_iconv_build]:-not-run}"
	local showcase_prod_rc="${case_rc[showcase_static_prod_iconv_build]:-not-run}"
	local github_summary
	{
		echo "## GUI issue #74 — UCRT64 $cc"
		echo
		echo '| Case | Phase | Required | Exit |'
		echo '|---|---|---:|---:|'
		awk -F '\t' 'NR > 1 { printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }' "$results_file"
		echo
		echo '### Discriminating results'
		echo
		echo "- Pango/pkgconf C static: without an explicit final \`-liconv\`=$no_iconv_rc; with it=$with_iconv_rc."
		echo "- Direct gettext C static: without \`-liconv\`=$gettext_no_iconv_rc; with it=$gettext_with_iconv_rc."
		echo "- vglyph static non-prod: without iconv=$v_no_iconv_rc; with iconv=$v_with_iconv_rc."
		echo "- vglyph static with iconv: non-prod=$v_with_iconv_rc; prod=$v_prod_rc."
		echo "- showcase static with iconv: non-prod=$showcase_noprod_rc; prod=$showcase_prod_rc."
		echo "- Required command failures: $required_failures."
		echo
		if [ "$no_iconv_rc" != 0 ] && [ "$no_iconv_rc" != not-run ] && [ "$with_iconv_rc" = 0 ]; then
			echo '- The Pango/pkgconf C oracle isolates a missing static iconv edge in external metadata/order.'
		elif [ "$no_iconv_rc" = 0 ]; then
			echo '- The current MSYS2 package snapshot links the C oracle without an explicit final `-liconv`; inspect pkgconf and symbol artifacts for package drift.'
		fi
		if [ "$v_with_iconv_rc" = 0 ] && [ "$v_prod_rc" != 0 ] && [ "$v_prod_rc" != not-run ]; then
			echo '- vglyph passes without `-prod` and fails with `-prod`; isolate GCC production/LTO before changing dependency metadata.'
		fi
		if [ "$showcase_noprod_rc" = 0 ] && [ "$showcase_prod_rc" != 0 ] && [ "$showcase_prod_rc" != not-run ]; then
			echo '- The large public GUI example isolates the remaining failure to its production build.'
		fi
	} > "$summary_file"
	cat "$summary_file"
	if [ -n "${GITHUB_STEP_SUMMARY-}" ]; then
		github_summary="$(to_unix_path "$GITHUB_STEP_SUMMARY")"
		cat "$summary_file" >> "$github_summary"
	fi
}

write_environment_report
copy_pkgconfig_metadata

read -r -a pango_cflags <<< "$(pkgconf --cflags pangoft2 2>/dev/null || true)"
read -r -a pango_dynamic_libs <<< "$(pkgconf --libs pangoft2 2>/dev/null || true)"
read -r -a pango_static_libs <<< "$(pkgconf --static --libs pangoft2 2>/dev/null || true)"

c_dynamic_exe="$bin_dir/c_dynamic.exe"
run_command c_dynamic_build build yes "$cc" "${pango_cflags[@]}" "$probe_c" -o "$c_dynamic_exe" "${pango_dynamic_libs[@]}"
c_dynamic_build_rc="$last_rc"
inspect_pe c_dynamic "$c_dynamic_exe"
run_built_executable c_dynamic yes "$c_dynamic_exe" "$c_dynamic_build_rc"

c_static_noiconv_exe="$bin_dir/c_static_noiconv.exe"
run_command c_static_noiconv_build build no "$cc" -static "${pango_cflags[@]}" "$probe_c" -o "$c_static_noiconv_exe" "${pango_static_libs[@]}"
c_static_noiconv_build_rc="$last_rc"
inspect_pe c_static_noiconv "$c_static_noiconv_exe"
run_built_executable c_static_noiconv no "$c_static_noiconv_exe" "$c_static_noiconv_build_rc"

c_static_iconv_exe="$bin_dir/c_static_iconv.exe"
run_command c_static_iconv_build build yes "$cc" -static "${pango_cflags[@]}" "$probe_c" -o "$c_static_iconv_exe" "${pango_static_libs[@]}" -liconv
c_static_iconv_build_rc="$last_rc"
inspect_pe c_static_iconv "$c_static_iconv_exe"
run_built_executable c_static_iconv yes "$c_static_iconv_exe" "$c_static_iconv_build_rc"

gettext_static_noiconv_exe="$bin_dir/gettext_static_noiconv.exe"
run_command gettext_static_noiconv_build build no "$cc" -static "$gettext_probe_c" -o "$gettext_static_noiconv_exe" -lintl
gettext_static_noiconv_build_rc="$last_rc"
inspect_pe gettext_static_noiconv "$gettext_static_noiconv_exe"
run_built_executable gettext_static_noiconv no "$gettext_static_noiconv_exe" "$gettext_static_noiconv_build_rc"

gettext_static_iconv_exe="$bin_dir/gettext_static_iconv.exe"
run_command gettext_static_iconv_build build yes "$cc" -static "$gettext_probe_c" -o "$gettext_static_iconv_exe" -lintl -liconv
gettext_static_iconv_build_rc="$last_rc"
inspect_pe gettext_static_iconv "$gettext_static_iconv_exe"
run_built_executable gettext_static_iconv yes "$gettext_static_iconv_exe" "$gettext_static_iconv_build_rc"

run_v_build vglyph_dynamic_noprod yes "$probe_v" -cflags '-Wno-error -Wno-incompatible-pointer-types'
vglyph_dynamic_noprod_build_rc="$last_rc"
run_built_executable vglyph_dynamic_noprod yes "$bin_dir/vglyph_dynamic_noprod.exe" "$vglyph_dynamic_noprod_build_rc"

run_v_build vglyph_dynamic_prod yes "$probe_v" -prod -cflags '-Wno-error -Wno-incompatible-pointer-types'
vglyph_dynamic_prod_build_rc="$last_rc"
run_built_executable vglyph_dynamic_prod yes "$bin_dir/vglyph_dynamic_prod.exe" "$vglyph_dynamic_prod_build_rc"

run_v_build vglyph_static_noprod_noiconv no "$probe_v" -cflags '-static -Wno-error -Wno-incompatible-pointer-types'
vglyph_static_noprod_noiconv_build_rc="$last_rc"
run_built_executable vglyph_static_noprod_noiconv no "$bin_dir/vglyph_static_noprod_noiconv.exe" "$vglyph_static_noprod_noiconv_build_rc"

run_v_build vglyph_static_noprod_iconv yes "$probe_v" -cflags '-static -Wno-error -Wno-incompatible-pointer-types' -ldflags '-liconv'
vglyph_static_noprod_iconv_build_rc="$last_rc"
run_built_executable vglyph_static_noprod_iconv yes "$bin_dir/vglyph_static_noprod_iconv.exe" "$vglyph_static_noprod_iconv_build_rc"

run_v_build vglyph_static_prod_iconv yes "$probe_v" -prod -cflags '-static -Wno-error -Wno-incompatible-pointer-types' -ldflags '-liconv'
vglyph_static_prod_iconv_build_rc="$last_rc"
run_built_executable vglyph_static_prod_iconv yes "$bin_dir/vglyph_static_prod_iconv.exe" "$vglyph_static_prod_iconv_build_rc"

run_v_build showcase_static_noprod_iconv yes "$showcase_v" -cflags '-static' -ldflags '-mwindows -liconv'
run_v_build showcase_static_prod_iconv yes "$showcase_v" -prod -cflags '-static' -ldflags '-mwindows -liconv'

copy_generated_files
write_rsp_order_report
write_summary

if [ "$required_failures" -ne 0 ]; then
	echo "$required_failures required diagnostic command(s) failed" >&2
	exit 1
fi
