Patching an PHP SIGSEGV
=======================

Date: 2019-12-31

Tags: PHP, segmentation fault, debugging

One cold December morning, in 2019, we had a failed job notification along with some scraped error logs. Strange. But after some additional searching, I stumbled across this in the kernel logs:

```
Dec 15 12:34:05 zeus kernel: php[28283]: segfault at 55adc0d19bc0 ip 00007f30f10fdff4 sp 00007ffd71bf9270 error 4 in libc-2.17.so[7f30f1090000+1c3000]
```

Uh Oh. In this writup, we're going to diagnose this error and determine the root cause.

# Anatomy of a Segmentation Fault

A segmentation fault, colloquially segfault or in Linux parlance, SIGSEGV, is a class of program error that occurs when an application attempts to access memory it does not have rights to access. This is typically the result of two modes of action:

- Programmer error: Some flaw or lack of checking in the program results in the program accessing RAM it shouldn't. This includes:
    - NULL pointer dereference - or attempting to access memory address `0x0`
    - Buffer overflow / underflow -  typically caused by not checking iteration bounds or validating assumptions on string length.
    - Use after free - The program has previously released a block of memory to the OS, but then attempted to access that memory again.
    - Stack overflow - The stack space has been exhausted, either from deep recursion or allocation of too many stack-based variabled.
    - Permissions - The program attempted to perform an action on memory that it did not have permission to perform (write on read-only memory, for example).
- Malicious behavior: A third party program or user is attempting to exploit a programmer error to get a priviledged process to do something it shouldn't be doing.
- Solar Flares / Cosmic Rays: A gamma ray flips a bit in memory. In production, this should be at least three bits (Read: use ECC RAM). This is rare but has a non-0 probability. Unless your code is running at high altitudes, in a nuclear cleanup robot, or in space, one of the above points is the likely culprit.

We can decompose the log message from above to gleam more information about the nature of this fault:

- `php[28283]` A process called `php` with pid `28283` generated the fault
- `at 55adc0d19bc0` the address the program was attempting to access when it generated the segmentation fault.
- `ip 00007f30f10fdff4` This is the address of the instruction pointer `ip` at the time of the segmentation fault, IE the instruction that triggered the fault.
- `sp 00007ffd71bf9270` This is the address of the stack pointer `sp` at the time of the fault. This is the value of the `RSP` register.
- `error 4` The type of access violation, listed in `traps.h`. We'll be reviewing these later.
- `in libc-2.17.so` This is the file the instruction pointer was in at the time of the fault.
- `[7f30f1090000+1c3000]` This is what address the file was loaded in at and how large the mapping is.

## Traps.h

```
/*
* Page fault error code bits:
*
*   bit 0 ==     0: no page found       1: protection fault
*   bit 1 ==     0: read access         1: write access
*   bit 2 ==     0: kernel-mode access  1: user-mode access
*   bit 3 ==                            1: use of reserved bit detected
*   bit 4 ==                            1: fault was an instruction fetch
*   bit 5 ==                            1: protection keys block access
*/
enum x86_pf_error_code {
	X86_PF_PROT     =       1 << 0,
	X86_PF_WRITE    =       1 << 1,
	X86_PF_USER     =       1 << 2,
	X86_PF_RSVD     =       1 << 3,
	X86_PF_INSTR    =       1 << 4,
	X86_PF_PK       =       1 << 5,
};
```

Here we can see that our error, 4, is just a simple user-mode access violation. Nothing to gain from here.

# Digging Deeper

Lets further inspect code to determine what was happening at the time of this error. First, let's start with some math:

```
0x7f30f109000 (load address of libc) - 0x7f3f10fdff4 (ip at time of the error) = 0x6dff4
```

Let's remember this address for later. We're going to use this as an offset into the current libc file to determine what function was running. This can be done with:
- objdump (provided by binutils)
- gdb (standalone debugger)

## Objdump

