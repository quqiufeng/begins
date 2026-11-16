savedcmd_meson-vdec.mod.o := aarch64-linux-gnu-gcc -Wp,-MMD,./.meson-vdec.mod.o.d -nostdinc -I/x96-build/7.2.12-trim/arch/arm64/include -I/x96-build/kbuild-trim/arch/arm64/include/generated -I/x96-build/7.2.12-trim/include -I/x96-build/kbuild-trim/include -I/x96-build/7.2.12-trim/arch/arm64/include/uapi -I/x96-build/kbuild-trim/arch/arm64/include/generated/uapi -I/x96-build/7.2.12-trim/include/uapi -I/x96-build/kbuild-trim/include/generated/uapi -include /x96-build/7.2.12-trim/include/linux/compiler-version.h -include /x96-build/7.2.12-trim/include/linux/kconfig.h -include /x96-build/7.2.12-trim/include/linux/compiler_types.h -D__KERNEL__ -mlittle-endian -DKASAN_SHADOW_SCALE_SHIFT= -fshort-wchar -funsigned-char -fno-common -fno-PIE -fno-strict-aliasing -std=gnu11 -fms-extensions -mgeneral-regs-only -DCONFIG_CC_HAS_K_CONSTRAINT=1 -Wno-psabi -mabi=lp64 -fno-asynchronous-unwind-tables -fno-unwind-tables -mbranch-protection=pac-ret -Wa,-march=armv8.5-a -DARM64_ASM_ARCH='"armv8.5-a"' -DKASAN_SHADOW_SCALE_SHIFT= -fno-delete-null-pointer-checks -O2 -fno-allow-store-data-races -fstack-protector-strong -fno-omit-frame-pointer -fno-optimize-sibling-calls -fno-stack-clash-protection -falign-functions=4 -fstrict-flex-arrays=3 -fno-strict-overflow -fno-stack-check -fconserve-stack -fno-builtin-wcslen -Wall -Wextra -Wundef -Werror=implicit-function-declaration -Werror=implicit-int -Werror=return-type -Werror=strict-prototypes -Wno-format-security -Wno-trigraphs -Wno-frame-address -Wno-address-of-packed-member -Wmissing-declarations -Wmissing-prototypes -Wframe-larger-than=2048 -Wno-main -Wno-type-limits -Wno-dangling-pointer -Wvla-larger-than=1 -Wno-pointer-sign -Wcast-function-type -Wno-array-bounds -Wno-stringop-overflow -Wno-alloc-size-larger-than -Wimplicit-fallthrough=5 -Werror=date-time -Werror=incompatible-pointer-types -Werror=designated-init -Wenum-conversion -Wunused -Wno-unused-but-set-variable -Wno-unused-const-variable -Wno-packed-not-aligned -Wno-format-overflow -Wno-format-truncation -Wno-stringop-truncation -Wno-override-init -Wno-missing-field-initializers -Wno-shift-negative-value -Wno-maybe-uninitialized -Wno-sign-compare -Wno-unused-parameter -mstack-protector-guard=sysreg -mstack-protector-guard-reg=sp_el0 -mstack-protector-guard-offset=1344  -DMODULE  -DKBUILD_BASENAME='"meson_vdec.mod"' -DKBUILD_MODNAME='"meson_vdec"' -D__KBUILD_MODNAME=meson_vdec -c -o meson-vdec.mod.o meson-vdec.mod.c  

source_meson-vdec.mod.o := meson-vdec.mod.c

