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
	gcc) cxx=g++ ;;
	clang) cxx=clang++ ;;
	*)
		echo "unsupported compiler: $cc" >&2
		exit 2
		;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
probe_c="$script_dir/pango_probe.c"
gettext_probe_c="$script_dir/gettext_probe.c"
probe_v="$script_dir/vglyph_probe.v"
windows_collector="$script_dir/collect_windows_diagnostics.ps1"
showcase_v="$gui_dir/examples/showcase.v"

: "${MINGW_PREFIX:?MINGW_PREFIX is not set; run this script from an MSYS2 UCRT64 shell}"
for required_path in "$v_exe" "$probe_c" "$gettext_probe_c" "$probe_v" "$windows_collector" "$showcase_v"; do
	if [ ! -f "$required_path" ]; then
		echo "required diagnostic input not found: $required_path" >&2
		exit 2
	fi
done
for required_tool in timeout cygpath powershell.exe objdump; do
	if ! command -v "$required_tool" >/dev/null 2>&1; then
		echo "required diagnostic tool not found: $required_tool" >&2
		exit 2
	fi
done

: "${VMODULES:?VMODULES is not set; point it at the Windows-visible V modules directory}"
vmodules_dir="$(cygpath -u "$VMODULES")"
vmodules_windows="$(cygpath -w "$vmodules_dir")"
export VMODULES="$vmodules_windows"
if [ ! -f "$vmodules_dir/vglyph/v.mod" ]; then
	echo "vglyph module not found below VMODULES: $vmodules_dir/vglyph/v.mod" >&2
	exit 2
fi
if ! command -v "$cxx" >/dev/null 2>&1; then
	echo "required C++ linker driver not found: $cxx" >&2
	exit 2
fi

out_dir="$artifact_root/$cc"
logs_dir="$out_dir/logs"
bin_dir="$out_dir/bin"
pe_dir="$out_dir/pe"
pkgconfig_dir="$out_dir/pkgconfig"
generated_dir="$out_dir/generated"
probes_dir="$out_dir/probes"
windows_dir="$out_dir/windows"
results_file="$out_dir/results.tsv"
summary_file="$out_dir/summary.md"
marker_file="$out_dir/.diagnostic-start"
diagnostic_start_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

mkdir -p "$logs_dir" "$bin_dir" "$pe_dir" "$pkgconfig_dir" "$generated_dir" "$probes_dir" "$windows_dir" || exit 2
touch "$marker_file"
cp "$probe_c" "$gettext_probe_c" "$probe_v" "$windows_collector" "$probes_dir/"
printf 'case\tphase\trequired\texit_code\n' > "$results_file"

declare -A case_rc=()
declare -a pango_cflags=()
declare -a pango_dynamic_libs=()
declare -a pango_static_libs=()
declare -a required_v_artifact_cases=()
declare -a static_iconv_order_cases=()
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

record_result() {
	local name="$1"
	local phase="$2"
	local required="$3"
	local command_rc="$4"
	printf '%s\t%s\t%s\t%s\n' "$name" "$phase" "$required" "$command_rc" >> "$results_file"
	case_rc["$name"]="$command_rc"
	last_rc="$command_rc"
	if [ "$required" = yes ] && [ "$command_rc" != 0 ]; then
		required_failures=$((required_failures + 1))
	fi
}

run_command() {
	local name="$1"
	local phase="$2"
	local required="$3"
	shift 3
	local log_file="$logs_dir/$name.log"
	local command_rc
	local timeout_seconds
	case "$phase:$name" in
		build:showcase_*) timeout_seconds=480 ;;
		build:*) timeout_seconds=240 ;;
		run:*) timeout_seconds=45 ;;
		collect:*) timeout_seconds=120 ;;
		*) timeout_seconds=120 ;;
	esac

	{
		printf 'case: %s\nphase: %s\nrequired: %s\ntimeout_seconds: %s\ncommand:' "$name" "$phase" "$required" "$timeout_seconds"
		printf ' %q' "$@"
		printf '\n'
	} | tee "$log_file"

	timeout --signal=TERM --kill-after=15s "${timeout_seconds}s" "$@" 2>&1 | tee -a "$log_file"
	command_rc=${PIPESTATUS[0]}
	printf 'exit_code: %s\n' "$command_rc" | tee -a "$log_file"
	record_result "$name" "$phase" "$required" "$command_rc"
	return 0
}

