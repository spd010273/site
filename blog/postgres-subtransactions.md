PostgreSQL, Subtransactions, and your SLA
=========================================

Date: 2022-09-21

Tags: SubtransSLRU, SubtransBuffer, Logical Replication Lag

# Background:

We began experiencing issues after implementing several optimizations in our application, which, when combined with a surge in customer utilization, resulted in extremely slow page performance, timeouts, and usability complaints. Our servers are running PostgreSQL 13.8. These changes resulted in, unbeknownst to us, passing a TPS (Transactions Per Second) threshold which triggered this subtransaction issue. It was only after investigating the wait states and locks held by stuck backends that we stumbled upon the `SubtransSLRU` and `SubtransBuffer` wait states, and the drawbacks of using subtransactions.

Subtransactions provide a way to handle runtime errors within SQL by issuing named SAVEPOINTs while within a transaction. Similar to demarcation of a transaction with `BEGIN`, `COMMIT`, or `ROLLBACK`, Subtransactions are demarcated with `SAVEPOINT <name>`, `RELEASE SAVEPOINT <name>`, and `ROLLBACK TO SAVEPOINT <name>`.

Subtransactions can also be implicitly issued. Within PostgreSQL's PL/pgSQL procedural language, subtransactions are automatically issued when an `EXCEPTION` block is present in the in-scope code block. This gives the procedure a known state to go back to if a given code block fails so that execution can resume and the parent transaction can be salvaged.

Try-catch blocks are nothing new to the field of software engineering. They provide an excellent way to wrap 'risky' operations with and unknown number of failure modes. They keep code short and concise. We'll be diving into why they can be a bad idea for high TPS (Transactions Per Second) PostgreSQL database systems.


# Symptoms:

Most symptoms of the softlocking seen when subtransactions overwhelm a system are documented. Here is some excellent background articles for further reading:

* [Postgres.AI blog](https://postgres.ai/blog/20210831-postgresql-subtransactions-considered-harmful)
* [GitLab](https://about.gitlab.com/blog/2021/09/29/why-we-spent-the-last-month-eliminating-postgresql-subtransactions)
* [Cybertec](https://www.cybertec-postgresql.com/en/subtransactions-and-performance-in-postgresql/)


Symptoms of soft locking on a primary / read replica database server:

* High number of outstanding / active queries executing or waiting to execute (pgbouncer: cl_waiting)
* Low average CPU usage (processes NOT in 'D' state)
* More than one backend with the wait_event `SubtransSLRU` or `SubtransBuffer` (more on this later)
* Catalog locked - getting the definition of a catalog table is impossible while the server is in this state


From a system-wide viewpoint, this state can result in query timeouts to be exceeded in the application layer, and appears as a severe drop in throughput with no obvious causes like:

* No obvious CPU / I/O thrashing
* OS not utilizing swap (near out of memory scenarios)
* Queries otherwise execute quickly in a development / staging environment
* Statistics up-to-date and query plans are identical or close to expected


For logical replication, things get a little more murky. Without putting the server into a more verbose logging mode, the symptoms are:

* Logical streaming repeatedly falls behind with the standby node entering 'catchup' state but never able to resume normal operation
* Logs fill with `could not start WAL streaming: ERROR:  replication slot "<slot name>" is active for PID <pid>`
* The above error is seen when trying to drop / recreate the replication slot or publication / subscription pair.

If `DEBUG2` logging ( via the server's `log_min_messages` setting ) is enabled on the logical replication server, the logs will be filled with large blocks of:
```
DEBUG:  spill 1 changes in XID 845012185 to disk
DEBUG:  spill 2 changes in XID 845012186 to disk
...
```

# Diagnosis:

## Transaction Throughput

The following query will tell you if your system has outstanding `SubtransSLRU` or `SubtransBuffer` wait_events executing:
```sql
WITH tt_wait_events_lwlock AS
(
    SELECT 'LWLock' AS wait_event_type,
           'SubtransSLRU' AS subtrans_slru,
           'SubtransBuffer' AS subtrans_buffer
)
    SELECT COUNT( DISTINCT a_ss.pid ) AS subtrans_slru,
           COUNT( DISTINCT a_sb.pid ) AS subtrans_buffer
      FROM tt_wait_events_lwlock tt
 LEFT JOIN pg_stat_activity a_ss
        ON a_ss.wait_event = tt.subtrans_slru
       AND a_ss.state = 'active'
       AND a_ss.wait_event_type = tt.wait_event_type
 LEFT JOIN pg_stat_activity a_sb
        ON a_sb.wait_event = tt.subtrans_buffer
       AND a_sb.state = 'active'
       AND a_sb.wait_event_type = tt.wait_event_type;
```

NOTE: If you are going to use this to set up a monitor (Nagios, Datadog, et al), you will need a short polling period - these events in a system on the threshold of soft-locking can be very fleeting.

The `SubtransSLRU` and `SubtransBuffer` wait states revolve around the `transam`, `slru`, and `lmgr` code within PostgreSQL. Specifically, entry into the `SubTransSetParent`, `SubTransGetTopmostTransaction` subroutines results in a call to `LWLockAcquire` for the `SubtransSLRULock` lightweight lock.

These locks are stored in a section of shared_buffers which is allocated by postmaster at startup. The lock tranche is `LWTRANCHE_SUBTRANS_BUFFER`, and is a SLRU (Simple Least Recently Used) buffer. This buffer is linearly searched and optimized for access to the first (most recent) page.

When a backend needs to get / set a given subtransactions top level transaction ID, it will attempt to acquire the LWLock on the subtransaction SLRU to read or write this information. If the page is not in memory at the time, the slru code will take out the buffer control lock for the tranche (`SubtransBuffer`) while moving pages from/to disk. There is also underlying code to handle dirty in-memory pages and the associated flushing activity. If enough backends are attempting to call `SubTransSetParent` or `SubTransGetTopmostTransaction`, the system will get bogged down in the `LWLockAcquire` for the `SubtransSLRU` lock, and if the pressure is especially bad, the `SimpleLruReadPage` -> `LWLockAcquire` chain (`SubtransBuffer`).

Taking a step back, why would PostgreSQL want to obtain these locks?

From backend/access/transam/xact.c:
```c
AssignTransactionId(TransactionState s)
...
    if (isSubXact)
        SubTransSetParent(XidFromFullTransactionId(s->fullTransactionId),
                          XidFromFullTransactionId(s->parent->fullTransactionId));
...
```

From backend/access/transam/twophase.c:
```c
ProcessTwoPhaseBuffer(TransactionID xid,
...
    for (i = 0; i < hdr->nsubxacts; i++)
    {
        TransactionId subxid = subxids[i];

        Assert(TransactionIdFollows(subxid, xid));

        /* update nextFullXid if needed */
        if (setNextXid)
            AdvanceNextFullTransactionIdPastXid(subxid);

        if (setParent)
            SubTransSetParent(subxid, xid);
    }
...
```

From backend/storage/ipc/procarray.c:
```c
ProcArrayApplyXidAssignment(TransactionId topxid,
...
    for (i = 0; i < nsubxids; i++)
        SubTransSetParent(subxids[i], topxid);
...
```

To a lesser extent - calls to `SubTransGetTopmostTransacton` ( which calls `LWLockAcquire` on `SubtransSLRU` and possibly `SimpleLruReadPage_ReadOnly` ) appears in:

* backend/access/heap/heapam.c: HeapCheckForSerializableConflictOut()
* backend/storage/ipc/procarray.c: TransactionIdsInProgress()
* backend/storage/lmgr/lmgr.c: XactLockTableWait() and ConditionalXactLockTableWait()
* backend/utils/time/snapmgr.c: XidInMVCCSnapshot()

Code invoking this execution path is all over the PostgreSQL codebase, providing ample opportunities for backends to get stuck waiting on LWLocks to the `SubtransSLRU`.

As described in the associated articles, avoiding subtransactions is critical for maintaining consistent performance.

## Logical Replication

Logical standby lag described in the symtoms section is caused by a bottleneck at the walsender as it is attempting to sequence transactions for the logical decoder.

Within the `WalSndLoop` in walsender.c, `XLogSendLogical` is called via function pointer prior to initialization. This calls `LogicalDecodingProcessRecord` prior to handing off the record to the Logical Decoder for output. Within `LogicalDecodingProcessRecord`, most normal transaction log operations are handled by `ReorderBufferProcessXid`. Eventually, `ReorderBufferSerializeTXN` is called, spending a large amount of time in the following loop:

Here, in attempting to serialize records read in from WAL, the `ReorderBufferSerializeTXN` function recursively calls itself from within a loop:
```c
    /* do the same to all child TXs */
    dlist_foreach(subtxn_i, &txn->subtxns)
    {
        ReorderBufferTXN *subtxn;

        subtxn = dlist_container(ReorderBufferTXN, node, subtxn_i.cur);
        ReorderBufferSerializeTXN(rb, subtxn);
    }
```

This block sequences nested subtransactions, and while not related to the `SubtransSLRU` issue described above, the runtime of this code is heavily dependent on the volume of subtransactions and their nesting. Due to this combination, it is advisable to avoid subtransactions in logically replicated systems that see a high level of throughput. Inadvertent nesting of transactions of broad scope can quickly deteriorate the runtime performance of this code block. We've seen logical read replicas fall behind in their subscriptions multiple times a week while streaming replication remains intact on a similarly-specced server.


## Read Replicas

Read replicas can get caught up in a similar soft-locking mode, but with a twist: As mentioned in the Postgres.ai blog post, this problem is predicated by a long-running transaction on the primary server.

This keystone to this issue relies in the procarray hooks in which the replicas attempt to to lookup the top-level XID for a given XID. This magnifies the problem on the read replicas as this happens for every transaction, regardless of it having a savepoint. Long running queries keep that pg_subtrans entry active, extending the number of subtransactions needed to be searched through.


# Prognosis:

If subtransactions are unavoidable, expect the following outcomes:

When a backend exceeds `PGPROC_MAX_CACHED_SUBXIDS` at the session level, it will start getting caught in the `LWLockAcquire` execution chain for `SubtransSLRU`. This can remain unnoticed for years but can be noticed by either observing the wait events or noting that high TPS environments take a longer time to execute a given query compared to a lower TPS environment when all other variables (plans, hardware, etc) remain nearly identical.

When the global number of subtransactions exceed `NUM_SUBTRANS_BUFFERS` * 8KiB / 4 Bytes = 65536 entries, the especially brutal competition for the `LWTRANCHE_SUBTRANS_BUFFER` begins. Backends begin entering the `SubTransSetParent` -> `LWLockAcquire( SubtransSLRU )` -> slru page swap in / out to shared_buffers chain. This will begin to impact other backends attempting to perform non-subtransaction work ( via `SubTransGetTopmostTransaction` ) and will result in many of the symptoms described earlier.

This will cause normally fast queries to slow down substantially, resulting in clients waiting to connect, connection timeouts and session timeouts at the application, transport, or backend level.


# Cure:

The obvious answer, after reading the included articles, is to eliminate SAVEPOINTs and PL/pgSQL EXCEPTION blocks. These are not safe to use in their current implementation in a production environment that sees OLTP workloads. Barring that, the only other solution is to throw CPU power at the problem, or to recompile PostgreSQL with larger Subtransaction / XID buffers:

* `#define PGPROC_MAX_CACHED_SUBXIDS 64` in include/storage/proc.h
* `#define NUM_SUBTRANS_BUFFERS 32` in include/access/subtrans.h

Because pg_subtrans is being actively used while the servers are in this soft-locked state, it is highly likely that the associated pages will be in the kernel's page cache. Ensuring that the kernel has enough room to keep these pages resident can help alleviate the issue partially, but eventually the backends will become stuck effectively memcpy()ing pages from the page cache to shared_buffers and back.

When removing subtransactions, any call to `SAVEPOINT` is unsafe. Functions with `EXCEPTION` handling are not safe (raising exceptions is perfectly fine).

# Possible Long-Term Fixes

The subtransaction functionality within PostgreSQL is important! There are use cases where they are unavoidable. The implementation is also correct - handling of the subtransactions is critical to PostgreSQL's MVCC (Multi Version Concurrency Control) functionality, as well as the high level operation of serializing client's changes to disk operations. What could help is the addition of tunable parameters. Allow database and system administrators to fine tune these buffer sizes in a way that suits a servers size and expected throughput. Small installations, some data warehouses, and many unknown use cases are fine with the default setting!
In fact, this has already been addressed! As mentioned in the Gitlab article, Andrey Borodin at Yandex has addressed this with a [patch](https://www.postgresql.org/message-id/flat/494C5E7F-E410-48FA-A93E-F7723D859561%40yandex-team.ru#18c79477bf7fc44a3ac3d1ce55e4c169). Let's get that reviewed or otherwise integrated into the code base!

However, logical replication's interaction with subtransactions is a different beast entirely. The sequencing of these subtransactions MUST occur for the logical decoder to see the 'correct' order of operations as they occured within a transaction.
