PHP and SystemV Semaphores
==========================

Date: 2023-10-25

Tags: PHP, SystemV, Semaphores

# Background

## Semaphore Primer

Semaphores have been with humans since the Bronze Age, and possibly before. Flag, sign, marker, signal - all synonyms and indicators of what a semaphore does. In the realm of software, semaphores are used to indicate that a shared resource is being used, modified, or read. Something akin to a program saying:

* "I'm about to modify this shared document, don't look at it until I'm done."
* "I need to use the family car run an errand, be back in 30 minutes!"
* "Let's look at this slideshow, please don't modify it until we are finished with it."

The common thread is either the exclusive modification of, or shared use of a common resource. Semaphores can be used to signal this sharing or exclusivity between pieces of software running on the same system.

## SystemV

SystemV has a history stretching back to the 1980s. Design elements or actual software from the early years of UNIX systems still exist and influence software to this day. When I refer SystemV, however, I'm referring to one of those software components that have stood the test of time both in terms of robustness as well as how completely they satisfy their niche.

The component of SystemV I'm referring to is IPC, or Inter-Process Communication. This component includes the semaphores I mentioned earlier - the methods programs use to signal their intentions to each other. SystemV IPC also includes a shared memory and a message queueing element. SystemV's semaphore implementation provides a few functions that programs can use to manipulate semaphores:

* `semget()`: Create a group of semaphores, referred to as a semaphore set.
* `semctl()`: Modify, read, write, or delete a semaphore or semaphore set.
* `semop()`:  Perform an atomic operation(s) on a semaphore.

## Atomicity and Usage

Shared resources require some type of atomic operation(s) to be able to function without introducing a race condition or leading to undefined behaviors. Atomicity means that an operation or set of operations either all happen, or don't happen at all. This all-or-nothing is critically important to controlling the internal state of a computer program. Without atomic operations, programs would be even more bloated with conditional logic and error handling routines to capture edge cases, and those that are missed would most certainly lead to incorrect behavior.

`semop()` is arguably the most important semaphore manipulation function. It executes a list of operations on a semaphore in an atomic manner. Before we dive more into the details of how a program would use semaphores, let us touch on sets and flags.

When a semaphore set is created, the programmer must specify the number of semaphores needed. In our running example, we will use two semaphores in our set. Semaphores are numbered starting from 0, and incrementing past that. Our example semaphore set's two semaphores will be:

* 0: The 'write' semaphore. This indicates that we need exclusive access to a shared resource.
* 1: The 'read' semaphore. This insicates that the shared resource is in-use but not being modified.

These are considered an exclusive lock, and a shared lock, respectively. Programs that need to modify the resource must wait for all readers to finish using it. Conversely, a program that wants to read the shared resource must ensure it's not being modified before it attempts to read it.
`semop()` typically takes a few arguments:

* semaphore number: The member of the semaphore set we are modifying
* operation: Whether we are decrementing or incrementing a semaphore, or, a special case, waiting for it to be 0.
* flags: `IPC_NOWAIT`, or `SEM_UNDO`, or nothing.

### Flags:

* `IPC_NOWAIT`: Tells semop that if it enters a condition where it cannot proceed with the programmer's request, it should abort its attempt and return a failure to the program.
* `SEM_UNDO`: Tells semop that if this program were to exit (possibly unexpectedly), all operations marked with this flag that have been made by that program should be reverted.

There are two scenarios in which a call to `semop()` can be used to wait for a 'lock' to occur:

### Wait for 0

Here we wait for a semaphore's value to be 0. In our example, a writer or reader may increment their respective semaphore to indicate that a write or read is occurring, respectively. If a program enters the wait-for-0 state on, say, a write semaphore, It will successfully execute when all writers have indicated they are done with their operation.

### No 0 crossing / no decrement below 0

Semaphores cannot be less than 0, so another form of waiting that can occur is for an operation to be able to successfully execute. Let's walk through an example:

1. Some programs have been running for some time. They use a shared resource. This shared resouce has a limited number of concurrent users, so the semaphore is initalized to 10.
2. A few readers come along, and to indicate that they are using the shared resource, they decrement the semaphore by one. The semaphore now has a value of 7.
3. A writer comes along, and needs exclusive access to the shared resource. To prevent other readers, it attempts to decrement the semaphore by 10,
4. Since the decrement by 10 cannot complete, and the writer has not specified the `IPC_NOWAIT` flag, execution stops and it waits for its semaphore operation to complete.
5. Two readers finish their operations. To indicate that they no longer need the resource, they increment the semaphore. The semaphore's value is now 9.
6. The writer's decrement operation still cannot complete yet, it continues to wait.
7. A few other readers come along, decrementing the semaphore, performing their operations, and then incrementing the semaphore.
8. Finally, the last reader completes its work, incrementing the semaphore. The semaphore's value is now 10.
9. The writer's large decrement can now execute, and the writing program is now able to resume its work. The semaphore's value is now 0.
10. A potential reader arrives and attempt to decrement the semaphore, but since the semaphore cannot be decremented below 0, it waits.
11. The writer finishes making its changes and increments the semaphore by 10, allowing up to 10 readers to use the resource.
12. The readers are able to resume sharing the resource.

## PHP

PHP, aka Hypertext Preprocessor, is a way to generate dynamic web pages. PHP files can range from static HTML, like the web page you are viewing, to complex scripts which communicate with disparate data sources, modify and compute the data, then present it as if it were a static web page. PHP drives most of the web today, though it is competing with newer design philosophies and programming languages. PHP simplifies the interface to these semaphore functions with, as will be described later, some cost. These functions are:

* `sem_get()`: Create a group of semaphores.
* `sem_acquire()`: Assert a 'lock' on a semaphore, indicating that we need to use a shared resource.
* `sem_release()`: Release a 'lock' on a semaphore, indicating that we are done using the shared resource.
* `sem_remove()`: Delete a semaphore set.

Internally, when `sem_get()` is called, PHP creates a semaphore set with three semaphores. The scheme it uses to force processes to wait is the decrement-past-0:

* 0: `SYSVSEM_SEM` This semaphore is initialized to the max number of possible acquisitions. When `sem_acquire()` is called, this is decremented, and when `sem_release()` is called, this is incremented.
* 1: `SYSVSEM_USAGE` This is a counter of the number of processes using this semaphore. When a PHP process sees that it is the last process using the semaphore set (`SYSVSEM_USAGE` is equal to 1), it resets the value of `SYSVSEM_SEM` to the previous initialization value (maximum acquisitions)
* 2: `SYSVSEM_SETVAL` this is a locking semaphore used to ensure the other two semaphores are operated on attomically. PHP asserts this lock when `sem_get()` is called, then PHP increments `SYSVSEM_USAGE`.

Given that PHP doesn't allow the user to specify the semaphore locking paradigm, external programs must adapt to use this locking scheme.

# Implementation

The following implementation is in Perl, but can be readily adapted to C/C++ or languages that provide raw access to `semop()`. The scheme we are using is a single perl program is maintaining a shared resource and is responsible to writing / modifying it, and multiple PHP processes will access this shared resource for reading. The example Perl program will do the following:

1. Initialize the semaphore set.
2. Assert a write lock such that readers will wait at `sem_acquire()`
3. Do some processesing to a shared resource.
4. Deassert the write lock, allowing PHP readers to pass the `sem_acquire()` portion of their code.
5. Attempt to reassert the write lock, but have it wait for all readers to complete their work.

```perl
#!/usr/bin/perl

use strict;
use warnings;

use IPC::SysV qw( :all );
```

Initial includes. IPC::SysV includes the semaphore operation functions.

```perl
use constant {
    MAX_ACQUIRE  => 32767,
    SEMAPHORE_ID => 12345678,
    SEM_PERM     => ( S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH ),
    SEM_FLAG     => IPC_CREAT,
};

my $pack_mod = 's' . do {
    my $foobar = eval { pack( 'L!', 0 ); };
    $@ ? '' : '!';
} . '*';
```

This sets some constants and initializes, at runtime, a packing string used to control pack(), a function which lets Perl convert it's native scalar / array types to native C or system integer / binary / char * data. This specific example checks if the system supports packing unsigned long integers then assembles the packing string based on that.

