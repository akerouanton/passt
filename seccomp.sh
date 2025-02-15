#!/bin/sh -eu
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# PASST - Plug A Simple Socket Transport
#  for qemu/UNIX domain socket mode
#
# PASTA - Pack A Subtle Tap Abstraction
#  for network namespace/tap device mode
#
# seccomp.sh - Build seccomp profiles from "#syscalls[:PROFILE]" code comments
#
# Copyright (c) 2021 Red Hat GmbH
# Author: Stefano Brivio <sbrivio@redhat.com>

TMP="$(mktemp)"
IN="$@"
OUT="$(mktemp)"

[ -z "${ARCH}" ] && ARCH="$(uname -m)"
[ -z "${CC}" ] && CC="cc"

AUDIT_ARCH="AUDIT_ARCH_$(echo ${ARCH} | tr [a-z] [A-Z]             \
                                      | sed 's/^ARM.*/ARM/'        \
                                      | sed 's/I[456]86/I386/'     \
                                      | sed 's/PPC64/PPC/'         \
                                      | sed 's/PPCLE/PPC64LE/'     \
                                      | sed 's/MIPS64EL/MIPSEL64/' \
                                      | sed 's/HPPA/PARISC/'       \
                                      | sed 's/SH4/SH/')"

HEADER="/* This file was automatically generated by $(basename ${0}) */

#ifndef AUDIT_ARCH_PPC64LE
#define AUDIT_ARCH_PPC64LE (AUDIT_ARCH_PPC64 | __AUDIT_ARCH_LE)
#endif"

# Prefix for each profile: check that 'arch' in seccomp_data is matching
PRE='
struct sock_filter filter_@PROFILE@[] = {
	/* cppcheck-suppress [badBitmaskCheck, unmatchedSuppression] */
	BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
		 (offsetof(struct seccomp_data, arch))),
	BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, @AUDIT_ARCH@, 0, @KILL@),
	/* cppcheck-suppress [badBitmaskCheck, unmatchedSuppression] */
	BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
		 (offsetof(struct seccomp_data, nr))),

'

# Suffix for each profile: return actions
POST='	BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
	BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
};
'

# Syscall, @NR@: number, @ALLOW@: offset to RET_ALLOW, @NAME@: syscall name
CALL='	BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, @NR@, @ALLOW@, 0), /* @NAME@ */'

# Binary search tree node or leaf, @NR@: value, @R@: right jump, @L@: left jump
BST='	BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, @NR@, @R@, @L@),'

# cleanup() - Remove temporary file if it exists
cleanup() {
	rm -f "${TMP}" "${OUT}"
}
trap "cleanup" EXIT

# sub() - Substitute in-place file line with processed template line
# $1:	Line number
# $2:	Template name (variable name)
# $@:	Replacement for @KEY@ in the form KEY:value
sub() {
	IFS=
	__line_no="${1}"
	__template="$(eval printf '%s' "\${${2}}")"
	shift; shift

	sed -i "${__line_no}s#.*#${__template}#" "${TMP}"

	IFS=' '
	for __def in ${@}; do
		__key="@${__def%%:*}@"
		__value="${__def#*:}"
		sed -i "${__line_no}s/${__key}/${__value}/" "${TMP}"
	done
	unset IFS
}

# finish() - Finalise header file from temporary files with prefix and suffix
# $1:	Variable name of prefix
# $@:	Replacements for prefix variable
finish() {
	IFS=
	__out="$(eval printf '%s' "\${${1}}")"
	shift

	IFS=' '
	for __def in ${@}; do
		__key="@${__def%%:*}@"
		__value="${__def#*:}"
		__out="$(printf '%s' "${__out}" | sed "s#${__key}#${__value}#")"
	done

	printf '%s\n' "${__out}" >> "${OUT}"
	cat "${TMP}" >> "${OUT}"
	rm "${TMP}"
	printf '%s' "${POST}" >> "${OUT}"
	unset IFS
}

# log2() - Binary logarithm
# $1:	Operand
log2() {
	__x=-1
	__y=${1}
	while [ ${__y} -gt 0 ]; do : $((__y >>= 1)); __x=$((__x + 1)); done
	echo ${__x}
}

# syscall_nr - Get syscall number from compiler
# $1:	Name of syscall
syscall_nr() {
	__in="$(printf "#include <asm-generic/unistd.h>\n#include <sys/syscall.h>\n__NR_%s" ${1})"
	__out="$(echo "${__in}" | ${CC} -E -xc - -o - | tail -1)"
	[ "${__out}" = "__NR_$1" ] && return 1

	# Output might be in the form "(x + y)" (seen on armv6l, armv7l)
	__out="$(eval echo $((${__out})))"
	echo "${__out}"
}