```
[root@zeus ~]# objdump -D -M intel /usr/lib64/libc-2.17.so > /tmp/decomp && grep -B 5 -A 5 '6dff4:' /tmp/decomp

000000000006dff0 <_IO_fclose@@GLIBC_2.2.5>:
   6dff0:	41 54                	push   r12
   6dff2:	55                   	push   rbp
   6dff3:	53                   	push   rbx
   6dff4:	8b 17                	mov    edx,DWORD PTR [rdi] ← HERE
   6dff6:	48 89 fb             	mov    rbx,rdi
   6dff9:	f6 c6 20             	test   dh,0x20
   6dffc:	89 d1                	mov    ecx,edx
   6dffe:	0f 85 84 01 00 00    	jne    6e188 <_IO_fclose@@GLIBC_2.2.5+0x198>
   6e004:	89 d0                	mov    eax,edx
```

## GDB

```
[root@zeus ~]# gdb -batch -ex 'disas 0x6dff4' /usr/lib64/libc-2.17.so
Dump of assembler code for function _IO_new_fclose:
   0x000000000006dff0 <+0>:	push   %r12
   0x000000000006dff2 <+2>:	push   %rbp
   0x000000000006dff3 <+3>:	push   %rbx
   0x000000000006dff4 <+4>:	mov    (%rdi),%edx ← HERE
   0x000000000006dff6 <+6>:	mov    %rdi,%rbx
   0x000000000006dff9 <+9>:	test   $0x20,%dh
   0x000000000006dffc <+12>:	mov    %edx,%ecx
   0x000000000006dffe <+14>:	jne    0x6e188 <_IO_new_fclose+408>
   0x000000000006e004 <+20>:	mov    %edx,%eax
   0x000000000006e006 <+22>:	and    $0x8000,%eax
   0x000000000006e00b <+27>:	jne    0x6e063 <_IO_new_fclose+115>
   ... rest of function body
```

Either way, we've confirmed that the issue occurred when the php process invoked fclose(). But what were the circumstances of this failure? How was fclose being called? How do find where in the PHP source that this error.

Depending on how reliably reproducable the error is, we can take a few routes:

If we can reliably generate this error with a PHP script, the solution is simple: step through the code with a debugger attached (GDB).
If we cannot reliably generate this we can either get a core dump or use something like dtrace.

# Getting a Core Dump

What we want to happen, oddly enough, is:
```
Segmentation fault (core dumped)
```

A core dump is a snapshot of the processes memory space at the time the core was generated. This includes things like the stack, which can be used to determine what functions were running with which arguments at the time of the crash. We will feed this into `gdb` to perform a backtrace. First, we must enable the generation of core dumps:

```
[root@zeus ~]# sysctl -w kernel.core_pattern=/tmp/core-%e.%p.%h.%t
[root@zeus ~]# ulimit -c unlimited
```

Now, the next time the fault occurs, the kernel will generate a core dump and store it in the `/tmp/` directory.

```
[root@zeus ~]# ls -lah /tmp/core*
-rw------- 1 root root 265M Dec 17 14:30 /tmp/core-php.30317.zeus.example.com.157661100
```

Next, order to turn the function addresses within that core dump, we'll need to get a version of PHP with the debug symbols compiled in. This correlates the function addresses to their names as they appear in the C source!

The difference between having and not having debug symbols is:

```
[root@zeus ~]# gdb /usr/bin/php /tmp/core-php.30317.zeus.example.com.157661100
(gdb) bt
#0  0x00007f898aa80ff4 in ?? ()
#1  0x0000562b420466c0 in ?? ()
#2  0x0000000000200000 in ?? ()
#3  0x00007f8963303000 in ?? ()
#4  0x00007f8982e617f7 in ?? ()
#5  0x0000562b3ff78000 in ?? ()
#6  0x0000562b403dc000 in ?? ()
```

and 