record_skipped() {
	local name="$1"
	local phase="$2"
	local required="$3"
	local reason="$4"
	printf 'case: %s\nphase: %s\nrequired: %s\nskipped: %s\n' "$name" "$phase" "$required" "$reason" | tee "$logs_dir/$name.log"
	record_result "$name" "$phase" "$required" skipped
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
		timeout --signal=TERM --kill-after=5s 60s objdump -p "$executable"
	} > "$report" 2>&1
	echo "PE imports for $name:"
	grep -i 'DLL Name' "$report" || true
}

check_static_pe() {
	local name="$1"
	local required="$2"
	local executable="$3"
	local build_rc="$4"
	local expected_subsystem="$5"
	local log_file="$logs_dir/${name}_static_pe.log"
	local raw_report="$pe_dir/${name}.gate-objdump.txt"
	local dll_name
	local lower_name
	local gate_rc=0
	local -a third_party_imports=()

	if [ "$build_rc" -ne 0 ]; then
		record_skipped "${name}_static_pe" pe no "build exit code $build_rc"
		return 0
	fi
	if [ ! -f "$executable" ]; then
		record_skipped "${name}_static_pe" pe "$required" 'build returned 0 but the PE output is missing'
		return 0
	fi

	if ! timeout --signal=TERM --kill-after=5s 60s objdump -f -p "$executable" > "$raw_report" 2>&1; then
		gate_rc=2
	fi
	if ! grep -Eq 'architecture:[[:space:]]+i386:x86-64|file format pei-x86-64' "$raw_report"; then
		gate_rc=3
	fi
	case "$expected_subsystem" in
		gui)
			if ! grep -Eq 'Subsystem[[:space:]]+0*2[[:space:]]+\(Windows GUI\)' "$raw_report"; then
				gate_rc=4
			fi
			;;
		console)
			if ! grep -Eq 'Subsystem[[:space:]]+0*3[[:space:]]+\(Windows CUI\)' "$raw_report"; then
				gate_rc=4
			fi
			;;
		*)
			echo "unsupported expected PE subsystem: $expected_subsystem" >&2
			gate_rc=4
			;;
	esac

	while IFS= read -r dll_name; do
		dll_name="${dll_name#*:}"
		dll_name="${dll_name#"${dll_name%%[![:space:]]*}"}"
		dll_name="${dll_name%$'\r'}"
		[ -n "$dll_name" ] || continue
		lower_name="${dll_name,,}"
		if [ -f "$MINGW_PREFIX/bin/$dll_name" ] || [[ "$lower_name" == lib*.dll ]] || [ "$lower_name" = zlib1.dll ]; then
			third_party_imports+=("$dll_name")
		fi
	done < <(grep -i 'DLL Name:' "$raw_report" || true)
	if [ "${#third_party_imports[@]}" -ne 0 ]; then
		gate_rc=5
	fi

	{
		echo "file: $executable"
		echo "expected_subsystem: $expected_subsystem"
		echo "third_party_imports: ${third_party_imports[*]:-none}"
		echo "gate_exit_code: $gate_rc"
	} | tee "$log_file"
	record_result "${name}_static_pe" pe "$required" "$gate_rc"
}

run_built_executable() {
	local name="$1"
	local required="$2"
	local executable="$3"
	local build_rc="$4"
	if [ "$build_rc" -ne 0 ]; then
		record_skipped "${name}_run" run no "build exit code $build_rc"
	elif [ ! -f "$executable" ]; then
		record_skipped "${name}_run" run "$required" 'build returned 0 but the executable is missing'
	else
		run_command "${name}_run" run "$required" "$executable"
	fi
}

run_v_build() {
	local name="$1"
	local required="$2"
	local source="$3"
	shift 3
	local executable="$bin_dir/$name.exe"
	local build_rc
	local proof_required="$required"
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
	if [ "$build_rc" -eq 0 ]; then
		proof_required=yes
	fi
	inspect_pe "$name" "$executable"
	if [ "$proof_required" = yes ]; then
		required_v_artifact_cases+=("$name")
	fi
	case "$name" in
		*_static_*)
			if [[ "$name" == showcase_* ]]; then
				check_static_pe "$name" "$proof_required" "$executable" "$build_rc" gui
			else
				check_static_pe "$name" "$proof_required" "$executable" "$build_rc" console
			fi
			if [ "$proof_required" = yes ] && [[ "$name" == *_iconv ]]; then
				static_iconv_order_cases+=("$name")
			fi
			;;
	esac
	last_rc="$build_rc"
}