deps_meson-vdec.mod.o := \
    $(wildcard include/config/MODULE_UNLOAD) \
  /x96-build/7.2.12-trim/include/linux/compiler-version.h \
    $(wildcard include/config/CC_VERSION_TEXT) \
  /x96-build/7.2.12-trim/include/linux/kconfig.h \
    $(wildcard include/config/CPU_BIG_ENDIAN) \
    $(wildcard include/config/BOOGER) \
    $(wildcard include/config/FOO) \
  /x96-build/7.2.12-trim/include/linux/compiler_types.h \
    $(wildcard include/config/DEBUG_INFO_BTF) \
    $(wildcard include/config/PAHOLE_HAS_BTF_TAG) \
    $(wildcard include/config/FUNCTION_ALIGNMENT) \
    $(wildcard include/config/CC_HAS_SANE_FUNCTION_ALIGNMENT) \
    $(wildcard include/config/X86_64) \
    $(wildcard include/config/ARM64) \
    $(wildcard include/config/LD_DEAD_CODE_DATA_ELIMINATION) \
    $(wildcard include/config/LTO_CLANG) \
    $(wildcard include/config/HAVE_ARCH_COMPILER_H) \
    $(wildcard include/config/KCSAN) \
    $(wildcard include/config/CC_HAS_ASSUME) \
    $(wildcard include/config/CC_HAS_COUNTED_BY) \
    $(wildcard include/config/FORTIFY_SOURCE) \
    $(wildcard include/config/UBSAN_BOUNDS) \
    $(wildcard include/config/CC_HAS_COUNTED_BY_PTR) \
    $(wildcard include/config/CC_HAS_MULTIDIMENSIONAL_NONSTRING) \
    $(wildcard include/config/CFI) \
    $(wildcard include/config/ARCH_USES_CFI_GENERIC_LLVM_PASS) \
    $(wildcard include/config/CC_HAS_BROKEN_COUNTED_BY_REF) \
    $(wildcard include/config/CC_HAS_ASM_INLINE) \
  /x96-build/7.2.12-trim/include/linux/compiler-context-analysis.h \
  /x96-build/7.2.12-trim/include/linux/compiler_attributes.h \
  /x96-build/7.2.12-trim/include/linux/compiler-gcc.h \
    $(wildcard include/config/ARCH_USE_BUILTIN_BSWAP) \
    $(wildcard include/config/SHADOW_CALL_STACK) \
    $(wildcard include/config/KCOV) \
    $(wildcard include/config/CC_HAS_TYPEOF_UNQUAL) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/compiler.h \
    $(wildcard include/config/ARM64_PTR_AUTH_KERNEL) \
    $(wildcard include/config/ARM64_PTR_AUTH) \
    $(wildcard include/config/BUILTIN_RETURN_ADDRESS_STRIPS_PAC) \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/percpu_types.h \
  /x96-build/7.2.12-trim/include/asm-generic/percpu_types.h \
  /x96-build/7.2.12-trim/include/linux/module.h \
    $(wildcard include/config/MODULES) \
    $(wildcard include/config/SYSFS) \
    $(wildcard include/config/MODULES_TREE_LOOKUP) \
    $(wildcard include/config/LIVEPATCH) \
    $(wildcard include/config/STACKTRACE_BUILD_ID) \
    $(wildcard include/config/ARCH_USES_CFI_TRAPS) \
    $(wildcard include/config/MODULE_SIG) \
    $(wildcard include/config/GENERIC_BUG) \
    $(wildcard include/config/KALLSYMS) \
    $(wildcard include/config/SMP) \
    $(wildcard include/config/TRACEPOINTS) \
    $(wildcard include/config/TREE_SRCU) \
    $(wildcard include/config/BPF_EVENTS) \
    $(wildcard include/config/DEBUG_INFO_BTF_MODULES) \
    $(wildcard include/config/JUMP_LABEL) \
    $(wildcard include/config/TRACING) \
    $(wildcard include/config/EVENT_TRACING) \
    $(wildcard include/config/DYNAMIC_FTRACE) \
    $(wildcard include/config/KPROBES) \
    $(wildcard include/config/HAVE_STATIC_CALL_INLINE) \
    $(wildcard include/config/KUNIT) \
    $(wildcard include/config/PRINTK_INDEX) \
    $(wildcard include/config/CONSTRUCTORS) \
    $(wildcard include/config/FUNCTION_ERROR_INJECTION) \
    $(wildcard include/config/DYNAMIC_DEBUG_CORE) \
    $(wildcard include/config/MITIGATION_RETPOLINE) \
  /x96-build/7.2.12-trim/include/linux/list.h \
    $(wildcard include/config/LIST_HARDENED) \
    $(wildcard include/config/DEBUG_LIST) \
  /x96-build/7.2.12-trim/include/linux/container_of.h \
  /x96-build/7.2.12-trim/include/linux/build_bug.h \
  /x96-build/7.2.12-trim/include/linux/compiler.h \
    $(wildcard include/config/TRACE_BRANCH_PROFILING) \
    $(wildcard include/config/PROFILE_ALL_BRANCHES) \
    $(wildcard include/config/OBJTOOL) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/rwonce.h \
    $(wildcard include/config/LTO) \
  /x96-build/7.2.12-trim/include/asm-generic/rwonce.h \
  /x96-build/7.2.12-trim/include/linux/kasan-checks.h \
    $(wildcard include/config/KASAN_GENERIC) \
    $(wildcard include/config/KASAN_SW_TAGS) \
  /x96-build/7.2.12-trim/include/linux/types.h \
    $(wildcard include/config/HAVE_UID16) \
    $(wildcard include/config/UID16) \
    $(wildcard include/config/ARCH_DMA_ADDR_T_64BIT) \
    $(wildcard include/config/PHYS_ADDR_T_64BIT) \
    $(wildcard include/config/64BIT) \
    $(wildcard include/config/ARCH_32BIT_USTAT_F_TINODE) \
  /x96-build/7.2.12-trim/include/uapi/linux/types.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/uapi/asm/types.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/types.h \
  /x96-build/7.2.12-trim/include/asm-generic/int-ll64.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/int-ll64.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/bitsperlong.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitsperlong.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/bitsperlong.h \
  /x96-build/7.2.12-trim/include/uapi/linux/posix_types.h \
  /x96-build/7.2.12-trim/include/linux/stddef.h \
  /x96-build/7.2.12-trim/include/uapi/linux/stddef.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/posix_types.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/posix_types.h \
  /x96-build/7.2.12-trim/include/linux/kcsan-checks.h \
    $(wildcard include/config/KCSAN_WEAK_MEMORY) \
    $(wildcard include/config/KCSAN_IGNORE_ATOMICS) \
  /x96-build/7.2.12-trim/include/linux/poison.h \
    $(wildcard include/config/ILLEGAL_POINTER_VALUE) \
  /x96-build/7.2.12-trim/include/linux/const.h \
  /x96-build/7.2.12-trim/include/vdso/const.h \
  /x96-build/7.2.12-trim/include/uapi/linux/const.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/barrier.h \
    $(wildcard include/config/ARM64_PSEUDO_NMI) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/alternative-macros.h \
  /x96-build/7.2.12-trim/include/vdso/bits.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/cpucaps.h \
    $(wildcard include/config/ARM64_EPAN) \
    $(wildcard include/config/ARM64_SVE) \
    $(wildcard include/config/ARM64_SME) \
    $(wildcard include/config/ARM64_CNP) \
    $(wildcard include/config/ARM64_MTE) \
    $(wildcard include/config/ARM64_BTI) \
    $(wildcard include/config/ARM64_TLB_RANGE) \
    $(wildcard include/config/ARM64_POE) \
    $(wildcard include/config/ARM64_GCS) \
    $(wildcard include/config/ARM64_HAFT) \
    $(wildcard include/config/UNMAP_KERNEL_AT_EL0) \
    $(wildcard include/config/ARM64_ERRATUM_843419) \
    $(wildcard include/config/ARM64_ERRATUM_1742098) \
    $(wildcard include/config/ARM64_ERRATUM_2645198) \
    $(wildcard include/config/ARM64_ERRATUM_2658417) \
    $(wildcard include/config/CAVIUM_ERRATUM_23154) \
    $(wildcard include/config/ARM64_WORKAROUND_DISABLE_CNP) \
    $(wildcard include/config/ARM64_WORKAROUND_REPEAT_TLBI) \
    $(wildcard include/config/ARM64_ERRATUM_3194386) \
    $(wildcard include/config/ARM64_ERRATUM_4193714) \
    $(wildcard include/config/HW_PERF_EVENTS) \
    $(wildcard include/config/ARM64_LSUI) \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/cpucap-defs.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/insn-def.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/brk-imm.h \
  /x96-build/7.2.12-trim/include/linux/stringify.h \
  /x96-build/7.2.12-trim/include/asm-generic/barrier.h \
  /x96-build/7.2.12-trim/include/linux/stat.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/stat.h \
    $(wildcard include/config/COMPAT) \
  /x96-build/kbuild-trim/arch/arm64/include/generated/uapi/asm/stat.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/stat.h \
  /x96-build/7.2.12-trim/include/linux/time.h \
    $(wildcard include/config/POSIX_TIMERS) \
  /x96-build/7.2.12-trim/include/linux/cache.h \
    $(wildcard include/config/ARCH_HAS_CACHE_LINE_SIZE) \
  /x96-build/7.2.12-trim/include/uapi/linux/kernel.h \
  /x96-build/7.2.12-trim/include/uapi/linux/sysinfo.h \
  /x96-build/7.2.12-trim/include/vdso/cache.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/cache.h \
    $(wildcard include/config/KASAN_HW_TAGS) \
  /x96-build/7.2.12-trim/include/linux/bitops.h \
  /x96-build/7.2.12-trim/include/linux/bits.h \
  /x96-build/7.2.12-trim/include/uapi/linux/bits.h \
  /x96-build/7.2.12-trim/include/linux/overflow.h \
  /x96-build/7.2.12-trim/include/linux/limits.h \
  /x96-build/7.2.12-trim/include/uapi/linux/limits.h \
  /x96-build/7.2.12-trim/include/vdso/limits.h \
  /x96-build/7.2.12-trim/include/linux/typecheck.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/generic-non-atomic.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/bitops.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/builtin-__ffs.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/builtin-ffs.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/builtin-__fls.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/builtin-fls.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/ffz.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/fls64.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/sched.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/hweight.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/arch_hweight.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/const_hweight.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/atomic.h \
  /x96-build/7.2.12-trim/include/linux/atomic.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/atomic.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/cmpxchg.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/lse.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/atomic_ll_sc.h \
    $(wildcard include/config/CC_HAS_K_CONSTRAINT) \
  /x96-build/7.2.12-trim/include/linux/export.h \
    $(wildcard include/config/MODVERSIONS) \
    $(wildcard include/config/GENDWARFKSYMS) \
  /x96-build/7.2.12-trim/include/linux/linkage.h \
    $(wildcard include/config/ARCH_USE_SYM_ANNOTATIONS) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/linkage.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/alternative.h \
  /x96-build/7.2.12-trim/include/linux/init.h \
    $(wildcard include/config/MEMORY_HOTPLUG) \
    $(wildcard include/config/HAVE_ARCH_PREL32_RELOCATIONS) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/atomic_lse.h \
  /x96-build/7.2.12-trim/include/linux/atomic/atomic-arch-fallback.h \
    $(wildcard include/config/GENERIC_ATOMIC64) \
  /x96-build/7.2.12-trim/include/linux/atomic/atomic-long.h \
  /x96-build/7.2.12-trim/include/linux/atomic/atomic-instrumented.h \
  /x96-build/7.2.12-trim/include/linux/instrumented.h \
    $(wildcard include/config/DEBUG_ATOMIC) \
    $(wildcard include/config/DEBUG_ATOMIC_LARGEST_ALIGN) \
  /x96-build/7.2.12-trim/include/linux/bug.h \
    $(wildcard include/config/PRINTK) \
    $(wildcard include/config/BUG_ON_DATA_CORRUPTION) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/bug.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/asm-bug.h \
    $(wildcard include/config/DEBUG_BUGVERBOSE) \
  /x96-build/7.2.12-trim/include/asm-generic/bug.h \
    $(wildcard include/config/DEBUG_BUGVERBOSE_DETAILED) \
    $(wildcard include/config/BUG) \
    $(wildcard include/config/GENERIC_BUG_RELATIVE_POINTERS) \
  /x96-build/7.2.12-trim/include/linux/instrumentation.h \
    $(wildcard include/config/NOINSTR_VALIDATION) \
  /x96-build/7.2.12-trim/include/linux/once_lite.h \
  /x96-build/7.2.12-trim/include/linux/panic.h \
    $(wildcard include/config/PANIC_TIMEOUT) \
  /x96-build/7.2.12-trim/include/linux/stdarg.h \
  /x96-build/7.2.12-trim/include/linux/printk.h \
    $(wildcard include/config/MESSAGE_LOGLEVEL_DEFAULT) \
    $(wildcard include/config/CONSOLE_LOGLEVEL_DEFAULT) \
    $(wildcard include/config/CONSOLE_LOGLEVEL_QUIET) \
    $(wildcard include/config/EARLY_PRINTK) \
    $(wildcard include/config/DYNAMIC_DEBUG) \
  /x96-build/7.2.12-trim/include/linux/kern_levels.h \
  /x96-build/7.2.12-trim/include/linux/ratelimit_types.h \
  /x96-build/7.2.12-trim/include/uapi/linux/param.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/param.h \
  /x96-build/7.2.12-trim/include/asm-generic/param.h \
    $(wildcard include/config/HZ) \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/param.h \
  /x96-build/7.2.12-trim/include/linux/spinlock_types_raw.h \
    $(wildcard include/config/DEBUG_SPINLOCK) \
    $(wildcard include/config/DEBUG_LOCK_ALLOC) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/spinlock_types.h \
  /x96-build/7.2.12-trim/include/asm-generic/qspinlock_types.h \
    $(wildcard include/config/NR_CPUS) \
  /x96-build/7.2.12-trim/include/asm-generic/qrwlock_types.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/byteorder.h \
  /x96-build/7.2.12-trim/include/linux/byteorder/little_endian.h \
  /x96-build/7.2.12-trim/include/uapi/linux/byteorder/little_endian.h \
  /x96-build/7.2.12-trim/include/linux/swab.h \
  /x96-build/7.2.12-trim/include/uapi/linux/swab.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/uapi/asm/swab.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/swab.h \
  /x96-build/7.2.12-trim/include/linux/byteorder/generic.h \
  /x96-build/7.2.12-trim/include/linux/lockdep_types.h \
    $(wildcard include/config/PROVE_RAW_LOCK_NESTING) \
    $(wildcard include/config/LOCKDEP) \
    $(wildcard include/config/LOCK_STAT) \
  /x96-build/7.2.12-trim/include/linux/dynamic_debug.h \
  /x96-build/7.2.12-trim/include/linux/jump_label.h \
    $(wildcard include/config/HAVE_ARCH_JUMP_LABEL_RELATIVE) \
  /x96-build/7.2.12-trim/include/linux/cleanup.h \
  /x96-build/7.2.12-trim/include/linux/err.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/uapi/asm/errno.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/errno.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/errno-base.h \
  /x96-build/7.2.12-trim/include/linux/args.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/jump_label.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/insn.h \
  /x96-build/7.2.12-trim/include/linux/kmsan-checks.h \
    $(wildcard include/config/KMSAN) \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/instrumented-atomic.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/lock.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/instrumented-lock.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/non-atomic.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/non-instrumented-non-atomic.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/le.h \
  /x96-build/7.2.12-trim/include/asm-generic/bitops/ext2-atomic-setbit.h \
  /x96-build/7.2.12-trim/include/linux/kasan-enabled.h \
    $(wildcard include/config/ARCH_DEFER_KASAN) \
    $(wildcard include/config/KASAN) \
  /x96-build/7.2.12-trim/include/linux/static_key.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/cputype.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/sysreg.h \
    $(wildcard include/config/BROKEN_GAS_INST) \
    $(wildcard include/config/ARM64_PA_BITS_52) \
    $(wildcard include/config/ARM64_4K_PAGES) \
    $(wildcard include/config/ARM64_16K_PAGES) \
    $(wildcard include/config/ARM64_64K_PAGES) \
    $(wildcard include/config/AMPERE_ERRATUM_AC04_CPU_23) \
  /x96-build/7.2.12-trim/include/linux/kasan-tags.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/gpr-num.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/sysreg-defs.h \
  /x96-build/7.2.12-trim/include/linux/bitfield.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/mte-def.h \
  /x96-build/7.2.12-trim/include/linux/math64.h \
    $(wildcard include/config/ARCH_SUPPORTS_INT128) \
  /x96-build/7.2.12-trim/include/linux/math.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/div64.h \
  /x96-build/7.2.12-trim/include/asm-generic/div64.h \
    $(wildcard include/config/CC_OPTIMIZE_FOR_PERFORMANCE) \
  /x96-build/7.2.12-trim/include/vdso/math64.h \
  /x96-build/7.2.12-trim/include/linux/time64.h \
  /x96-build/7.2.12-trim/include/vdso/time64.h \
  /x96-build/7.2.12-trim/include/uapi/linux/time.h \
  /x96-build/7.2.12-trim/include/uapi/linux/time_types.h \
  /x96-build/7.2.12-trim/include/linux/time32.h \
  /x96-build/7.2.12-trim/include/linux/timex.h \
  /x96-build/7.2.12-trim/include/uapi/linux/timex.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/timex.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/arch_timer.h \
    $(wildcard include/config/ARM_ARCH_TIMER_OOL_WORKAROUND) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/hwcap.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/hwcap.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/cpufeature.h \
    $(wildcard include/config/ARM64_SW_TTBR0_PAN) \
    $(wildcard include/config/ARM64_DEBUG_PRIORITY_MASKING) \
    $(wildcard include/config/ARM64_BTI_KERNEL) \
    $(wildcard include/config/ARM64_PA_BITS) \
    $(wildcard include/config/ARM64_HW_AFDBM) \
    $(wildcard include/config/ARM64_AMU_EXTN) \
    $(wildcard include/config/ARM64_LPA2) \
  /x96-build/7.2.12-trim/include/linux/kernel.h \
    $(wildcard include/config/PREEMPT_VOLUNTARY_BUILD) \
    $(wildcard include/config/PREEMPT_DYNAMIC) \
    $(wildcard include/config/HAVE_PREEMPT_DYNAMIC_CALL) \
    $(wildcard include/config/HAVE_PREEMPT_DYNAMIC_KEY) \
    $(wildcard include/config/PREEMPT_) \
    $(wildcard include/config/DEBUG_ATOMIC_SLEEP) \
    $(wildcard include/config/MMU) \
    $(wildcard include/config/PROVE_LOCKING) \
  /x96-build/7.2.12-trim/include/linux/align.h \
  /x96-build/7.2.12-trim/include/vdso/align.h \
  /x96-build/7.2.12-trim/include/linux/array_size.h \
  /x96-build/7.2.12-trim/include/linux/kstrtox.h \
  /x96-build/7.2.12-trim/include/linux/log2.h \
    $(wildcard include/config/ARCH_HAS_ILOG2_U32) \
    $(wildcard include/config/ARCH_HAS_ILOG2_U64) \
  /x96-build/7.2.12-trim/include/linux/minmax.h \
  /x96-build/7.2.12-trim/include/linux/sprintf.h \
  /x96-build/7.2.12-trim/include/linux/static_call_types.h \
    $(wildcard include/config/HAVE_STATIC_CALL) \
  /x96-build/7.2.12-trim/include/linux/trace_printk.h \
  /x96-build/7.2.12-trim/include/linux/instruction_pointer.h \
  /x96-build/7.2.12-trim/include/linux/util_macros.h \
    $(wildcard include/config/FOO_SUSPEND) \
  /x96-build/7.2.12-trim/include/linux/wordpart.h \
  /x96-build/7.2.12-trim/include/linux/cpumask.h \
    $(wildcard include/config/FORCE_NR_CPUS) \
    $(wildcard include/config/HOTPLUG_CPU) \
    $(wildcard include/config/DEBUG_PER_CPU_MAPS) \
    $(wildcard include/config/CPUMASK_OFFSTACK) \
  /x96-build/7.2.12-trim/include/linux/bitmap.h \
  /x96-build/7.2.12-trim/include/linux/errno.h \
  /x96-build/7.2.12-trim/include/uapi/linux/errno.h \
  /x96-build/7.2.12-trim/include/linux/find.h \
  /x96-build/7.2.12-trim/include/linux/string.h \
    $(wildcard include/config/BINARY_PRINTF) \
  /x96-build/7.2.12-trim/include/uapi/linux/string.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/string.h \
    $(wildcard include/config/ARCH_HAS_UACCESS_FLUSHCACHE) \
  /x96-build/7.2.12-trim/include/linux/bitmap-str.h \
  /x96-build/7.2.12-trim/include/linux/cpumask_types.h \
  /x96-build/7.2.12-trim/include/linux/threads.h \
    $(wildcard include/config/BASE_SMALL) \
  /x96-build/7.2.12-trim/include/linux/gfp_types.h \
  /x96-build/7.2.12-trim/include/linux/numa.h \
    $(wildcard include/config/NUMA_KEEP_MEMINFO) \
    $(wildcard include/config/NUMA) \
    $(wildcard include/config/HAVE_ARCH_NODE_DEV_GROUP) \
  /x96-build/7.2.12-trim/include/linux/nodemask.h \
    $(wildcard include/config/HIGHMEM) \
  /x96-build/7.2.12-trim/include/linux/nodemask_types.h \
    $(wildcard include/config/NODES_SHIFT) \
  /x96-build/7.2.12-trim/include/linux/random.h \
    $(wildcard include/config/VMGENID) \
  /x96-build/7.2.12-trim/include/uapi/linux/random.h \
  /x96-build/7.2.12-trim/include/uapi/linux/ioctl.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/uapi/asm/ioctl.h \
  /x96-build/7.2.12-trim/include/asm-generic/ioctl.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/ioctl.h \
  /x96-build/7.2.12-trim/include/linux/irqnr.h \
  /x96-build/7.2.12-trim/include/uapi/linux/irqnr.h \
  /x96-build/7.2.12-trim/include/vdso/page.h \
    $(wildcard include/config/PAGE_SHIFT) \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/kernel-hwcap.h \
  /x96-build/7.2.12-trim/include/linux/percpu.h \
    $(wildcard include/config/KMALLOC_PARTITION_CACHES) \
    $(wildcard include/config/PAGE_SIZE_4KB) \
    $(wildcard include/config/NEED_PER_CPU_PAGE_FIRST_CHUNK) \
    $(wildcard include/config/HAVE_SETUP_PER_CPU_AREA) \
  /x96-build/7.2.12-trim/include/linux/alloc_tag.h \
    $(wildcard include/config/MEM_ALLOC_PROFILING_DEBUG) \
    $(wildcard include/config/MEM_ALLOC_PROFILING) \
    $(wildcard include/config/ARCH_MODULE_NEEDS_WEAK_PER_CPU) \
    $(wildcard include/config/MEM_ALLOC_PROFILING_ENABLED_BY_DEFAULT) \
  /x96-build/7.2.12-trim/include/linux/codetag.h \
    $(wildcard include/config/CODE_TAGGING) \
  /x96-build/7.2.12-trim/include/linux/preempt.h \
    $(wildcard include/config/PREEMPT_RT) \
    $(wildcard include/config/PREEMPT_COUNT) \
    $(wildcard include/config/DEBUG_PREEMPT) \
    $(wildcard include/config/TRACE_PREEMPT_TOGGLE) \
    $(wildcard include/config/PREEMPTION) \
    $(wildcard include/config/PREEMPT_NOTIFIERS) \
    $(wildcard include/config/PREEMPT_NONE) \
    $(wildcard include/config/PREEMPT_VOLUNTARY) \
    $(wildcard include/config/PREEMPT) \
    $(wildcard include/config/PREEMPT_LAZY) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/preempt.h \
  /x96-build/7.2.12-trim/include/linux/thread_info.h \
    $(wildcard include/config/THREAD_INFO_IN_TASK) \
    $(wildcard include/config/GENERIC_ENTRY) \
    $(wildcard include/config/ARCH_HAS_PREEMPT_LAZY) \
    $(wildcard include/config/HAVE_ARCH_WITHIN_STACK_FRAMES) \
    $(wildcard include/config/SH) \
  /x96-build/7.2.12-trim/include/linux/restart_block.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/current.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/thread_info.h \
    $(wildcard include/config/ARM64_MPAM) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/memory.h \
    $(wildcard include/config/ARM64_VA_BITS) \
    $(wildcard include/config/KASAN_SHADOW_OFFSET) \
    $(wildcard include/config/RANDOMIZE_BASE) \
    $(wildcard include/config/DEBUG_VIRTUAL) \
    $(wildcard include/config/EFI) \
    $(wildcard include/config/ARM_GIC_V3_ITS) \
  /x96-build/7.2.12-trim/include/linux/sizes.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/page-def.h \
  /x96-build/7.2.12-trim/include/linux/mmdebug.h \
    $(wildcard include/config/DEBUG_VM) \
    $(wildcard include/config/DEBUG_VM_IRQSOFF) \
    $(wildcard include/config/DEBUG_VM_PGFLAGS) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/boot.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/sections.h \
  /x96-build/7.2.12-trim/include/asm-generic/sections.h \
    $(wildcard include/config/HAVE_FUNCTION_DESCRIPTORS) \
  /x96-build/7.2.12-trim/include/asm-generic/memory_model.h \
    $(wildcard include/config/FLATMEM) \
    $(wildcard include/config/SPARSEMEM_VMEMMAP) \
    $(wildcard include/config/SPARSEMEM) \
  /x96-build/7.2.12-trim/include/linux/pfn.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/stack_pointer.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/percpu.h \
  /x96-build/7.2.12-trim/include/asm-generic/percpu.h \
  /x96-build/7.2.12-trim/include/linux/percpu-defs.h \
    $(wildcard include/config/DEBUG_FORCE_WEAK_PER_CPU) \
    $(wildcard include/config/AMD_MEM_ENCRYPT) \
  /x96-build/7.2.12-trim/include/linux/smp.h \
    $(wildcard include/config/UP_LATE_INIT) \
    $(wildcard include/config/CSD_LOCK_WAIT_DEBUG) \
  /x96-build/7.2.12-trim/include/linux/smp_types.h \
  /x96-build/7.2.12-trim/include/linux/llist.h \
    $(wildcard include/config/ARCH_HAVE_NMI_SAFE_CMPXCHG) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/smp.h \
    $(wildcard include/config/ARM64_ACPI_PARKING_PROTOCOL) \
  /x96-build/7.2.12-trim/include/linux/irqflags.h \
    $(wildcard include/config/TRACE_IRQFLAGS) \
    $(wildcard include/config/IRQSOFF_TRACER) \
    $(wildcard include/config/PREEMPT_TRACER) \
    $(wildcard include/config/DEBUG_IRQFLAGS) \
    $(wildcard include/config/TRACE_IRQFLAGS_SUPPORT) \
  /x96-build/7.2.12-trim/include/linux/irqflags_types.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/irqflags.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/ptrace.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/ptrace.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/sve_context.h \
  /x96-build/7.2.12-trim/include/linux/irqchip/arm-gic-v3-prio.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/stacktrace/frame.h \
  /x96-build/7.2.12-trim/include/linux/sched.h \
    $(wildcard include/config/VIRT_CPU_ACCOUNTING_NATIVE) \
    $(wildcard include/config/SCHED_INFO) \
    $(wildcard include/config/SCHEDSTATS) \
    $(wildcard include/config/SCHED_CORE) \
    $(wildcard include/config/FAIR_GROUP_SCHED) \
    $(wildcard include/config/RT_GROUP_SCHED) \
    $(wildcard include/config/RT_MUTEXES) \
    $(wildcard include/config/UCLAMP_TASK) \
    $(wildcard include/config/UCLAMP_BUCKETS_COUNT) \
    $(wildcard include/config/KMAP_LOCAL) \
    $(wildcard include/config/SCHED_CLASS_EXT) \
    $(wildcard include/config/CGROUP_SCHED) \
    $(wildcard include/config/CFS_BANDWIDTH) \
    $(wildcard include/config/BLK_DEV_IO_TRACE) \
    $(wildcard include/config/PREEMPT_RCU) \
    $(wildcard include/config/TASKS_RCU) \
    $(wildcard include/config/TASKS_TRACE_RCU) \
    $(wildcard include/config/TRIVIAL_PREEMPT_RCU) \
    $(wildcard include/config/MEMCG_V1) \
    $(wildcard include/config/LRU_GEN) \
    $(wildcard include/config/COMPAT_BRK) \
    $(wildcard include/config/CGROUPS) \
    $(wildcard include/config/BLK_CGROUP) \
    $(wildcard include/config/PSI) \
    $(wildcard include/config/PAGE_OWNER) \
    $(wildcard include/config/EVENTFD) \
    $(wildcard include/config/ARCH_HAS_CPU_PASID) \
    $(wildcard include/config/X86_BUS_LOCK_DETECT) \
    $(wildcard include/config/TASK_DELAY_ACCT) \
    $(wildcard include/config/STACKPROTECTOR) \
    $(wildcard include/config/ARCH_HAS_SCALED_CPUTIME) \
    $(wildcard include/config/VIRT_CPU_ACCOUNTING_GEN) \
    $(wildcard include/config/NO_HZ_FULL) \
    $(wildcard include/config/POSIX_CPUTIMERS) \
    $(wildcard include/config/POSIX_CPU_TIMERS_TASK_WORK) \
    $(wildcard include/config/KEYS) \
    $(wildcard include/config/SYSVIPC) \
    $(wildcard include/config/DETECT_HUNG_TASK) \
    $(wildcard include/config/IO_URING) \
    $(wildcard include/config/AUDIT) \
    $(wildcard include/config/AUDITSYSCALL) \
    $(wildcard include/config/DETECT_HUNG_TASK_BLOCKER) \
    $(wildcard include/config/UBSAN) \
    $(wildcard include/config/UBSAN_TRAP) \
    $(wildcard include/config/COMPACTION) \
    $(wildcard include/config/TASK_XACCT) \
    $(wildcard include/config/CPUSETS) \
    $(wildcard include/config/X86_CPU_RESCTRL) \
    $(wildcard include/config/PERF_EVENTS) \
    $(wildcard include/config/NUMA_BALANCING) \
    $(wildcard include/config/SCHED_CACHE) \
    $(wildcard include/config/ARCH_HAS_LAZY_MMU_MODE) \
    $(wildcard include/config/FAULT_INJECTION) \
    $(wildcard include/config/LATENCYTOP) \
    $(wildcard include/config/FUNCTION_GRAPH_TRACER) \
    $(wildcard include/config/MEMCG) \
    $(wildcard include/config/UPROBES) \
    $(wildcard include/config/BCACHE) \
    $(wildcard include/config/VMAP_STACK) \
    $(wildcard include/config/SECURITY) \
    $(wildcard include/config/BPF_SYSCALL) \
    $(wildcard include/config/KSTACK_ERASE) \
    $(wildcard include/config/KSTACK_ERASE_METRICS) \
    $(wildcard include/config/X86_MCE) \
    $(wildcard include/config/KRETPROBES) \
    $(wildcard include/config/RETHOOK) \
    $(wildcard include/config/ARCH_HAS_PARANOID_L1D_FLUSH) \
    $(wildcard include/config/RV) \
    $(wildcard include/config/RV_PER_TASK_MONITORS) \
    $(wildcard include/config/USER_EVENTS) \
    $(wildcard include/config/UNWIND_USER) \
    $(wildcard include/config/SCHED_PROXY_EXEC) \
    $(wildcard include/config/SCHED_MM_CID) \
  /x96-build/7.2.12-trim/include/uapi/linux/sched.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/processor.h \
    $(wildcard include/config/KUSER_HELPERS) \
    $(wildcard include/config/ARM64_FORCE_52BIT) \
    $(wildcard include/config/HAVE_HW_BREAKPOINT) \
    $(wildcard include/config/ARM64_TAGGED_ADDR_ABI) \
  /x96-build/7.2.12-trim/include/vdso/processor.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/vdso/processor.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/hw_breakpoint.h \
    $(wildcard include/config/CPU_PM) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/virt.h \
    $(wildcard include/config/KVM) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/kasan.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/mte-kasan.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/pgtable-types.h \
    $(wildcard include/config/PGTABLE_LEVELS) \
  /x96-build/7.2.12-trim/include/asm-generic/pgtable-nop4d.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/pgtable-hwdef.h \
    $(wildcard include/config/ARM64_CONT_PTE_SHIFT) \
    $(wildcard include/config/ARM64_CONT_PMD_SHIFT) \
    $(wildcard include/config/ARM64_VA_BITS_52) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/pointer_auth.h \
  /x96-build/7.2.12-trim/include/uapi/linux/prctl.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/spectre.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/fpsimd.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/sigcontext.h \
  /x96-build/7.2.12-trim/include/linux/futex_types.h \
    $(wildcard include/config/FUTEX) \
    $(wildcard include/config/FUTEX_PRIVATE_HASH) \
    $(wildcard include/config/FUTEX_ROBUST_UNLOCK) \
  /x96-build/7.2.12-trim/include/linux/mutex_types.h \
    $(wildcard include/config/MUTEX_SPIN_ON_OWNER) \
    $(wildcard include/config/DEBUG_MUTEXES) \
  /x96-build/7.2.12-trim/include/linux/osq_lock.h \
  /x96-build/7.2.12-trim/include/linux/spinlock_types.h \
  /x96-build/7.2.12-trim/include/linux/rwlock_types.h \
  /x96-build/7.2.12-trim/include/linux/pid_types.h \
  /x96-build/7.2.12-trim/include/linux/sem_types.h \
  /x96-build/7.2.12-trim/include/linux/shm.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/page.h \
  /x96-build/7.2.12-trim/include/linux/personality.h \
  /x96-build/7.2.12-trim/include/uapi/linux/personality.h \
  /x96-build/7.2.12-trim/include/asm-generic/getorder.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/shmparam.h \
  /x96-build/7.2.12-trim/include/asm-generic/shmparam.h \
  /x96-build/7.2.12-trim/include/linux/kmsan_types.h \
  /x96-build/7.2.12-trim/include/linux/plist_types.h \
  /x96-build/7.2.12-trim/include/linux/hrtimer_types.h \
  /x96-build/7.2.12-trim/include/linux/timerqueue_types.h \
  /x96-build/7.2.12-trim/include/linux/rbtree_types.h \
  /x96-build/7.2.12-trim/include/linux/timer_types.h \
  /x96-build/7.2.12-trim/include/linux/seccomp_types.h \
    $(wildcard include/config/SECCOMP) \
  /x96-build/7.2.12-trim/include/linux/refcount_types.h \
  /x96-build/7.2.12-trim/include/linux/resource.h \
  /x96-build/7.2.12-trim/include/uapi/linux/resource.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/uapi/asm/resource.h \
  /x96-build/7.2.12-trim/include/asm-generic/resource.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/resource.h \
  /x96-build/7.2.12-trim/include/linux/latencytop.h \
  /x96-build/7.2.12-trim/include/linux/sched/prio.h \
  /x96-build/7.2.12-trim/include/linux/sched/types.h \
  /x96-build/7.2.12-trim/include/linux/signal_types.h \
    $(wildcard include/config/OLD_SIGACTION) \
  /x96-build/7.2.12-trim/include/uapi/linux/signal.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/signal.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/signal.h \
  /x96-build/7.2.12-trim/include/asm-generic/signal.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/signal.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/signal-defs.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/uapi/asm/siginfo.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/siginfo.h \
  /x96-build/7.2.12-trim/include/linux/spinlock.h \
  /x96-build/7.2.12-trim/include/linux/bottom_half.h \
  /x96-build/7.2.12-trim/include/linux/lockdep.h \
    $(wildcard include/config/DEBUG_LOCKING_API_SELFTESTS) \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/mmiowb.h \
  /x96-build/7.2.12-trim/include/asm-generic/mmiowb.h \
    $(wildcard include/config/MMIOWB) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/spinlock.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/qspinlock.h \
  /x96-build/7.2.12-trim/include/asm-generic/qspinlock.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/qrwlock.h \
  /x96-build/7.2.12-trim/include/asm-generic/qrwlock.h \
  /x96-build/7.2.12-trim/include/linux/rwlock.h \
  /x96-build/7.2.12-trim/include/linux/spinlock_api_smp.h \
    $(wildcard include/config/INLINE_SPIN_LOCK) \
    $(wildcard include/config/INLINE_SPIN_LOCK_BH) \
    $(wildcard include/config/INLINE_SPIN_LOCK_IRQ) \
    $(wildcard include/config/INLINE_SPIN_LOCK_IRQSAVE) \
    $(wildcard include/config/INLINE_SPIN_TRYLOCK) \
    $(wildcard include/config/INLINE_SPIN_TRYLOCK_BH) \
    $(wildcard include/config/UNINLINE_SPIN_UNLOCK) \
    $(wildcard include/config/INLINE_SPIN_UNLOCK_BH) \
    $(wildcard include/config/INLINE_SPIN_UNLOCK_IRQ) \
    $(wildcard include/config/INLINE_SPIN_UNLOCK_IRQRESTORE) \
    $(wildcard include/config/GENERIC_LOCKBREAK) \
  /x96-build/7.2.12-trim/include/linux/rwlock_api_smp.h \
    $(wildcard include/config/INLINE_READ_LOCK) \
    $(wildcard include/config/INLINE_WRITE_LOCK) \
    $(wildcard include/config/INLINE_READ_LOCK_BH) \
    $(wildcard include/config/INLINE_WRITE_LOCK_BH) \
    $(wildcard include/config/INLINE_READ_LOCK_IRQ) \
    $(wildcard include/config/INLINE_WRITE_LOCK_IRQ) \
    $(wildcard include/config/INLINE_READ_LOCK_IRQSAVE) \
    $(wildcard include/config/INLINE_WRITE_LOCK_IRQSAVE) \
    $(wildcard include/config/INLINE_READ_TRYLOCK) \
    $(wildcard include/config/INLINE_WRITE_TRYLOCK) \
    $(wildcard include/config/INLINE_READ_UNLOCK) \
    $(wildcard include/config/INLINE_WRITE_UNLOCK) \
    $(wildcard include/config/INLINE_READ_UNLOCK_BH) \
    $(wildcard include/config/INLINE_WRITE_UNLOCK_BH) \
    $(wildcard include/config/INLINE_READ_UNLOCK_IRQ) \
    $(wildcard include/config/INLINE_WRITE_UNLOCK_IRQ) \
    $(wildcard include/config/INLINE_READ_UNLOCK_IRQRESTORE) \
    $(wildcard include/config/INLINE_WRITE_UNLOCK_IRQRESTORE) \
  /x96-build/7.2.12-trim/include/linux/syscall_user_dispatch_types.h \
  /x96-build/7.2.12-trim/include/linux/mm_types_task.h \
    $(wildcard include/config/ARCH_WANT_BATCHED_UNMAP_TLB_FLUSH) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/tlbbatch.h \
  /x96-build/7.2.12-trim/include/linux/netdevice_xmit.h \
    $(wildcard include/config/NET_ACT_MIRRED) \
    $(wildcard include/config/NET_EGRESS) \
    $(wildcard include/config/NF_DUP_NETDEV) \
  /x96-build/7.2.12-trim/include/linux/task_io_accounting.h \
    $(wildcard include/config/TASK_IO_ACCOUNTING) \
  /x96-build/7.2.12-trim/include/linux/posix-timers_types.h \
  /x96-build/7.2.12-trim/include/linux/rseq_types.h \
    $(wildcard include/config/RSEQ) \
    $(wildcard include/config/RSEQ_SLICE_EXTENSION) \
  /x96-build/7.2.12-trim/include/linux/irq_work_types.h \
  /x96-build/7.2.12-trim/include/linux/workqueue_types.h \
  /x96-build/7.2.12-trim/include/linux/seqlock_types.h \
  /x96-build/7.2.12-trim/include/linux/kcsan.h \
  /x96-build/7.2.12-trim/include/linux/rv.h \
    $(wildcard include/config/RV_LTL_MONITOR) \
    $(wildcard include/config/RV_HA_MONITOR) \
    $(wildcard include/config/RV_REACTORS) \
  /x96-build/7.2.12-trim/include/linux/uidgid_types.h \
  /x96-build/7.2.12-trim/include/linux/tracepoint-defs.h \
  /x96-build/7.2.12-trim/include/linux/unwind_deferred_types.h \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/kmap_size.h \
  /x96-build/7.2.12-trim/include/asm-generic/kmap_size.h \
    $(wildcard include/config/DEBUG_KMAP_LOCAL) \
  /x96-build/kbuild-trim/include/generated/rq-offsets.h \
  /x96-build/7.2.12-trim/include/linux/sched/ext.h \
    $(wildcard include/config/EXT_GROUP_SCHED) \
  /x96-build/7.2.12-trim/include/clocksource/arm_arch_timer.h \
    $(wildcard include/config/ARM_ARCH_TIMER) \
  /x96-build/7.2.12-trim/include/linux/timecounter.h \
  /x96-build/7.2.12-trim/include/asm-generic/timex.h \
  /x96-build/7.2.12-trim/include/vdso/time32.h \
  /x96-build/7.2.12-trim/include/vdso/time.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/compat.h \
  /x96-build/7.2.12-trim/include/asm-generic/compat.h \
    $(wildcard include/config/COMPAT_FOR_U64_ALIGNMENT) \
  /x96-build/7.2.12-trim/include/linux/sched/task_stack.h \
    $(wildcard include/config/STACK_GROWSUP) \
    $(wildcard include/config/DEBUG_STACK_USAGE) \
  /x96-build/7.2.12-trim/include/uapi/linux/magic.h \
  /x96-build/7.2.12-trim/include/linux/refcount.h \
  /x96-build/7.2.12-trim/include/linux/kasan.h \
    $(wildcard include/config/KASAN_STACK) \
    $(wildcard include/config/KASAN_VMALLOC) \
  /x96-build/7.2.12-trim/include/uapi/linux/stat.h \
  /x96-build/7.2.12-trim/include/linux/uidgid.h \
    $(wildcard include/config/MULTIUSER) \
    $(wildcard include/config/USER_NS) \
  /x96-build/7.2.12-trim/include/linux/highuid.h \
  /x96-build/7.2.12-trim/include/linux/buildid.h \
    $(wildcard include/config/VMCORE_INFO) \
  /x96-build/7.2.12-trim/include/linux/kmod.h \
  /x96-build/7.2.12-trim/include/linux/umh.h \
  /x96-build/7.2.12-trim/include/linux/gfp.h \
    $(wildcard include/config/ZONE_DMA) \
    $(wildcard include/config/ZONE_DMA32) \
    $(wildcard include/config/ZONE_DEVICE) \
    $(wildcard include/config/CONTIG_ALLOC) \
  /x96-build/7.2.12-trim/include/linux/mmzone.h \
    $(wildcard include/config/ARCH_FORCE_MAX_ORDER) \
    $(wildcard include/config/PAGE_BLOCK_MAX_ORDER) \
    $(wildcard include/config/HAVE_GIGANTIC_FOLIOS) \
    $(wildcard include/config/HUGETLB_PAGE) \
    $(wildcard include/config/HUGETLB_PAGE_OPTIMIZE_VMEMMAP) \
    $(wildcard include/config/CMA) \
    $(wildcard include/config/MEMORY_ISOLATION) \
    $(wildcard include/config/ZSMALLOC) \
    $(wildcard include/config/UNACCEPTED_MEMORY) \
    $(wildcard include/config/IOMMU_SUPPORT) \
    $(wildcard include/config/SWAP) \
    $(wildcard include/config/TRANSPARENT_HUGEPAGE) \
    $(wildcard include/config/LRU_GEN_STATS) \
    $(wildcard include/config/LRU_GEN_WALKS_MMU) \
    $(wildcard include/config/MEMORY_FAILURE) \
    $(wildcard include/config/PAGE_EXTENSION) \
    $(wildcard include/config/DEFERRED_STRUCT_PAGE_INIT) \
    $(wildcard include/config/HAVE_MEMORYLESS_NODES) \
    $(wildcard include/config/SPARSEMEM_EXTREME) \
    $(wildcard include/config/SPARSEMEM_VMEMMAP_PREINIT) \
    $(wildcard include/config/HAVE_ARCH_PFN_VALID) \
  /x96-build/7.2.12-trim/include/linux/list_nulls.h \
  /x96-build/7.2.12-trim/include/linux/wait.h \
  /x96-build/7.2.12-trim/include/linux/seqlock.h \
    $(wildcard include/config/CC_IS_GCC) \
    $(wildcard include/config/GCC_VERSION) \
    $(wildcard include/config/UBSAN_ALIGNMENT) \
  /x96-build/7.2.12-trim/include/linux/mutex.h \
  /x96-build/7.2.12-trim/include/linux/debug_locks.h \
  /x96-build/7.2.12-trim/include/linux/pageblock-flags.h \
    $(wildcard include/config/HUGETLB_PAGE_SIZE_VARIABLE) \
  /x96-build/7.2.12-trim/include/linux/page-flags-layout.h \
  /x96-build/kbuild-trim/include/generated/bounds.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/sparsemem.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/pgtable-prot.h \
    $(wildcard include/config/HAVE_ARCH_USERFAULTFD_WP) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/rsi.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/rsi_cmds.h \
  /x96-build/7.2.12-trim/include/linux/arm-smccc.h \
    $(wildcard include/config/HAVE_ARM_SMCCC) \
    $(wildcard include/config/ARM) \
  /x96-build/7.2.12-trim/include/linux/uuid.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/rsi_smc.h \
  /x96-build/7.2.12-trim/include/linux/mm_types.h \
    $(wildcard include/config/HAVE_ALIGNED_STRUCT_PAGE) \
    $(wildcard include/config/SLAB_OBJ_EXT) \
    $(wildcard include/config/HUGETLB_PMD_PAGE_TABLE_SHARING) \
    $(wildcard include/config/SLAB_FREELIST_HARDENED) \
    $(wildcard include/config/USERFAULTFD) \
    $(wildcard include/config/ANON_VMA_NAME) \
    $(wildcard include/config/PER_VMA_LOCK) \
    $(wildcard include/config/HAVE_ARCH_COMPAT_MMAP_BASES) \
    $(wildcard include/config/MEMBARRIER) \
    $(wildcard include/config/ARCH_HAS_ELF_CORE_EFLAGS) \
    $(wildcard include/config/AIO) \
    $(wildcard include/config/MMU_NOTIFIER) \
    $(wildcard include/config/SPLIT_PMD_PTLOCKS) \
    $(wildcard include/config/IOMMU_MM_DATA) \
    $(wildcard include/config/KSM) \
    $(wildcard include/config/MM_ID) \
    $(wildcard include/config/CORE_DUMP_DEFAULT_ELF_HEADERS) \
  /x96-build/7.2.12-trim/include/linux/auxvec.h \
  /x96-build/7.2.12-trim/include/uapi/linux/auxvec.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/auxvec.h \
  /x96-build/7.2.12-trim/include/linux/kref.h \
  /x96-build/7.2.12-trim/include/linux/rbtree.h \
  /x96-build/7.2.12-trim/include/linux/rcupdate.h \
    $(wildcard include/config/TINY_RCU) \
    $(wildcard include/config/RCU_STRICT_GRACE_PERIOD) \
    $(wildcard include/config/RCU_LAZY) \
    $(wildcard include/config/RCU_STALL_COMMON) \
    $(wildcard include/config/VIRT_XFER_TO_GUEST_WORK) \
    $(wildcard include/config/RCU_NOCB_CPU) \
    $(wildcard include/config/TASKS_RCU_GENERIC) \
    $(wildcard include/config/TASKS_RUDE_RCU) \
    $(wildcard include/config/TREE_RCU) \
    $(wildcard include/config/DEBUG_OBJECTS_RCU_HEAD) \
    $(wildcard include/config/PROVE_RCU) \
    $(wildcard include/config/ARCH_WEAK_RELEASE_ACQUIRE) \
  /x96-build/7.2.12-trim/include/linux/context_tracking_irq.h \
    $(wildcard include/config/CONTEXT_TRACKING_IDLE) \
  /x96-build/7.2.12-trim/include/linux/rcutree.h \
  /x96-build/7.2.12-trim/include/linux/maple_tree.h \
    $(wildcard include/config/MAPLE_RCU_DISABLED) \
    $(wildcard include/config/DEBUG_MAPLE_TREE) \
  /x96-build/7.2.12-trim/include/linux/rwsem.h \
    $(wildcard include/config/RWSEM_SPIN_ON_OWNER) \
    $(wildcard include/config/DEBUG_RWSEMS) \
  /x96-build/7.2.12-trim/include/linux/completion.h \
  /x96-build/7.2.12-trim/include/linux/swait.h \
  /x96-build/7.2.12-trim/include/linux/uprobes.h \
  /x96-build/7.2.12-trim/include/linux/timer.h \
    $(wildcard include/config/DEBUG_OBJECTS_TIMERS) \
    $(wildcard include/config/NO_HZ_COMMON) \
  /x96-build/7.2.12-trim/include/linux/ktime.h \
  /x96-build/7.2.12-trim/include/linux/jiffies.h \
  /x96-build/7.2.12-trim/include/vdso/jiffies.h \
  /x96-build/kbuild-trim/include/generated/timeconst.h \
  /x96-build/7.2.12-trim/include/vdso/ktime.h \
  /x96-build/7.2.12-trim/include/linux/timekeeping.h \
    $(wildcard include/config/POSIX_AUX_CLOCKS) \
    $(wildcard include/config/GENERIC_CMOS_UPDATE) \
  /x96-build/7.2.12-trim/include/linux/clocksource_ids.h \
  /x96-build/7.2.12-trim/include/linux/debugobjects.h \
    $(wildcard include/config/DEBUG_OBJECTS) \
    $(wildcard include/config/DEBUG_OBJECTS_FREE) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/uprobes.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/debug-monitors.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/esr.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/probes.h \
  /x96-build/7.2.12-trim/include/linux/workqueue.h \
    $(wildcard include/config/DEBUG_OBJECTS_WORK) \
    $(wildcard include/config/FREEZER) \
    $(wildcard include/config/WQ_WATCHDOG) \
  /x96-build/7.2.12-trim/include/linux/percpu_counter.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/mmu.h \
    $(wildcard include/config/ARM64_E0PD) \
  /x96-build/7.2.12-trim/include/linux/page-flags.h \
    $(wildcard include/config/PAGE_IDLE_FLAG) \
    $(wildcard include/config/ARCH_USES_PG_ARCH_2) \
    $(wildcard include/config/ARCH_USES_PG_ARCH_3) \
    $(wildcard include/config/MIGRATION) \
    $(wildcard include/config/DEBUG_KMAP_LOCAL_FORCE_MAP) \
  /x96-build/7.2.12-trim/include/linux/local_lock.h \
  /x96-build/7.2.12-trim/include/linux/local_lock_internal.h \
  /x96-build/7.2.12-trim/include/linux/zswap.h \
    $(wildcard include/config/ZSWAP) \
  /x96-build/7.2.12-trim/include/linux/memory_hotplug.h \
    $(wildcard include/config/ARCH_HAS_ADD_PAGES) \
    $(wildcard include/config/MEMORY_HOTREMOVE) \
  /x96-build/7.2.12-trim/include/linux/notifier.h \
  /x96-build/7.2.12-trim/include/linux/srcu.h \
    $(wildcard include/config/TINY_SRCU) \
    $(wildcard include/config/NEED_SRCU_NMI_SAFE) \
  /x96-build/7.2.12-trim/include/linux/rcu_segcblist.h \
  /x96-build/7.2.12-trim/include/linux/srcutree.h \
  /x96-build/7.2.12-trim/include/linux/rcu_node_tree.h \
    $(wildcard include/config/RCU_FANOUT) \
    $(wildcard include/config/RCU_FANOUT_LEAF) \
  /x96-build/7.2.12-trim/include/linux/topology.h \
    $(wildcard include/config/USE_PERCPU_NUMA_NODE_ID) \
    $(wildcard include/config/SCHED_SMT) \
    $(wildcard include/config/GENERIC_ARCH_TOPOLOGY) \
  /x96-build/7.2.12-trim/include/linux/arch_topology.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/topology.h \
  /x96-build/7.2.12-trim/include/asm-generic/topology.h \
  /x96-build/7.2.12-trim/include/linux/sysctl.h \
    $(wildcard include/config/SYSCTL) \
  /x96-build/7.2.12-trim/include/uapi/linux/sysctl.h \
  /x96-build/7.2.12-trim/include/linux/elf.h \
    $(wildcard include/config/ARCH_HAVE_EXTRA_ELF_NOTES) \
    $(wildcard include/config/ARCH_USE_GNU_PROPERTY) \
    $(wildcard include/config/ARCH_HAVE_ELF_PROT) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/elf.h \
    $(wildcard include/config/COMPAT_VDSO) \
  /x96-build/kbuild-trim/arch/arm64/include/generated/asm/user.h \
  /x96-build/7.2.12-trim/include/asm-generic/user.h \
  /x96-build/7.2.12-trim/include/uapi/linux/elf.h \
  /x96-build/7.2.12-trim/include/uapi/linux/elf-em.h \
  /x96-build/7.2.12-trim/include/linux/fs.h \
    $(wildcard include/config/FANOTIFY_ACCESS_PERMISSIONS) \
    $(wildcard include/config/FS_POSIX_ACL) \
    $(wildcard include/config/CGROUP_WRITEBACK) \
    $(wildcard include/config/IMA) \
    $(wildcard include/config/FILE_LOCKING) \
    $(wildcard include/config/FSNOTIFY) \
    $(wildcard include/config/EPOLL) \
    $(wildcard include/config/FS_DAX) \
    $(wildcard include/config/BLOCK) \
    $(wildcard include/config/UNICODE) \
  /x96-build/7.2.12-trim/include/linux/fs/super.h \
  /x96-build/7.2.12-trim/include/linux/fs/super_types.h \
    $(wildcard include/config/QUOTA) \
    $(wildcard include/config/FS_ENCRYPTION) \
    $(wildcard include/config/FS_VERITY) \
  /x96-build/7.2.12-trim/include/linux/fs_dirent.h \
  /x96-build/7.2.12-trim/include/linux/errseq.h \
  /x96-build/7.2.12-trim/include/linux/list_lru.h \
  /x96-build/7.2.12-trim/include/linux/shrinker.h \
    $(wildcard include/config/SHRINKER_DEBUG) \
  /x96-build/7.2.12-trim/include/linux/xarray.h \
    $(wildcard include/config/XARRAY_MULTI) \
  /x96-build/7.2.12-trim/include/linux/sched/mm.h \
    $(wildcard include/config/MMU_LAZY_TLB_REFCOUNT) \
    $(wildcard include/config/ARCH_HAS_MEMBARRIER_CALLBACKS) \
    $(wildcard include/config/ARCH_HAS_SYNC_CORE_BEFORE_USERMODE) \
  /x96-build/7.2.12-trim/include/linux/sync_core.h \
    $(wildcard include/config/ARCH_HAS_PREPARE_SYNC_CORE_CMD) \
  /x96-build/7.2.12-trim/include/linux/sched/coredump.h \
  /x96-build/7.2.12-trim/include/linux/list_bl.h \
  /x96-build/7.2.12-trim/include/linux/bit_spinlock.h \
  /x96-build/7.2.12-trim/include/linux/percpu-rwsem.h \
  /x96-build/7.2.12-trim/include/linux/rcuwait.h \
  /x96-build/7.2.12-trim/include/linux/sched/signal.h \
    $(wildcard include/config/SCHED_AUTOGROUP) \
    $(wildcard include/config/BSD_PROCESS_ACCT) \
    $(wildcard include/config/TASKSTATS) \
  /x96-build/7.2.12-trim/include/linux/rculist.h \
    $(wildcard include/config/PROVE_RCU_LIST) \
  /x96-build/7.2.12-trim/include/linux/signal.h \
    $(wildcard include/config/DYNAMIC_SIGFRAME) \
    $(wildcard include/config/PROC_FS) \
  /x96-build/7.2.12-trim/include/linux/sched/jobctl.h \
  /x96-build/7.2.12-trim/include/linux/sched/task.h \
    $(wildcard include/config/HAVE_EXIT_THREAD) \
    $(wildcard include/config/ARCH_WANTS_DYNAMIC_TASK_STRUCT) \
    $(wildcard include/config/HAVE_ARCH_THREAD_STRUCT_WHITELIST) \
  /x96-build/7.2.12-trim/include/linux/uaccess.h \
    $(wildcard include/config/ARCH_HAS_SUBPAGE_FAULTS) \
    $(wildcard include/config/ARCH_MEMORY_ORDER_TSO) \
    $(wildcard include/config/HARDENED_USERCOPY) \
  /x96-build/7.2.12-trim/include/linux/fault-inject-usercopy.h \
    $(wildcard include/config/FAULT_INJECTION_USERCOPY) \
  /x96-build/7.2.12-trim/include/linux/nospec.h \
  /x96-build/7.2.12-trim/include/linux/ucopysize.h \
    $(wildcard include/config/HARDENED_USERCOPY_DEFAULT_ON) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/uaccess.h \
    $(wildcard include/config/CC_HAS_ASM_GOTO_OUTPUT) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/kernel-pgtable.h \
    $(wildcard include/config/RELOCATABLE) \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/asm-extable.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/mte.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/extable.h \
    $(wildcard include/config/BPF_JIT) \
  /x96-build/7.2.12-trim/include/asm-generic/access_ok.h \
    $(wildcard include/config/ALTERNATE_USER_ADDRESS_SPACE) \
  /x96-build/7.2.12-trim/include/linux/cred.h \
  /x96-build/7.2.12-trim/include/linux/capability.h \
  /x96-build/7.2.12-trim/include/uapi/linux/capability.h \
  /x96-build/7.2.12-trim/include/linux/key.h \
    $(wildcard include/config/KEY_NOTIFICATIONS) \
    $(wildcard include/config/NET) \
  /x96-build/7.2.12-trim/include/linux/assoc_array.h \
    $(wildcard include/config/ASSOCIATIVE_ARRAY) \
  /x96-build/7.2.12-trim/include/linux/sched/user.h \
    $(wildcard include/config/VFIO_PCI_ZDEV_KVM) \
    $(wildcard include/config/IOMMUFD) \
    $(wildcard include/config/SECRETMEM) \
    $(wildcard include/config/WATCH_QUEUE) \
  /x96-build/7.2.12-trim/include/linux/ratelimit.h \
  /x96-build/7.2.12-trim/include/linux/pid.h \
  /x96-build/7.2.12-trim/include/linux/rhashtable-types.h \
  /x96-build/7.2.12-trim/include/linux/posix-timers.h \
  /x96-build/7.2.12-trim/include/linux/alarmtimer.h \
    $(wildcard include/config/RTC_CLASS) \
  /x96-build/7.2.12-trim/include/linux/hrtimer.h \
    $(wildcard include/config/HIGH_RES_TIMERS) \
    $(wildcard include/config/TIME_LOW_RES) \
    $(wildcard include/config/TIMERFD) \
  /x96-build/7.2.12-trim/include/linux/hrtimer_defs.h \
  /x96-build/7.2.12-trim/include/linux/timerqueue.h \
  /x96-build/7.2.12-trim/include/linux/hrtimer_rearm.h \
    $(wildcard include/config/HRTIMER_REARM_DEFERRED) \
  /x96-build/7.2.12-trim/include/linux/rcuref.h \
  /x96-build/7.2.12-trim/include/linux/rcu_sync.h \
  /x96-build/7.2.12-trim/include/linux/quota.h \
    $(wildcard include/config/QUOTA_NETLINK_INTERFACE) \
  /x96-build/7.2.12-trim/include/uapi/linux/dqblk_xfs.h \
  /x96-build/7.2.12-trim/include/linux/dqblk_v1.h \
  /x96-build/7.2.12-trim/include/linux/dqblk_v2.h \
  /x96-build/7.2.12-trim/include/linux/dqblk_qtree.h \
  /x96-build/7.2.12-trim/include/linux/projid.h \
  /x96-build/7.2.12-trim/include/uapi/linux/quota.h \
  /x96-build/7.2.12-trim/include/linux/unicode.h \
  /x96-build/7.2.12-trim/include/linux/dcache.h \
  /x96-build/7.2.12-trim/include/linux/rculist_bl.h \
  /x96-build/7.2.12-trim/include/linux/lockref.h \
    $(wildcard include/config/ARCH_USE_CMPXCHG_LOCKREF) \
  /x96-build/7.2.12-trim/include/linux/stringhash.h \
    $(wildcard include/config/DCACHE_WORD_ACCESS) \
  /x96-build/7.2.12-trim/include/linux/hash.h \
    $(wildcard include/config/HAVE_ARCH_HASH) \
  /x96-build/7.2.12-trim/include/linux/vfsdebug.h \
    $(wildcard include/config/DEBUG_VFS) \
  /x96-build/7.2.12-trim/include/linux/wait_bit.h \
  /x96-build/7.2.12-trim/include/linux/kdev_t.h \
  /x96-build/7.2.12-trim/include/uapi/linux/kdev_t.h \
  /x96-build/7.2.12-trim/include/linux/path.h \
  /x96-build/7.2.12-trim/include/linux/radix-tree.h \
  /x96-build/7.2.12-trim/include/linux/semaphore.h \
  /x96-build/7.2.12-trim/include/linux/fcntl.h \
    $(wildcard include/config/ARCH_32BIT_OFF_T) \
  /x96-build/7.2.12-trim/include/uapi/linux/fcntl.h \
  /x96-build/7.2.12-trim/arch/arm64/include/uapi/asm/fcntl.h \
  /x96-build/7.2.12-trim/include/uapi/asm-generic/fcntl.h \
  /x96-build/7.2.12-trim/include/uapi/linux/openat2.h \
  /x96-build/7.2.12-trim/include/linux/migrate_mode.h \
  /x96-build/7.2.12-trim/include/linux/delayed_call.h \
  /x96-build/7.2.12-trim/include/linux/ioprio.h \
  /x96-build/7.2.12-trim/include/linux/sched/rt.h \
  /x96-build/7.2.12-trim/include/linux/iocontext.h \
    $(wildcard include/config/BLK_ICQ) \
  /x96-build/7.2.12-trim/include/uapi/linux/ioprio.h \
  /x96-build/7.2.12-trim/include/linux/mount.h \
  /x96-build/7.2.12-trim/include/linux/mnt_idmapping.h \
  /x96-build/7.2.12-trim/include/linux/slab.h \
    $(wildcard include/config/FAILSLAB) \
    $(wildcard include/config/KFENCE) \
    $(wildcard include/config/SLUB_TINY) \
    $(wildcard include/config/SLUB_DEBUG) \
    $(wildcard include/config/KMALLOC_PARTITION_RANDOM) \
    $(wildcard include/config/KMALLOC_PARTITION_TYPED) \
    $(wildcard include/config/SLAB_BUCKETS) \
    $(wildcard include/config/KVFREE_RCU_BATCHED) \
  /x96-build/7.2.12-trim/include/linux/percpu-refcount.h \
  /x96-build/7.2.12-trim/include/linux/rw_hint.h \
  /x96-build/7.2.12-trim/include/linux/file_ref.h \
  /x96-build/7.2.12-trim/include/uapi/linux/fs.h \
  /x96-build/7.2.12-trim/include/linux/kobject.h \
    $(wildcard include/config/UEVENT_HELPER) \
    $(wildcard include/config/DEBUG_KOBJECT_RELEASE) \
  /x96-build/7.2.12-trim/include/linux/sysfs.h \
  /x96-build/7.2.12-trim/include/linux/kernfs.h \
    $(wildcard include/config/KERNFS) \
  /x96-build/7.2.12-trim/include/linux/idr.h \
  /x96-build/7.2.12-trim/include/linux/kobject_ns.h \
  /x96-build/7.2.12-trim/include/linux/moduleparam.h \
    $(wildcard include/config/ALPHA) \
    $(wildcard include/config/PPC64) \
  /x96-build/7.2.12-trim/include/linux/rbtree_latch.h \
  /x96-build/7.2.12-trim/include/linux/error-injection.h \
  /x96-build/7.2.12-trim/include/asm-generic/error-injection.h \
  /x96-build/7.2.12-trim/arch/arm64/include/asm/module.h \
  /x96-build/7.2.12-trim/include/asm-generic/module.h \
    $(wildcard include/config/HAVE_MOD_ARCH_SPECIFIC) \
  /x96-build/7.2.12-trim/include/linux/export-internal.h \
    $(wildcard include/config/PARISC) \

meson-vdec.mod.o: $(deps_meson-vdec.mod.o)

$(deps_meson-vdec.mod.o):