```
[root@zeus ~]# gdb /usr/bin/php /tmp/core-php.30317.zeus.example.com.157661100
(gdb) < about 150 lines of loading shared libraries into appropriate addresses >
(gdb) bt
#0  0x00007f898aa80ff4 in _IO_fclose (obj=<optimized out>, is_temp=<optimized out>) at /usr/src/debug/glibc-2.17-c758a686/libio/iofclose.c:38
#1  0x0000562b420466c0 in ?? ()
#2  0x0000000000200000 in spl_dllist_object_get_debug_info (obj=<optimized out>, is_temp=<optimized out>) at /usr/src/debug/php-7.3.13/ext/spl/spl_dllist.c:534
#3  0x00007f8963303000 in ?? ()
#4  0x00007f8982e617f7 in accel_move_code_to_huge_pages (obj=<optimized out>, is_temp=<optimized out>) at /usr/src/debug/php-7.3.13/ext/opcache/ZendAccelerator.c:2815
#5  0x0000562b3ff78000 in ?? ()
#6  0x0000562b403dc000 in ?? ()
```
(SPOILERS: This is an example, I was not able to generate this with gdb)

How do we get this debug information?

- Compile a working version of the program with the `-g` flag
    - This is difficult with PHP and its modular architecture
- Find and install all the debuginfo packages and hope that GDB can figure it out.
    - This, in retrospect, was a waste of time in this case. eu-unstrip of the core resulted in conflicting information.
- Manually analyze the backtrace with a Perl script.

# Back Trace Analysis

The following is a perl script which takes a back trace and attempt to resolve which shared libraries were loaded into the process map at the time of the crash. This requires tools like `objdump` and `eu-unstrip`

```
#!/usr/bin/perl

use warnings;
use strict;

use Getopt::Std;
use Readonly;
use Carp;
use Math::BigInt;

Readonly my $GET_SHLIB_LOAD_ADDR_CMD => "eu-unstrip -n --core=__CORE__ | awk '{ print \$5, \$1 }' | sed 's/+0x/ 0x/'";
Readonly my $GET_GDB_BT          => "gdb -batch -ex \"bt\" /usr/bin/php __CORE__ 2>/dev/null | awk '{ print \$1,\$2 }'";
Readonly my $DECOMP              => "objdump -D -M intel __FILE__";

sub usage(;$)
{
    my( $message ) = @_;

    print "$message\n" if( $message );
    print "Usage:\n$0 -c <core_dump>\n";
    exit 1;
}

our( $opt_c );
usage( "Invalid arguments" ) unless( getopts( 'c:' ) );

my $core_dump = $opt_c;

unless( defined $core_dump and -e $core_dump )
{
    usage( "Invalid core dump" );
}

my $cmd_result;
my $cmd = $GET_SHLIB_LOAD_ADDR_CMD;
$cmd =~ s/__CORE__/$core_dump/;

unless( open( $cmd_result, '-|', $cmd ) )
{
    croak( "Failed to execute command '$GET_SHLIB_LOAD_ADDR_CMD'" );
}

my $shlib_data = {};
while( my $line = <$cmd_result> )
{
    chomp( $line );
    my @data = split( ' ', $line );
    my $library = $data[0];
    my $base_address = Math::BigInt->new( $data[1] );
    my $length       = Math::BigInt->new( $data[2] );
    my $end_address  = $base_address + $length;

    $shlib_data->{$library}->{start} = $base_address;
    $shlib_data->{$library}->{end}   = $end_address;
}

close( $cmd_result );

$cmd = $GET_GDB_BT;
$cmd =~ s/__CORE__/$core_dump/;

unless( open( $cmd_result, '-|', $cmd ) )
{
    croak( "Failed to execute command $GET_GDB_BT" );
}

my $stack_frames = { };

while( my $line = <$cmd_result> )
{
    chomp $line;
    next unless( $line =~ /^#/ );
    my @data = split( ' ', $line );
    my $frameid = $data[0];
    $frameid =~ s/^#//;
    $frameid = int( $frameid );
    $stack_frames->{$frameid} = Math::BigInt->new( $data[1] );
}

close( $cmd );
print "Analyzing BT...\n";
foreach my $frameid( sort { $a <=> $b } keys %$stack_frames )
{
    my $fn_pointer = $stack_frames->{$frameid};

    print "Stack Frame $frameid: " . $fn_pointer->as_hex();
    my $offset = 0;
    my $lib    = '';
    my $libload = 0;
    foreach my $library( keys %$shlib_data )
    {
        if(
                $fn_pointer >= $shlib_data->{$library}->{start}
            and $fn_pointer <= $shlib_data->{$library}->{end}
          )
        {
            $offset  = $fn_pointer - $shlib_data->{$library}->{start};
            $lib     = $library;
            $libload = $shlib_data->{$library}->{start};
            last;
        }
    }

    if( $offset > 0 )
    {
        print " $lib, offset " . $offset->as_hex() . " from " . $libload->as_hex() . "\n";
        $cmd = $DECOMP;
        $cmd =~ s/__FILE__/$lib/;
        unless( open( $cmd_result, '-|', $cmd ) )
        {
            croak( "Failed to open $lib for decompilation" );
        }

        my $fn_header = '';
        my $offset_no_0x = $offset->as_hex();
        $offset_no_0x =~ s/^0x//;
        my $frame_line = '';
        while( my $line = <$cmd_result> )
        {
            chomp( $line );
            if( not $line =~ /^\s+/ )
            {
                $fn_header = $line;
            }
            elsif( $line =~ /^\s+$offset_no_0x/ )
            {
                $frame_line = $line;
                last;
            }
        }

        if( length( $frame_line ) > 0 )
        {
            print "  $fn_header:\n    $frame_line\n";
        }
    }
    else
    {
        print " ??\n";
    }
}

exit 0;
```

