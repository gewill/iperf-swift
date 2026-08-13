/*
 * Copyright (c) 2026 iPerf Swift contributors.
 * SPDX-License-Identifier: MIT
 *
 * Minimal atomic compatibility declarations for the Apple targets supported
 * by this package. The public iperf structures must expose integer fields so
 * they remain importable by Swift's Clang importer. Operations use compiler
 * atomic builtins where the C source needs them.
 */
#ifndef IPERF_STDATOMIC_H
#define IPERF_STDATOMIC_H

#include <stdint.h>

typedef intptr_t atomic_uint_fast64_t;

#define ATOMIC_FLAG_INIT 0
#define ATOMIC_VAR_INIT(value) (value)

static inline void atomic_init(atomic_uint_fast64_t *object, uint64_t value)
{
    __atomic_store_n(object, value, __ATOMIC_SEQ_CST);
}

static inline uint64_t atomic_load(const atomic_uint_fast64_t *object)
{
    return __atomic_load_n(object, __ATOMIC_SEQ_CST);
}

static inline void atomic_store(atomic_uint_fast64_t *object, uint64_t value)
{
    __atomic_store_n(object, value, __ATOMIC_SEQ_CST);
}

static inline uint64_t atomic_fetch_add(atomic_uint_fast64_t *object, uint64_t value)
{
    return __atomic_fetch_add(object, value, __ATOMIC_SEQ_CST);
}

#define atomic_load_explicit(object, order) atomic_load(object)
#define atomic_store_explicit(object, value, order) atomic_store(object, value)
#define atomic_fetch_add_explicit(object, value, order) atomic_fetch_add(object, value)

static inline void atomic_thread_fence(int order)
{
    __atomic_thread_fence(order);
}

#endif /* IPERF_STDATOMIC_H */