write_environment_report() {
	local report="$out_dir/environment.txt"
	local name
	local linker_driver
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
		for name in MSYSTEM MINGW_PREFIX MSYS2_LOCATION VMODULES HOME USERPROFILE PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CFLAGS CPPFLAGS LDFLAGS VFLAGS ImageOS ImageVersion RUNNER_OS RUNNER_ARCH; do
			printf '%s=%s\n' "$name" "${!name-}"
		done

		echo
		echo '=== command resolution ==='
		for name in v gcc g++ clang clang++ ld nm objdump pkg-config pkgconf; do
			printf '%s: ' "$name"
			command -v "$name" 2>&1 || true
		done
		where.exe v.exe gcc.exe clang.exe ld.exe pkg-config.exe pkgconf.exe 2>&1 || true

		echo
		echo '=== versions and revisions ==='
		"$v_exe" version 2>&1 || true
		"$cc" --version 2>&1 || true
		"$cxx" --version 2>&1 || true
		"$cc" -dumpmachine 2>&1 || true
		"$cc" --print-target-triple 2>&1 || true
		linker_driver="$("$cc" -print-prog-name=ld 2>&1 || true)"
		printf 'driver_linker: %s\n' "$linker_driver"
		if [ -n "$linker_driver" ]; then
			"$linker_driver" --version 2>&1 || true
		fi
		for name in collect2 lto1 lto-wrapper as; do
			printf 'driver_%s: ' "$name"
			"$cc" "-print-prog-name=$name" 2>&1 || true
		done
		"$cc" -print-search-dirs 2>&1 || true
		gcc --version 2>&1 || true
		clang --version 2>&1 || true
		ld --version 2>&1 || true
		pkgconf --version 2>&1 || true
		git -C "$(dirname "$v_exe")" rev-parse HEAD 2>&1 || true
		git -C "$gui_dir" rev-parse HEAD 2>&1 || true
		git -C "$vmodules_dir/vglyph" rev-parse HEAD 2>&1 || true

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
	local pc_root
	local destination
	for pc_root in "$MINGW_PREFIX/lib/pkgconfig" "$MINGW_PREFIX/share/pkgconfig"; do
		[ -d "$pc_root" ] || continue
		destination="$pkgconfig_dir/$(basename "$(dirname "$pc_root")")"
		mkdir -p "$destination"
		find "$pc_root" -maxdepth 1 -type f -name '*.pc' -exec cp '{}' "$destination/" \;
	done
	pkgconf --cflags pangoft2 > "$pkgconfig_dir/pangoft2.cflags.txt" 2>&1 || true
	pkgconf --libs pangoft2 > "$pkgconfig_dir/pangoft2.dynamic-libs.txt" 2>&1 || true
	pkgconf --static --libs pangoft2 > "$pkgconfig_dir/pangoft2.static-libs.txt" 2>&1 || true
	find "$pkgconfig_dir" -type f -name '*.pc' -print | sort > "$pkgconfig_dir/pc-manifest.txt"
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

verify_expected_iconv_outcome() {
	local negative_name="$1"
	local positive_name="$2"
	local required="$3"
	local negative_build_name="${negative_name}_build"
	local positive_build_name="${positive_name}_build"
	local negative_rc="${case_rc[$negative_build_name]:-not-run}"
	local positive_rc="${case_rc[$positive_build_name]:-not-run}"
	local negative_log="$logs_dir/$negative_build_name.log"
	local verify_log="$logs_dir/${negative_name}_iconv_boundary.log"
	local verify_rc=0
	local undefined_pattern='undefined reference|undefined symbol|unresolved external'
	local allowed_iconv_pattern='(libiconv_set_relocation_prefix|libiconv_open|libiconv_close|libiconv)'
	local root_error_pattern='cannot import|cannot find|cannot open|no such file or directory|file format not recognized|file not recognized|permission denied|timed out|internal compiler error|segmentation fault|fatal error'
	local line
	local -a undefined_lines=()
	local -a non_iconv_lines=()

	if [ "$positive_rc" != 0 ]; then
		verify_rc=1
		printf 'The positive control %s failed with exit %s; the iconv boundary is indeterminate.\n' \
			"$positive_name" "$positive_rc" > "$verify_log"
	elif [ "$negative_rc" = 0 ]; then
		echo 'The no-extra-iconv control linked successfully; the package snapshot no longer exposes the expected boundary.' > "$verify_log"
	elif [ "$negative_rc" = 124 ] || [ "$negative_rc" = 137 ]; then
		verify_rc=1
		echo "The no-extra-iconv control timed out or was killed (exit $negative_rc); the iconv boundary is indeterminate." > "$verify_log"
	elif [ ! -f "$negative_log" ]; then
		verify_rc=1
		echo "The no-extra-iconv control failed with exit $negative_rc, but its build log is missing." > "$verify_log"
	elif grep -Eiq "$root_error_pattern" "$negative_log"; then
		verify_rc=1
		{
			echo 'The no-extra-iconv control has a non-linker root error; the iconv boundary is indeterminate:'
			grep -Ei "$root_error_pattern" "$negative_log" || true
		} > "$verify_log"
	else
		mapfile -t undefined_lines < <(grep -Ei "$undefined_pattern" "$negative_log" || true)
		for line in "${undefined_lines[@]}"; do
			if ! grep -Eiq "($undefined_pattern).*([^[:alnum:]_]|^)$allowed_iconv_pattern([^[:alnum:]_]|$)" <<< "$line"; then
				non_iconv_lines+=("$line")
			fi
		done
		if [ "${#undefined_lines[@]}" -eq 0 ]; then
			verify_rc=1
			echo "The no-extra-iconv control failed with exit $negative_rc, but no undefined symbol was found." > "$verify_log"
		elif [ "${#non_iconv_lines[@]}" -ne 0 ]; then
			verify_rc=1
			{
				echo 'The no-extra-iconv control has undefined symbols outside the allowed iconv boundary:'
				printf '%s\n' "${non_iconv_lines[@]}"
			} > "$verify_log"
		else
			{
				echo 'Every undefined symbol in the no-extra-iconv control is at the expected iconv boundary:'
				printf '%s\n' "${undefined_lines[@]}"
			} > "$verify_log"
		fi
	fi
	cat "$verify_log"
	record_result "${negative_name}_iconv_boundary" oracle "$required" "$verify_rc"
}

verify_build_flag() {
	local name="$1"
	local expectation="$2"
	local token="$3"
	local build_log="$logs_dir/${name}_build.log"
	local verify_log="$logs_dir/${name}_${expectation}_${token#-}.log"
	local verify_rc=0
	local found=no
	if [ -f "$build_log" ] && grep -Fq -- "$token" "$build_log"; then
		found=yes
	fi
	case "$expectation:$found" in
		present:yes|absent:no) ;;
		*) verify_rc=1 ;;
	esac
	printf 'build_log: %s\nexpected: %s\ntoken: %s\nobserved: %s\n' \
		"$build_log" "$expectation" "$token" "$found" | tee "$verify_log"
	record_result "${name}_${expectation}_${token#-}" flags yes "$verify_rc"
}