Sorry for that long inine script! Now let's see if it can produce anything useful!

```
[root@zeus ~]# debug_core.pl -c /tmp/core-php.30317.zeus.example.com.157661100
Analyzing BT...
Stack Frame 0: 0x7f898aa80ff4 /usr/lib64/libc-2.17.so, offset 0x6dff4 from 0x7f898aa13000
  000000000006dff0 <_IO_fclose@@GLIBC_2.2.5>::
       6dff4:	8b 17                	mov    edx,DWORD PTR [rdi]
Stack Frame 1: 0x562b420466c0 ??
Stack Frame 2: 0x000000200000 ??
Stack Frame 3: 0x7f8963303000 ??
Stack Frame 4: 0x7f8982e617f7 /usr/lib64/php/modules/opcache.so, offset 0x107f7 from 0x7f8982e51000
  000000000000e1d0 <.text>::
       107f7:	48 8b 84 24 38 10 00 	mov    rax,QWORD PTR [rsp+0x1038]
Stack Frame 5: 0x562b3ff78000 ??
Stack Frame 6: 0x562b403dc000 /usr/bin/php, offset 0x464000 from 0x562b3ff78000
  Lies in CU but not present in valid section!
```

Okay, so we've got a little bit more information compared to the all ?? of the backtrace of a non debug compile of PHP.

Now, lets see if we can fill in the blanks with what we've found:

- Stack Frame #5: This is an address not within any loaded library, but it is near the address which PHP was loaded in, so we will make the assumption that this is within the PHP executable.
- Stack Frame #3: This is likely a shared library that we do not know about, or a library loaded by another shared library, given that its address range is near the other shared libraries.
- Stack Frame #2: This is a very odd address. It doesn't lie in kernel space. We'll likely need to investigate this later
- Stack Frame #1: Again, this looks to be near where PHP was loaded in, so we can assume this is part of the PHP executable proper.

We do have a bread crumb though - let's investigate stack frame #4 (opcache.so) to determine what was going on.