```perl
my $SEMOP_ARGS = {
    INITSTART => [
        2, 0, 0,                                        # check for active sem_get()
        2, 1, SEM_UNDO,                                 # block any future sem_get() calls until we are done
    ],
    INITCHECK => [
        0, -MAX_ACQUIRE, SEM_UNDO,                      # wait for active sem_acquire()s to complete
    ],
    INITSET => [
        0, MAX_ACQUIRE, 0,                              # initialize the semaphore to MAX_ACQUIRE
    ],
    INITDONE => [
        1, 1, SEM_UNDO,                                 # increment SYSVSEM_USAGE to prevent PHP from resetting SYSVSEM_SEM
        0, MAX_ACQUIRE, SEM_UNDO,                       # initialize SYSVSEM_SEM to MAX_ACQUIRE
        2, -1, SEM_UNDO,                                # decrement SYSVSEM_SETVAL to allow sem_get()s to run
    ],
    LOCK => [
        0, -MAX_ACQUIRE, SEM_UNDO,                      # Attempt to lock, readers will block
    ],
    UNLOCK => [
        0, MAX_ACQUIRE, ( SEM_UNDO | IPC_NOWAIT ),      # Release lock, resetting semaphore and allowing readers access
    ],
};

foreach my $key( keys %$SEMOP_ARGS )
{
    $SEMOP_ARGS->{$key} = pack( $pack_mod, @{$SEMOP_ARGS->{$key}} );
}
```

Sets up a data structure that we use to pass arguments to `semop()`. It does this initially in a human readable form, and then packs it into a binary form that `semop()` can use. Note that the arrays may contain multiple operations. Remember that each operation consists of three parts:
1. Semaphore number
2. Operation
3. Flags

For example, the INITSTART member of this structure will:
1. Wait for semaphore 2 (`SYSVSEM_SETVAL`) to be 0 with no flags.
2. Increment semaphore 2 (`SYSVSEM_SETVAL`) by 1 once the above has been satisfied.

```perl
my $semid = semget( SEMAPHORE_KEY, 3, SEM_PERM | SEM_FLAG );

unless( $semid )
{
    die( "Failed to create semaphore: $!" );
}

# perform initial locking
semop( $semid, $SEMOP_ARGS->{INITSTART} );

# Get the value of SYSVSEM_SEM
my $val = semctl( $semid, 0, GETVAL, 0 );

if( $val == 0 )
{
    #initialize the semaphore to MAX_ACQUIRE if PHP hasn't done it yet.
    semop( $semid, $SEMOP_ARGS->{INITSET} );
}

# Validate that we can decrement SYSVSEM_SEM to 0 ( I.E. It's properly initialized to MAX_ACQUIRE )
# This also waits for all readers to sem_release()
unless( semop( $semid, $SEMOP_ARGS->{INITCHECK} ) )
{
    die( "Invalid initial state for SYSVSEM_SEM" );
}

# SYSVSEM_SEM is 0 and we have locks, lets reset is, release SYSVSEM_SETVAL and increment SYSVSEM_USAGE
# to prevent PHP from resetting SYSVSEM_SEM on its own
semop( $semid, $SEMOP_ARGS->{INITDONE} );
```

The above is the initialization code for a PHP semaphore set for our use case. Here we:
1. Lock out `sem_get()`
2. Set `SYSVSEM_SEM` to `MAX_ACQUIRE` depending on whether PHP has already initialized the semaphore
3. Verify that there are no other `sem_acquire()`s outstanding by waiting on a decrement
4. Re-set `SYSVSEM_SEM` to `MAX_ACQUIRE`, then release `SYSVSEM_SETVAL` and increment `SYSVSEM_USAGE`

Now, when we execute the following code:
```perl
semop( $sem_id, $SEMOP_ARGS->{LOCK} );
```

This will wait for all `sem_acquire()`s operations to finish prior to setting `SYSVSEM_SEM` to zero. This has the added benefit of blocking readers in the same operation. Unlocking is the opposite - we increment / reset the semaphore to a value of `MAX_ACQUIRE` with `SEM_UNDO` and `IPC_NOWAIT` as flags.

