#pragma once
#include <stdint.h>

/* Opaque handle types */
typedef struct darwin_ring darwin_ring;
typedef struct darwin_sqe  darwin_sqe;

/* Completion queue entry – same layout as io_uring_cqe */
typedef struct darwin_cqe {
    uint64_t user_data;
    int32_t  res;
    int32_t  _pad;
} darwin_cqe;

/* Ring lifecycle */
darwin_ring *darwin_ring_create (unsigned sq_size, unsigned cq_size);
void         darwin_ring_destroy(darwin_ring *ring);

/* Submission */
darwin_sqe *darwin_get_sqe    (darwin_ring *ring);
void        darwin_sqe_set_data(darwin_sqe *sqe, uint64_t user_data);
void        darwin_prep_read  (darwin_sqe *sqe, int fd, void       *buf,
                                uint32_t len, uint64_t offset);
void        darwin_prep_write (darwin_sqe *sqe, int fd, const void *buf,
                                uint32_t len, uint64_t offset);
void        darwin_prep_nop   (darwin_sqe *sqe);
int         darwin_submit     (darwin_ring *ring);

/* Completion – mirrors io_uring peek/wait/seen semantics */
int  darwin_wait_cqe(darwin_ring *ring, darwin_cqe **cqe_out); /* blocking     */
int  darwin_peek_cqe(darwin_ring *ring, darwin_cqe **cqe_out); /* non-blocking */
void darwin_cqe_seen(darwin_ring *ring, darwin_cqe *cqe);