# Transition to C

Let's have a look at opcache.so
```
[root@zeus ~]# gdb --batch --ex=’disas 0x107f7’ /usr/lib64/php/modules/opcache.so
Dump of assembler code for function accel_move_code_to_huge_pages:
   0x0000000000010770 <+0>:	push   %r14
   0x0000000000010772 <+2>:	push   %r13
   0x0000000000010774 <+4>:	lea    0x56f43(%rip),%rsi        # 0x676be
   0x000000000001077b <+11>:	push   %r12
   0x000000000001077d <+13>:	push   %rbp
   0x000000000001077e <+14>:	lea    0x507b9(%rip),%rdi        # 0x60f3e
   ... more asm ...
```

Very interesting! Put on your tin-foil hats, as this lines up with another odd address we saw earlier! Remember that strange 0x200000 address from earlier? Well

```
0x200000 = 2097152 = 2 * 1024 * 1024 = 2 MiB
```

Odd. Intel has two options for huge pages: 2 MiB and 1 GiB. We may have found a smoking gun, but let's note what we've found and look at the source.

## Aside: What are Hugepages?

Hugepages are a way to speed up access of blocks of memory by better utilizing space within the CPU's TLB (Translation Lookaside Buffer). The TLB stores the translated virtual address to the physical address in memory. Virtual addresses are the memory layout as-seen by a given process. This allows multiple programs to be run with similar address layouts.

The following lists the page size for x86-based systems:
- 4 KiB for normal pages
- 2 MiB for huge pages
- 1 GiB for huge(r) pages - requires the `PDPE1GB` extension

A larger page size improves the chance that your page address is in the TLB, and thus improves the speed of access to memory. For example, given a system with 256 GiB of RAM, the chance that a given page is in the TLB with 4096 entries is:

- 67108864 4KiB Pages: 0.006% hit chance
- 131072 2Mib Pages: 3.125% hit chance
- 256 1GiB Pages: 100% hit chance.

Obviously, not every program will be using huge pages, but when programs do use huge pages - they're more likely to get a TLB hit and have faster memory access. This also improves performance of other programs by reducing TLB usage.

## Back to the Problem at Hand

Let's take a look at the source for `accel_move_code_to_huge_pages`
```
static void accel_move_code_to_huge_pages(void)
{
        FILE *f;
        long unsigned int huge_page_size = 2 * 1024 * 1024;

        f = fopen("/proc/self/maps", "r");
        if (f) {
                long unsigned int  start, end, offset, inode;
                char perm[5], dev[6], name[MAXPATHLEN];
                int ret;

                ret = fscanf(f, "%lx-%lx %4s %lx %5s %ld %s\n", &start, &end, perm, &offset, dev, &inode, name);
                if (ret == 7 && perm[0] == 'r' && perm[1] == '-' && perm[2] == 'x' && name[0] == '/') {
                        long unsigned int  seg_start = ZEND_MM_ALIGNED_SIZE_EX(start, huge_page_size);
                        long unsigned int  seg_end = (end & ~(huge_page_size-1L));

                        if (seg_end > seg_start) {
                                zend_accel_error(ACCEL_LOG_DEBUG, "remap to huge page %lx-%lx %s \n", seg_start, seg_end, name);
                                accel_remap_huge_pages((void*)seg_start, seg_end - seg_start, name, offset + seg_start - start);
                        }
                }
                fclose(f);
        }
}
```

Okay, some interesting things to note:
- There's an `fclose()` call within this function.
- The code assumes that we're using 2MiB hugepages. (NEAT!)

Let's take a look at the system configuration:

```
[root@zeus ~]# hugeadm --pool-list
      Size  Minimum  Current  Maximum  Default
1073741824      264      264      264        *
[root@zeus /]# grep HugePages /proc/meminfo
AnonHugePages:      2048 kB
HugePages_Total:     264
HugePages_Free:        0
HugePages_Rsvd:        0
HugePages_Surp:        0
```