verify_generated_artifacts() {
	local name
	local c_count
	local rsp_count
	local sequence
	local order_rc
	local log_file
	for name in "${required_v_artifact_cases[@]}"; do
		c_count="$(find "$generated_dir" -maxdepth 1 -type f -name "*${name}.exe*.tmp.c" | wc -l | tr -d '[:space:]')"
		rsp_count="$(find "$generated_dir" -maxdepth 1 -type f -name "*${name}.exe*.tmp.c.rsp" | wc -l | tr -d '[:space:]')"
		log_file="$logs_dir/${name}_generated_artifacts.log"
		printf 'case: %s\ngenerated_c_count: %s\nresponse_file_count: %s\n' "$name" "$c_count" "$rsp_count" | tee "$log_file"
		if [ "$c_count" -gt 0 ]; then
			record_result "${name}_generated_c" artifact yes 0
		else
			record_result "${name}_generated_c" artifact yes 1
		fi
		if [ "$rsp_count" -gt 0 ]; then
			record_result "${name}_response_file" artifact yes 0
		else
			record_result "${name}_response_file" artifact yes 1
		fi
	done

	for name in "${static_iconv_order_cases[@]}"; do
		sequence="$(find "$generated_dir" -maxdepth 1 -type f -name "*${name}.exe*.tmp.c.rsp" -exec grep -Eho -- '-lintl|-liconv' '{}' + 2>/dev/null | paste -sd ' ' -)"
		order_rc=1
		if [[ "$sequence" == *-lintl* ]] && [[ "${sequence#*-lintl}" == *-liconv* ]]; then
			order_rc=0
		fi
		log_file="$logs_dir/${name}_intl_iconv_order.log"
		printf 'case: %s\nexpected: -lintl ... -liconv\nsequence: %s\n' "$name" "${sequence:-none}" | tee "$log_file"
		record_result "${name}_intl_iconv_order" artifact yes "$order_rc"
	done
}

