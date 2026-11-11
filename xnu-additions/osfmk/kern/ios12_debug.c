/*
 * ios12-tablet: boot diagnostics.
 *
 * ios12_dump_threads() prints every kernel thread with what it is waiting on
 * and a short backtrace of where it blocked, so a silent boot hang can be
 * traced. Addresses are symbolised offline against the unstripped kernel
 * (tools/xnu_threads.py).
 */
#include <kern/thread.h>
#include <kern/task.h>
#include <kern/queue.h>
#include <kern/locks.h>
#include <kern/misc_protos.h>
/* struct thread_kernel_state comes in via kern/thread.h -> machine/thread.h */

extern queue_head_t threads;
extern lck_mtx_t tasks_threads_lock;

#define IOS12_STACK_SPAN  0x10000   /* generous bound for walking a kernel stack */

void ios12_dump_threads(void);

void
ios12_dump_threads(void)
{
	thread_t th;
	thread_t self = current_thread();

	printf("ios12-dump: begin\n");
	lck_mtx_lock(&tasks_threads_lock);
	queue_iterate(&threads, th, thread_t, threads) {
		printf("ios12-dump: thread %p tid %llu state 0x%x event 0x%llx cont %p kernel_task %d\n",
		    th, th->thread_id, th->state, (unsigned long long)th->wait_event,
		    th->continuation, th->task == kernel_task);

		if (th == self || th->kernel_stack == 0 || th->machine.kstackptr == 0) {
			continue;
		}
		struct thread_kernel_state *ks = (struct thread_kernel_state *)th->machine.kstackptr;
		arm_saved_state64_t *ss = saved_state64(&ks->machine.ss);
		uint64_t lo = th->kernel_stack, hi = th->kernel_stack + IOS12_STACK_SPAN;
		uint64_t fp = ss->fp;

		printf("ios12-dump:   bt %p", (void *)ss->lr);
		for (int i = 0; i < 14 && fp >= lo && fp + 16 <= hi && (fp & 0xf) == 0; i++) {
			uint64_t next = ((uint64_t *)fp)[0];
			uint64_t lr = ((uint64_t *)fp)[1];
			printf(" %p", (void *)lr);
			if (next <= fp) {
				break;
			}
			fp = next;
		}
		printf("\n");
	}
	lck_mtx_unlock(&tasks_threads_lock);
	printf("ios12-dump: end\n");
}