Alright, so the system is configured to use 1GiB hugepages. Let's see what `accel_remap_huge_pages` does:

```
static int accel_remap_huge_pages(void *start, size_t size, const char *name, size_t offset)
{
        void *ret = MAP_FAILED;
        void *mem;

        mem = mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
        if (mem == MAP_FAILED) {
                zend_error(E_WARNING,ACCELERATOR_PRODUCT_NAME " huge_code_pages: mmap failed: %s (%d)",strerror(errno), errno);
                return -1;
        }
        memcpy(mem, start, size);

        ret = mmap(start, size,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED|MAP_HUGETLB,-1,0);

        if (ret == MAP_FAILED) {
                ret = mmap(start, size,PROT_READ | PROT_WRITE | PROT_EXEC,MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,-1, 0);
                /* this should never happen? */
                ZEND_ASSERT(ret != MAP_FAILED);

                memcpy(start, mem, size);
                mprotect(start, size, PROT_READ | PROT_EXEC);
                munmap(mem, size);
                zend_error(E_WARNING,ACCELERATOR_PRODUCT_NAME " huge_code_pages: mmap(HUGETLB) failed: %s (%d)",strerror(errno), errno);
                return -1;
        }

        if (ret == start) {
                memcpy(start, mem, size);
                mprotect(start, size, PROT_READ | PROT_EXEC);
        }
        munmap(mem, size);

        return (ret == start) ? 0 : -1;
}
```

Interesting! It calls mmap with the `MAP_HUGETLB` flag, with the size specified in `accel_move_code_to_hugepages`.

Lets take a step back and see what these functions are doing:

- Open `/proc/self/maps` to read where the PHP executable is currently loaded.
- If we find the PHP executable, calculte the start and end of the address range we would like to copy
- Call `accel_remap_huge_pages` with these addresses
- Create a generic mmap allocation and copy the code to that address.
- Create a hugepage allocation at the old address (the one we just copied from) and copy the code back to the hugepage now at it's original address.

Are there any things that can break here? Yes! We already know that the PHP's assumption of the systems huge page size is incorrect. What can result from this bad assumption?

# The Theory

1. execve() aligns PHP's address space near a 1 GiB page boundary (the random chance)
2. PHP goes to map code to a hugepage from an existing memory segment
3. ZEND calls mmap() with a 1GiB aligned address and a multiple of 2MiB size. 
4. ZEND copies the PHP .text segment to the hugepage, but this mapping it way too large and corrupts the heap
5. ZEND sets `PROD_READ | PROT_EXEC` on the page
6. PHP jumps into its code (now in the huge page)
7. A SIGSEGV occurs on the next heap access.

But how do we prove this? We need to show a couple things can happen:

1. execve() will align PHP near a 1GiB page boundary
2. Zend will align its mmap address to a 1GiB/2MiB boundary address
3. mmap() honors the request.
4. The returned mapping is actually 1GiB in size.
5. The returned page maps over and corrupts the heap.

## Proving the Misalignment

We can prove #1-3 in a single step. We simply need a program that:

- Prints out the program's map from `/proc/<pid>/maps`
- Does an allocation from a .so file so that a crash doesn't immediately happen
    - The executable is likely to be loaded in a low address, where .so files are loaded at higher addresses
    - We can use this to gather information about the mapping and check page alignments
- The program needs to be sufficiently large such that its code segment is over 2MiB in size.
    - This would allow `accel_remap_huge_pages`

For this to happen, specifically when proving #1, it comes fown to chance.

Any given 1GiB region consists of 262144 4KiB pages. And anything in the last 512 pages will get rounded up to the next alignment address (per `ZEND_MM_ALIGNMENT_SIZE_EX`). This means we can expect a 0.195% chance that a randomly selected address in a 1GiB region will align to a 1GiB boundary.