collect_windows_diagnostics() {
	local collector_windows
	local output_windows
	collector_windows="$(cygpath -w "$windows_collector")"
	output_windows="$(cygpath -w "$windows_dir")"
	run_command windows_error_reporting collect yes \
		powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
		-File "$collector_windows" -StartUtc "$diagnostic_start_utc" -OutputDirectory "$output_windows"
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
	local raw_pango_oracle_rc="${case_rc[c_static_noiconv_iconv_boundary]:-not-run}"
	local full_no_iconv_rc="${case_rc[c_static_consumer_noiconv_build]:-not-run}"
	local full_with_iconv_rc="${case_rc[c_static_consumer_iconv_build]:-not-run}"
	local full_pango_oracle_rc="${case_rc[c_static_consumer_noiconv_iconv_boundary]:-not-run}"
	local gettext_no_iconv_rc="${case_rc[gettext_static_noiconv_build]:-not-run}"
	local gettext_with_iconv_rc="${case_rc[gettext_static_iconv_build]:-not-run}"
	local gettext_oracle_rc="${case_rc[gettext_static_noiconv_iconv_boundary]:-not-run}"
	local v_no_iconv_rc="${case_rc[vglyph_static_noprod_noiconv_build]:-not-run}"
	local v_with_iconv_rc="${case_rc[vglyph_static_noprod_iconv_build]:-not-run}"
	local v_raw_oracle_rc="${case_rc[vglyph_static_noprod_noiconv_iconv_boundary]:-not-run}"
	local v_manual_no_iconv_rc="${case_rc[vglyph_static_manual_noiconv_build]:-not-run}"
	local v_manual_with_iconv_rc="${case_rc[vglyph_static_manual_iconv_build]:-not-run}"
	local v_manual_oracle_rc="${case_rc[vglyph_static_manual_noiconv_iconv_boundary]:-not-run}"
	local v_s2_rc="${case_rc[vglyph_static_prod_no_prod_options_iconv_build]:-not-run}"
	local v_prod_rc="${case_rc[vglyph_static_prod_iconv_build]:-not-run}"
	local showcase_noprod_rc="${case_rc[showcase_static_noprod_iconv_build]:-not-run}"
	local showcase_s2_rc="${case_rc[showcase_static_prod_no_prod_options_iconv_build]:-not-run}"
	local showcase_prod_rc="${case_rc[showcase_static_prod_iconv_build]:-not-run}"
	local github_summary
	local s3_label='full prod (Windows Clang FLTO disabled by V)'
	if [ "$cc" = gcc ]; then
		s3_label='full prod/LTO'
	fi
	{
		echo "## GUI issue #74 — UCRT64 $cc"
		echo
		echo '| Case | Phase | Required | Exit |'
		echo '|---|---|---:|---:|'
		awk -F '\t' 'NR > 1 { printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }' "$results_file"
		echo
		echo '### Discriminating results'
		echo
		echo "- Toolchain: MSYS2 UCRT64 $cc; this is not a CLANG64-shell result."
		echo "- Raw Pango/pkgconf C-driver static: without an explicit final \`-liconv\`=$no_iconv_rc; with it=$with_iconv_rc; exclusive-iconv classification=$raw_pango_oracle_rc."
		echo "- Completed Pango static consumer (GLib static macros + $cxx driver): without \`-liconv\`=$full_no_iconv_rc; with final \`-liconv\`=$full_with_iconv_rc; exclusive-iconv classification=$full_pango_oracle_rc."
		echo "- Direct gettext C static: without \`-liconv\`=$gettext_no_iconv_rc; with it=$gettext_with_iconv_rc; exclusive-iconv classification=$gettext_oracle_rc."
		echo "- Reporter-faithful vglyph static non-prod: without iconv=$v_no_iconv_rc; with iconv=$v_with_iconv_rc; exclusive-iconv classification=$v_raw_oracle_rc."
		echo "- Manual-closure vglyph isolation (GLib static macros + \`-lstdc++\`): without iconv=$v_manual_no_iconv_rc; with final iconv=$v_manual_with_iconv_rc; exclusive-iconv classification=$v_manual_oracle_rc."
		echo "- Reporter-flag vglyph with iconv: non-prod=$v_with_iconv_rc; S2 prod/no-prod-options=$v_s2_rc; S3 $s3_label=$v_prod_rc."
		echo "- Reporter-flag showcase with iconv: non-prod=$showcase_noprod_rc; S2 prod/no-prod-options=$showcase_s2_rc; S3 $s3_label=$showcase_prod_rc."
		echo '- Showcase is a public, link-only surrogate for the private application; its GUI executable is not launched on the runner.'
		echo '- Static PE architecture/subsystem/imports, retained C/RSP files, link order, and S2/S3 flags are required gates.'
		echo "- Targeted Event Viewer and textual WER metadata are under \`windows/\`; memory dumps are never uploaded."
		echo "- Required command failures: $required_failures."
		echo
		if [ "$raw_pango_oracle_rc" = 0 ] && [ "$no_iconv_rc" != 0 ] && [ "$no_iconv_rc" != not-run ]; then
			echo '- The raw Pango/pkgconf C-driver pair isolates a missing static iconv edge in external metadata/order.'
		elif [ "$no_iconv_rc" = 0 ]; then
			echo "- The current MSYS2 package snapshot links the raw C oracle without an explicit final \`-liconv\`; inspect pkgconf and symbol artifacts for package drift."
		elif [ "$raw_pango_oracle_rc" != 0 ] && [ "$raw_pango_oracle_rc" != not-run ]; then
			echo '- The raw Pango/pkgconf failure is not exclusively iconv; inspect static GLib import macros and C++ runtime edges separately.'
		fi
		if [ "$full_pango_oracle_rc" = 0 ] && [ "$full_no_iconv_rc" != 0 ] && [ "$full_no_iconv_rc" != not-run ]; then
			echo '- After supplying the documented static-consumer macros and C++ driver, the completed Pango control isolates the final iconv edge.'
		fi
		if [ "$gettext_oracle_rc" = 0 ] && [ "$gettext_no_iconv_rc" != 0 ] && [ "$gettext_no_iconv_rc" != not-run ]; then
			echo '- The direct gettext pair independently isolates the libintl-to-iconv static edge without Pango, GLib, HarfBuzz, or Graphite.'
		fi
		if [ "$v_raw_oracle_rc" != 0 ] && [ "$v_raw_oracle_rc" != not-run ]; then
			echo '- The reporter-faithful V pair is not exclusively an iconv boundary; it remains the end-to-end resolution gate, not the manual closure control.'
		fi
		if [ "$v_manual_oracle_rc" = 0 ] && [ "$v_manual_no_iconv_rc" != 0 ] && [ "$v_manual_no_iconv_rc" != not-run ]; then
			echo '- The separately labelled V manual-closure pair isolates iconv after supplying static GLib/C++ consumer requirements; it is not the reporter command.'
		fi
		if [ "$v_with_iconv_rc" = 0 ] && [ "$v_prod_rc" != 0 ] && [ "$v_prod_rc" != not-run ]; then
			echo "- vglyph passes without \`-prod\` and fails in S3; isolate $cc $s3_label before changing dependency metadata."
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

run_command vglyph_module_check check yes "$v_exe" -check "$probe_v"

c_dynamic_exe="$bin_dir/c_dynamic.exe"
run_command c_dynamic_build build yes "$cc" "${pango_cflags[@]}" "$probe_c" -o "$c_dynamic_exe" "${pango_dynamic_libs[@]}"
c_dynamic_build_rc="$last_rc"
inspect_pe c_dynamic "$c_dynamic_exe"
run_built_executable c_dynamic yes "$c_dynamic_exe" "$c_dynamic_build_rc"

c_static_noiconv_exe="$bin_dir/c_static_noiconv.exe"
run_command c_static_noiconv_build build no "$cc" -static "${pango_cflags[@]}" "$probe_c" -o "$c_static_noiconv_exe" "${pango_static_libs[@]}"
c_static_noiconv_build_rc="$last_rc"
inspect_pe c_static_noiconv "$c_static_noiconv_exe"
check_static_pe c_static_noiconv yes "$c_static_noiconv_exe" "$c_static_noiconv_build_rc" console
run_built_executable c_static_noiconv yes "$c_static_noiconv_exe" "$c_static_noiconv_build_rc"

c_static_iconv_exe="$bin_dir/c_static_iconv.exe"
run_command c_static_iconv_build build no "$cc" -static "${pango_cflags[@]}" "$probe_c" -o "$c_static_iconv_exe" "${pango_static_libs[@]}" -liconv
c_static_iconv_build_rc="$last_rc"
inspect_pe c_static_iconv "$c_static_iconv_exe"
check_static_pe c_static_iconv yes "$c_static_iconv_exe" "$c_static_iconv_build_rc" console
verify_expected_iconv_outcome c_static_noiconv c_static_iconv no
run_built_executable c_static_iconv yes "$c_static_iconv_exe" "$c_static_iconv_build_rc"

c_static_consumer_noiconv_exe="$bin_dir/c_static_consumer_noiconv.exe"
pango_static_obj="$generated_dir/pango_probe_static.o"
run_command c_static_probe_compile build yes "$cc" -c -DGLIB_STATIC_COMPILATION -DGOBJECT_STATIC_COMPILATION "${pango_cflags[@]}" "$probe_c" -o "$pango_static_obj"
run_command c_static_consumer_noiconv_build build no "$cxx" -static "$pango_static_obj" -o "$c_static_consumer_noiconv_exe" "${pango_static_libs[@]}" -lstdc++
c_static_consumer_noiconv_build_rc="$last_rc"
inspect_pe c_static_consumer_noiconv "$c_static_consumer_noiconv_exe"
check_static_pe c_static_consumer_noiconv yes "$c_static_consumer_noiconv_exe" "$c_static_consumer_noiconv_build_rc" console
run_built_executable c_static_consumer_noiconv yes "$c_static_consumer_noiconv_exe" "$c_static_consumer_noiconv_build_rc"

c_static_consumer_iconv_exe="$bin_dir/c_static_consumer_iconv.exe"
run_command c_static_consumer_iconv_build build yes "$cxx" -static "$pango_static_obj" -o "$c_static_consumer_iconv_exe" "${pango_static_libs[@]}" -lstdc++ -liconv
c_static_consumer_iconv_build_rc="$last_rc"
inspect_pe c_static_consumer_iconv "$c_static_consumer_iconv_exe"
check_static_pe c_static_consumer_iconv yes "$c_static_consumer_iconv_exe" "$c_static_consumer_iconv_build_rc" console
verify_expected_iconv_outcome c_static_consumer_noiconv c_static_consumer_iconv yes
run_built_executable c_static_consumer_iconv yes "$c_static_consumer_iconv_exe" "$c_static_consumer_iconv_build_rc"

gettext_static_noiconv_exe="$bin_dir/gettext_static_noiconv.exe"
run_command gettext_static_noiconv_build build no "$cc" -static "$gettext_probe_c" -o "$gettext_static_noiconv_exe" -lintl
gettext_static_noiconv_build_rc="$last_rc"
inspect_pe gettext_static_noiconv "$gettext_static_noiconv_exe"
check_static_pe gettext_static_noiconv yes "$gettext_static_noiconv_exe" "$gettext_static_noiconv_build_rc" console
run_built_executable gettext_static_noiconv yes "$gettext_static_noiconv_exe" "$gettext_static_noiconv_build_rc"

gettext_static_iconv_exe="$bin_dir/gettext_static_iconv.exe"
run_command gettext_static_iconv_build build yes "$cc" -static "$gettext_probe_c" -o "$gettext_static_iconv_exe" -lintl -liconv
gettext_static_iconv_build_rc="$last_rc"
inspect_pe gettext_static_iconv "$gettext_static_iconv_exe"
check_static_pe gettext_static_iconv yes "$gettext_static_iconv_exe" "$gettext_static_iconv_build_rc" console
verify_expected_iconv_outcome gettext_static_noiconv gettext_static_iconv yes
run_built_executable gettext_static_iconv yes "$gettext_static_iconv_exe" "$gettext_static_iconv_build_rc"

run_v_build vglyph_dynamic_noprod yes "$probe_v" -cflags '-Wno-error -Wno-incompatible-pointer-types'
vglyph_dynamic_noprod_build_rc="$last_rc"
run_built_executable vglyph_dynamic_noprod yes "$bin_dir/vglyph_dynamic_noprod.exe" "$vglyph_dynamic_noprod_build_rc"

run_v_build vglyph_dynamic_prod yes "$probe_v" -prod -cflags '-Wno-error -Wno-incompatible-pointer-types'
vglyph_dynamic_prod_build_rc="$last_rc"
run_built_executable vglyph_dynamic_prod yes "$bin_dir/vglyph_dynamic_prod.exe" "$vglyph_dynamic_prod_build_rc"

run_v_build vglyph_static_noprod_noiconv no "$probe_v" -cflags '-static -Wno-error -Wno-incompatible-pointer-types'
vglyph_static_noprod_noiconv_build_rc="$last_rc"
run_built_executable vglyph_static_noprod_noiconv yes "$bin_dir/vglyph_static_noprod_noiconv.exe" "$vglyph_static_noprod_noiconv_build_rc"

run_v_build vglyph_static_noprod_iconv yes "$probe_v" -cflags '-static -Wno-error -Wno-incompatible-pointer-types' -ldflags '-liconv'
vglyph_static_noprod_iconv_build_rc="$last_rc"
verify_expected_iconv_outcome vglyph_static_noprod_noiconv vglyph_static_noprod_iconv yes
run_built_executable vglyph_static_noprod_iconv yes "$bin_dir/vglyph_static_noprod_iconv.exe" "$vglyph_static_noprod_iconv_build_rc"

run_v_build vglyph_static_manual_noiconv no "$probe_v" -cflags '-static -DGOBJECT_STATIC_COMPILATION -DGLIB_STATIC_COMPILATION -Wno-error -Wno-incompatible-pointer-types' -ldflags '-lstdc++'
vglyph_static_manual_noiconv_build_rc="$last_rc"
run_built_executable vglyph_static_manual_noiconv yes "$bin_dir/vglyph_static_manual_noiconv.exe" "$vglyph_static_manual_noiconv_build_rc"

run_v_build vglyph_static_manual_iconv yes "$probe_v" -cflags '-static -DGOBJECT_STATIC_COMPILATION -DGLIB_STATIC_COMPILATION -Wno-error -Wno-incompatible-pointer-types' -ldflags '-lstdc++ -liconv'
vglyph_static_manual_iconv_build_rc="$last_rc"
verify_expected_iconv_outcome vglyph_static_manual_noiconv vglyph_static_manual_iconv yes
run_built_executable vglyph_static_manual_iconv yes "$bin_dir/vglyph_static_manual_iconv.exe" "$vglyph_static_manual_iconv_build_rc"

run_v_build vglyph_static_prod_no_prod_options_iconv yes "$probe_v" -prod -no-prod-options -cflags '-static -Wno-error -Wno-incompatible-pointer-types' -ldflags '-liconv'
vglyph_static_prod_no_prod_options_iconv_build_rc="$last_rc"
verify_build_flag vglyph_static_prod_no_prod_options_iconv absent -flto
run_built_executable vglyph_static_prod_no_prod_options_iconv yes "$bin_dir/vglyph_static_prod_no_prod_options_iconv.exe" "$vglyph_static_prod_no_prod_options_iconv_build_rc"

run_v_build vglyph_static_prod_iconv yes "$probe_v" -prod -cflags '-static -Wno-error -Wno-incompatible-pointer-types' -ldflags '-liconv'
vglyph_static_prod_iconv_build_rc="$last_rc"
if [ "$cc" = gcc ]; then
	verify_build_flag vglyph_static_prod_iconv present -flto
else
	verify_build_flag vglyph_static_prod_iconv absent -flto
fi
run_built_executable vglyph_static_prod_iconv yes "$bin_dir/vglyph_static_prod_iconv.exe" "$vglyph_static_prod_iconv_build_rc"

run_v_build showcase_static_noprod_iconv yes "$showcase_v" -cflags '-static' -ldflags '-mwindows -liconv'
run_v_build showcase_static_prod_no_prod_options_iconv yes "$showcase_v" -prod -no-prod-options -cflags '-static' -ldflags '-mwindows -liconv'
verify_build_flag showcase_static_prod_no_prod_options_iconv absent -flto
run_v_build showcase_static_prod_iconv yes "$showcase_v" -prod -cflags '-static' -ldflags '-mwindows -liconv'
if [ "$cc" = gcc ]; then
	verify_build_flag showcase_static_prod_iconv present -flto
else
	verify_build_flag showcase_static_prod_iconv absent -flto
fi

collect_windows_diagnostics
copy_generated_files
verify_generated_artifacts
write_rsp_order_report
write_summary

if [ "$required_failures" -ne 0 ]; then
	echo "$required_failures required diagnostic command(s) failed" >&2
	exit 1
fi