filter() {
	__filtered=
	for __c in ${@}; do
		__arch_match=0
		case ${__c} in
		*:*)
			case ${__c} in
			${ARCH}:*)
				__arch_match=1
				__c=${__c##*:}
				;;
			esac
			;;
		*)
			__arch_match=1
			;;
		esac
		[ ${__arch_match} -eq 0 ] && continue

		IFS='| '
		__found=0
		for __name in ${__c}; do
			syscall_nr "${__name}" >/dev/null && __found=1 && break
		done
		unset IFS

		if [ ${__found} -eq 0 ]; then
			echo
			echo "Warning: no syscall number for ${__c}" >&2
			echo "  none of these syscalls will be allowed" >&2
			continue
		fi

		__filtered="${__filtered} ${__name}"
	done

	echo "${__filtered}" | tr ' ' '\n' | sort -u
}

# gen_profile() - Build struct sock_filter for a single profile
# $1:	Profile name
# $@:	Names of allowed system calls, amount padded to next power of two
gen_profile() {
	__profile="${1}"
	shift

	__statements_calls=${#}
	__bst_levels=$(log2 $(( __statements_calls / 4 )) )
	__statements_bst=$(( __statements_calls / 4 - 1 ))
	__statements=$((__statements_calls + __statements_bst))

	for __i in $(seq 1 ${__statements_bst} ); do
		echo -1 >> "${TMP}"
	done
	for __i in $(seq 1 ${__statements_calls} ); do
		__syscall_name="$(eval echo \${${__i}})"
		if ! syscall_nr ${__syscall_name} >> "${TMP}"; then
			echo "Cannot get syscall number for ${__syscall_name}"
			exit 1
		fi
		eval __syscall_nr_$(tail -1 "${TMP}")="${__syscall_name}"
	done
	sort -go "${TMP}" "${TMP}"

	__distance=$(( __statements_calls / 2 ))
	__level_nodes=1
	__ll=0
	__line=1
	for __level in $(seq 1 $(( __bst_levels - 1 )) ); do
		# Nodes
		__cmp_pos=${__distance}

		for __node in $(seq 1 ${__level_nodes}); do
			__cmp_line=$(( __statements_bst + __cmp_pos ))
			__lr=$(( __ll + 1 ))
			__nr="$(sed -n ${__cmp_line}p "${TMP}")"

			sub ${__line} BST "NR:${__nr}" "L:${__ll}" "R:${__lr}"

			__ll=${__lr}
			__line=$(( __line + 1 ))
			__cmp_pos=$(( __cmp_pos + __distance * 2 ))
		done

		__distance=$(( __distance / 2 ))
		__level_nodes=$(( __level_nodes * 2 ))
	done

	# Leaves
	__ll=$(( __level_nodes - 1 ))
	__lr=$(( __ll + __distance - 1 ))
	__cmp_pos=${__distance}

	for __leaf in $(seq 1 ${__level_nodes}); do
		__cmp_line=$(( __statements_bst + __cmp_pos ))
		__nr="$(sed -n ${__cmp_line}p "${TMP}")"
		sub ${__line} BST "NR:${__nr}" "L:${__ll}" "R:${__lr}"

		__ll=$(( __lr + __distance - 1 ))
		__lr=$(( __ll + __distance))
		__line=$(( __line + 1 ))
		__cmp_pos=$(( __cmp_pos + __distance * 2 ))
	done

	# Calls
	for __i in $(seq $(( __statements_bst + 1 )) ${__statements}); do
		__nr="$(sed -n ${__i}p "${TMP}")"
		eval __name="\${__syscall_nr_${__nr}}"
		__allow=$(( __statements - __i + 1 ))
		sub ${__i} CALL "NR:${__nr}" "NAME:${__name}" "ALLOW:${__allow}"
	done

	finish PRE "PROFILE:${__profile}" "KILL:$(( __statements + 1))" \
	       "AUDIT_ARCH:${AUDIT_ARCH}"
}

printf '%s\n' "${HEADER}" > "${OUT}"
__profiles="$(sed -n 's/[\t ]*\*[\t ]*#syscalls:\([^ ]*\).*/\1/p' ${IN} | sort -u)"
for __p in ${__profiles}; do
	__calls="$(sed -n 's/[\t ]*\*[\t ]*#syscalls\(:'"${__p}"'\|\)[\t ]\{1,\}\(.*\)/\2/p' ${IN})"
	__calls="${__calls} ${EXTRA_SYSCALLS:-}"
	__calls="$(filter ${__calls})"

	cols="$(stty -a | sed -n 's/.*columns \([0-9]*\).*/\1/p' || :)" 2>/dev/null
	case $cols in [0-9]*) col_args="-w ${cols}";; *) col_args="";; esac
	echo "seccomp profile ${__p} allows: ${__calls}" | tr '\n' ' ' | fmt -t ${col_args}

	# Pad here to keep gen_profile() "simple"
	__count=0
	for __c in ${__calls}; do __count=$(( __count + 1 )); done
	__padded=$(( 1 << (( $(log2 ${__count}) + 1 )) ))
	for __i in $( seq ${__count} $(( __padded - 1 )) ); do
		__calls="${__calls} read"
	done

	gen_profile "${__p}" ${__calls}
done

mv "${OUT}" seccomp.h