Time for some psuedocode:

Outer Script:
```
for( i = 0; i < 100000; i++ )
    return = system( ./program )
    if( return )
        Success++
end loop
print( success / count * 100 ) // Percentage of calls that the address hit the target range
```

Inner Script:
```
file = open( /proc/self/maps );
fprintf( file, “%lx-lx”, start, end )
1GB_page_boundary = ( start + 1024 * 1024 * 1024 - 1 ) & ~( 1024 * 1024 * 1024 -1 )
2MB_page_boundary = ( start + 1024 * 1024 * 2 - 1 ) & ~( 1024 * 1024 * 2 - 1 )
if( 1GB_page_bounary == 2MB_page_boundary )
    addr = mmap( 1GB_page_boundary, 1024 * 1024 * 4, <rest of PHP args> )
    if( addr == 1GB_page_boundary )
        print “Hit!\n”
        return // we will definitely crash here as we’re returning to garbage
exit
```

Some notes:
- The inner program effectively consisted of the two zend functions from earlier, stripped of the zend_error calls and with macros moved into the compilation unit to accurately reproduce the logic.
- I needed to paste in 82 copies of the Bee Movie script to get the file size adequately large enough.

I've since lost this executable, but needless to say it does work and PHP/mmap logic will allow points #1-3 to happen.

## Proving that mmap will do what you ask

This is straightforward enough. Let's ask for a `MAP_HUGETLB` allocation on a system configured with 1GiB hugepages!

```
uint32_t * data = NULL;
uint32_t   val, i;

data = mmap(
	NULL, 1024 * 1024 * sizeof( uint32_t ), // Ask for 32 MiB
	PROT_READ | PROT_WRITE | PROT_EXEC,
	MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
	-1,
	0
);

if( data == ( uint32_t * ) MAP_FAILED )
	return 1;

for( i = 0; i < 1024 * 1024 * 1024 / 4; i++ ) // Div by 4 since we’re accessing 4 bytes at a time
{
	if( i % ( 1024 * 1024 / 4 ) == 0 )
		printf( "At %lu MiB Boundary\n", i / ( 1024 * 1024 / 4 ) );

	data[i] = data[i] + 1; // Test read & write
}
```

and sure enough...
```
[chris@chris ~]# gcc -g -o t test.c && ./t
...
At 1022 MiB Boundary
At 1023 MiB Boundary
```
We received 1 GiB despite asking for 32 MiB.

## Proving heap corruption can happen

This one is also easy.

```
[root@zeus ~]# gdb /usr/bin/php /var/www/.../offending_php_script.php
```

While that program is loaded but is paused in execution:
```
[root@zeus ~]# cat /proc/17227/maps
555555554000-5555559b8000 r-xp 00000000 08:03 336127021                  /usr/bin/php
555555bb7000-555555c43000 r--p 00463000 08:03 336127021                  /usr/bin/php
555555c43000-555555c45000 rw-p 004ef000 08:03 336127021                  /usr/bin/php
555555c45000-555555eda000 rw-p 00000000 00:00 0                          [heap]
```

Let's calculate the offset from the start address of PHP (0x555555554000) against the start address of the heap (0x555555c45000) while taking into accound the ZEND alignment logic:

```
( 0x555555554000 + 0x200000 - 0x1 ) & ~( 0x200000 - 0x1 )
0x0000555555753FFF & ~0x00000000001FFFFF
0x0000555555753FFF &  0xFFFFFFFFFFE00000
0x0000555555600000
```

and the difference between this aligned address and the heap is:

```
0x0000555555c45000 - 0x0000555555600000 = 0x645000 = 6574080 = (approx) 6.27 * 1024 * 1024 bytes or 6.27 MiB
```

We'd only need to copy 6.27 MiB to start corrupting the heap, but since we're allocating significantly more than that!

# Quick Review

Here's what we know is happening:

1. execve() loads PHP starting in the top 512 4KiB pages of a given 1GiB region in memory
2. System is configured with 1GiB hugepages enabled
3. `accel_move_code_to_hugepages` opens a file to a heap allocated file pointer.
4. `accel_remap_huge_pages` allocates x MiB of a 1 GiB page using mmap.
	a. This page gets mapped over the heap
	b. `PROT_READ` and `PROT_EXEC` get set for this region - VERY BAD!
5. `accel_move_code_to_huge_pages` then moves to `fclose()` which closes a now invalid / trashed file pointer.

# Fixing the Issue

From the mmap manpage (emphasis mine):

```
Huge page (Huge TLB) mappings
	For mappings that employ huge pages, the requirements for the argu-
	ments of mmap() and munmap() differ somewhat from the requirements
	for mappings that use the native system page size.

	For mmap(), offset must be a multiple of the underlying huge page
	size. THE SYSTEM AUTOMATICALLY ALIGNS length TO BE A MULTIPLE OF THE
	UNDERLYING HUGE PAGE SIZE.

	For munmap(), addr and length must both be a multiple of the underly-
	ing huge page size.
```

Okay, to prevent this issue we'll certainly need to determine the system's configured hugepage size, or request explicitly for a 2MiB hugepage so that our assumption (and math) are correct.

The first draft fix is simply:

```
static int accel_remap_huge_pages(void *start, size_t size, const char *name, size_t offset)
{
        void *ret = MAP_FAILED;
        void *mem;

        mem = mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1, 0);
        if (mem == MAP_FAILED) {
            zend_error(E_WARNING,ACCELERATOR_PRODUCT_NAME " huge_code_pages: mmap failed: %s (%d)",strerror(errno), errno);
            return -1;
        }
        memcpy(mem, start, size);

        ret = mmap(start,size,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED|MAP_HUGETLB|MAP_HUGE_2MB,-1, 0);

        if (ret == MAP_FAILED) {
            ret = mmap(start,size,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0);
            ZEND_ASSERT(ret != MAP_FAILED);
            memcpy(start, mem, size);
            mprotect(start, size, PROT_READ | PROT_EXEC);
            munmap(mem, size);
            zend_error(E_WARNING,ACCELERATOR_PRODUCT_NAME " huge_code_pages: mmap(HUGETLB) failed: %s (%d)",strerror(errno), errno);
            return -1;
        }

        if( ret == start ) {
            memcpy(start, mem, size);
            mprotect(start, size, PROT_READ | PROT_EXEC);
        }

        munmap(mem, size);
        return (ret == start) ? 0 : -1;
}
```

All we really added was `MAP_HUGE_2MB`, but the downside is that not all systems / architectures have this set. Let's do this the right way and take a page (ba-dum-tsss) from PostgreSQL:

```
// postgres/src/backend/port/sysv_mem.c, some modifications
static void GetHugePageSize( size_t * hugepagesize, int * mmap_flags )
{
    *hugepagesize = 2 * 1024 * 1024;
    *mmap_flags = MAP_HUGETLB;
    FILE * fp = fopen( “/proc/meminfo”, “r” );
    char buf[128];
    unsigned int size;
    char ch;

    if( fp )
    {
        while( fgets( buf, sizeof( buf ), fp ) )
        {
            if( scanf( buf, “Hugepagesize: %u %c”, &size, &ch ) == 2 )
            {
                if( ch == ‘k’ )
                {
                    *hugepagesize = (size_t) size * 1024;
                    break;
                }
            }
        }
        fclose( fp );
        if( *hugepagesize > 1024 * 1024 * 2 )
        {
            *mmap_flags = *mmap_flags | MAP_HUGE_2MB;
        }
    }
}
```

We can then use this function to set our hugepage size based on the systems configuration.

Since the patch was submitted, 0 movement has occurred.
https://bugs.php.net/bug.php?id=79027

There is also a similar bug submitted.
