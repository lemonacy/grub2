/* -*-Asm-*- */
/*
 *  GRUB  --  GRand Unified Bootloader
 *  Copyright (C) 1999,2000,2001,2002,2005,2006,2007,2008,2009  Free Software Foundation, Inc.
 *
 *  GRUB is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  GRUB is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with GRUB.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <grub/symbol.h>
#include <grub/machine/boot.h>

/*
 *  defines for the code go here
 */

	/* Print message string */
#define MSG(x)	movw $x, %si; call LOCAL(message)
#define ERR(x)	movw $x, %si; jmp LOCAL(error_message)

	.macro floppy
part_start:

LOCAL(probe_values):
	.byte	36, 18, 15, 9, 0

LOCAL(floppy_probe):
	pushw	%dx
/*
 *  Perform floppy probe.
 */
#ifdef __APPLE__
	LOCAL(probe_values_minus_one) = LOCAL(probe_values) - 1
	movw	MACRO_DOLLAR(LOCAL(probe_values_minus_one)), %si
#else
	movw	MACRO_DOLLAR(LOCAL(probe_values)) - 1, %si
#endif

LOCAL(probe_loop):
	/* reset floppy controller INT 13h AH=0 */
	xorw	%ax, %ax
	int	MACRO_DOLLAR(0x13)

	incw	%si
	movb	(%si), %cl

	/* if number of sectors is 0, display error and die */
	testb	%cl, %cl
	jnz	1f

/*
 * Floppy disk probe failure.
 */
	MSG(fd_probe_error_string)
	jmp	LOCAL(general_error)

/* "Floppy" */
fd_probe_error_string:	.asciz "Floppy"

1:
	/* perform read */
	movw	MACRO_DOLLAR(GRUB_BOOT_MACHINE_BUFFER_SEG), %bx
	movw	%bx, %es
	xorw	%bx, %bx
	movw	MACRO_DOLLAR(0x201), %ax
	movb	MACRO_DOLLAR(0), %ch
	movb	MACRO_DOLLAR(0), %dh
	int	MACRO_DOLLAR(0x13)

	/* if error, jump to "LOCAL(probe_loop)" */
	jc	LOCAL(probe_loop)

	/* %cl is already the correct value! */
	movb	MACRO_DOLLAR(1), %dh
	movb	MACRO_DOLLAR(79), %ch

	jmp	LOCAL(final_init)
	.endm

	.macro scratch

	/* scratch space */ /* 此数据结构将会在下面的LOCAL(final_init)中被赋值 */
mode:
	.byte	0	/* 0x00 */
disk_address_packet:
sectors:
	.long	0	/* 0x12 */
heads:
	.long	0	/* 0x02 */
cylinders:
	.word	0	/* 0x50 */	/* 1.44M的软盘容量为：0x200 * 0x50 * 0x12 * 0x02 = 0x16800 = 1474560 */
sector_start:
	.byte	0
head_start:
	.byte	0
cylinder_start:
	.word	0
	/* more space... */
	.endm

	.file	"boot.S"

	.text

	/* Tell GAS to generate 16-bit instructions so that this code works
	   in real mode. */
	.code16

.globl _start, start;
_start:
start:
	/*
	 * _start is loaded at 0x7c00 and is jumped to with CS:IP 0:0x7c00
	 */

	/*
	 * Beginning of the sector is compatible with the FAT/HPFS BIOS
	 * parameter block.
	 */

	jmp	LOCAL(after_BPB)
	nop	/* do I care about this ??? */	/* BPB规定的offset是3，但上面的跳转指令只占2个字节(0xBE63)，故加了一条nop指令(0x90)来占位 */

#ifdef HYBRID_BOOT
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	nop
	nop
	jmp	LOCAL(after_BPB)
#else
	/*
	 * This space is for the BIOS parameter block!!!!  Don't change
	 * the first jump, nor start the code anywhere but right after
	 * this area.
	 */

	.org GRUB_BOOT_MACHINE_BPB_START		/* 0x03 */
	.org 4
#endif
#ifdef HYBRID_BOOT
	floppy
#else
	scratch
#endif

	.org GRUB_BOOT_MACHINE_BPB_END			/* 0x5a */
	/*
	 * End of BIOS parameter block.
	 */

LOCAL(kernel_address):
	.word	GRUB_BOOT_MACHINE_KERNEL_ADDR	/* 0x8000 */

#ifndef HYBRID_BOOT
	.org GRUB_BOOT_MACHINE_KERNEL_SECTOR	/* 0x5c */
LOCAL(kernel_sector):
	.long	1								/* 默认从第2个扇区开始加载kernel，下面LBA读取的时候会用到 */
LOCAL(kernel_sector_high):
	.long	0
#endif

	.org GRUB_BOOT_MACHINE_BOOT_DRIVE		/* 0x64 */
boot_drive:
	.byte 0xff	/* the disk to load kernel from */
			/* 0xff means use the boot drive */

LOCAL(after_BPB):

/* general setup */
	cli		/* we're not safe here! */

        /*
         * This is a workaround for buggy BIOSes which don't pass boot
         * drive correctly. If GRUB is installed into a HDD, check if
         * DL is masked correctly. If not, assume that the BIOS passed
         * a bogus value and set DL to 0x80, since this is the only
         * possible boot drive. If GRUB is installed into a floppy,
         * this does nothing (only jump).
         */
		 /*
		  * dl寄存器被BIOS设置为引导设备号，一般为0x80~0xff，0x80号对应第一个硬盘，0x81对应第二个硬盘...
		  * 如果jmp 3f被改写了，肯定是从0x80号开始的设备启动的（下面的检查也是，都是一些BIOS版本造成的，具体为什么，协议里应该有写，懒着查了），如果不满足，则直接设置为0x80。
		  *	再往下testb 0x70对引导设备号做进一步的检查，将其限制在0x0~0xf以及0x80~0x8f内，如果不在这个范围内，就将其设置为0x80。
		  */
	.org GRUB_BOOT_MACHINE_DRIVE_CHECK
boot_drive_check:
        jmp     3f	/* grub-setup may overwrite this jump */
        testb   $0x80, %dl
        jz      2f
3:
	/* Ignore %dl different from 0-0x0f and 0x80-0x8f.  */
	testb   $0x70, %dl
	jz      1f
2:
        movb    $0x80, %dl
1:
	/*
	 * ljmp to the next instruction because some bogus BIOSes
	 * jump to 07C0:0000 instead of 0000:7C00.
	 */
	ljmp	$0, $real_start

real_start:

	/* set up %ds and %ss as offset from 0 */
	xorw	%ax, %ax
	movw	%ax, %ds
	movw	%ax, %ss

	/* set up the REAL stack */
	movw	$GRUB_BOOT_MACHINE_STACK_SEG, %sp

	sti		/* we're safe again */

	/*
	 *  Check if we have a forced disk reference here
	 *  boot_drive默认值为0xff，如果被改写，表示强制使用某设备引导，将前面计算的dl替换为该设备号（%dl在boot_drive_check被设置为了0x80）。
	 */
	movb   boot_drive, %al
	cmpb	$0xff, %al
	je	1f
	movb	%al, %dl
1:
	/* save drive reference first thing! */
	pushw	%dx		/* 保存dx寄存器到堆栈，也即设备号 */

	/* print a notification message on the screen */
	MSG(notification_string)

	/* set %si to the disk address packet */
	movw	$disk_address_packet, %si	/* 保存disk_address_packet的地址到%si寄存器中，该地址用于保存读取硬盘的参数 */

	/* check if LBA is supported */
	/*
	 * int 0x13中断是计算机在实模式下提供读写磁盘信息的接口，其实是调用了BIOS的代码。
	 * 当中断参数为ah=0x41和bx=0x55aa时，该中断用于检查磁盘拓展模式。
	 * 硬盘有LBA和CHS两种模式，简单说CHS模式支持的硬盘容量较小，并且完全按照硬盘的硬件结构进行读写，LBA模式支持的硬盘容量多达TB级别，因此现在大多都使用LBA模式了。
	 * 当中断返回值CF=1时表示表示硬盘不支持LBA模式，直接跳转到LOCAL(chs_mode)，如果CF=0表示支持LBA，继续检查。
	 * 返回值bx中存储了魔数0xaa55，如果不相等，也直接跳转到LOCAL(chs_mode)。
	 * cx中的值存储了硬盘访问的接口位图，当为偶数时，表示不支持LBA的某些api，此时也跳转到CHS。
	 * 参考：https://blog.csdn.net/conansonic/article/details/78482766
	 */
	movb	$0x41, %ah
	movw	$0x55aa, %bx
	int	$0x13

	/*
	 *  %dl may have been clobbered by INT 13, AH=41H.
	 *  This happens, for example, with AST BIOS 1.04.
	 */
	popw	%dx			/* 此时%dl中仍然保留引导磁盘的驱动器号（即从哪块磁盘引导，0x80表示第一块硬盘） */
	pushw	%dx

	/* use CHS if fails */
	jc	LOCAL(chs_mode)
	cmpw	$0xaa55, %bx
	jne	LOCAL(chs_mode)

	andw	$1, %cx		/* cx中的值存储了硬盘访问的接口位图，当为偶数时，表示不支持LBA的某些api，此时也跳转到CHS。 */
	jz	LOCAL(chs_mode)

LOCAL(lba_mode):
	xorw	%ax, %ax
	movw	%ax, 4(%si)		/* head的低2字节清空为0 */

	incw	%ax
	/* set the mode to non-zero */
	movb	%al, -1(%si)	/* mode = 1 表示LBA模式，如果为0，对应CHS模式 */

	/* the blocks */
	movw	%ax, 2(%si)		/* 将sectors的高两字节2(%si)设置为0x0001，表示传输的扇区数（这里为一个扇区） */

	/* the size and the reserved byte */
	movw	$0x0010, (%si)	/* 将sectors的低两字节(%si)设置为$0x0010，其中高字节0x00为默认值，低字节0x10表示数据块的大小。此时disk_address_packet内存块的值为：10 00 01 00 00 00 */

	/* the absolute address 接下来从cylinders地址开始设置8(%si)和12(%si)，两者一起决定了读取的起始扇区，该值默认为0x1，也即读取第二个扇区。*/
	movl	LOCAL(kernel_sector), %ebx
	movl	%ebx, 8(%si)
	movl	LOCAL(kernel_sector_high), %ebx
	movl	%ebx, 12(%si)

	/* the segment of buffer address */
	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, 6(%si)	/* 0x7000， 此时disk_address_packet内存块的值为：10 00 | 01 00 | 00 00 | 00 70 | 01 00 00 00 | 00 00 00 00 */

/*
 * BIOS call "INT 0x13 Function 0x42" to read sectors from disk into memory
 *	Call with	%ah = 0x42
 *			%dl = drive number (%dl磁盘驱动器号0x80，由上面一直保留下来)
 *			%ds:%si = segment:offset of disk address packet	(%si指向的disk_address_packet上面刚刚设置完10 00 | 01 00 | 00 00 | 00 70 | 01 00 00 00 | 00 00 00 00)
 *	Return:
 *			%al = 0x0 on success; err code on failure
 */

	movb	$0x42, %ah	/* 执行int 0x13中断，参数0x42表示通过LBA模式从硬盘读取数据。如果返回标志位cf=1，则不支持LBA读，此时跳转到CHS模式LOCAL(chs_mode)。 */
	int	$0x13

	/* LBA read is not supported, so fallback to CHS.  */
	jc	LOCAL(chs_mode)

	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, %bx	/* 指定缓冲区的位置，接下来的copy_buffer会从这个位置复制 */
	jmp	LOCAL(copy_buffer)

LOCAL(chs_mode):
	/*
	 *  Determine the hard disk geometry from the BIOS!
	 *  We do this first, so that LS-120 IDE floppies work correctly.
	 */
	/*
		ah: 08h - 读取磁盘驱动器的参数
		参数：
		dl - 驱动器号（如果是硬盘则位7要置位为1）
		返回值：
		ah = 0， al = 0
		bl - 驱动器类型（AT/PS2）
		ch - 最大磁道号的低8位
		cl - 每磁道最大扇区数（位0-5）,最大磁道号高2位（位6-7）
		dh - 最大磁头数
		dl - 驱动器数量
		es:di -> 软驱磁盘参数表
		如果出错则CF标志置位，ah中是出错码
	 */
	movb	$8, %ah
	int	$0x13		/* 读取磁盘驱动器的参数 */
	jnc	LOCAL(final_init)

	popw	%dx
	/*
	 *  The call failed, so maybe use the floppy probe instead.
	 */
	testb	%dl, %dl
	jnb	LOCAL(floppy_probe)	/* 如果上面读取磁盘参数失败，则尝试去读取软盘。floppy_probe是通过macro的方式定义在MBR的磁盘分区表(64字节)的位置 */

	/* Nope, we definitely have a hard disk, and we're screwed. */
	ERR(hd_probe_error_string)

LOCAL(final_init):
	/* set the mode to zero */
	movzbl	%dh, %eax	/* dh-最大磁头号(=0x1)，这里把最大磁头数复制给%eax的同时清空了%ah，以便接下来的语句给mode赋值0，真是惜字节如金呀！ */
	movb	%ah, -1(%si)

	/* save number of heads */
	incw	%ax			/* 磁头数个数从1开始计数，故最大磁头号+1 */
	movl	%eax, 4(%si)

	movzbw	%cl, %dx	/* %cl-每磁道最大扇区数（位0-5）(=0x12)，最大磁道号高2位（位6-7） */
	shlw	$2, %dx		/* 处理高2bits，%dh位0位1保留了最大磁道号的高2位 */
	movb	%ch, %al	/* %ch-最大磁道号的低8位(=0x4f)，高2位在%cl的位6-7*/
	movb	%dh, %ah	/* 把高2位赋值给%ah，这样%ax就是完整的磁道号了 */

	/* save number of cylinders */
	incw	%ax			/* (=0x49+1=0x50) */
	movw	%ax, 8(%si)

	movzbw	%dl, %ax	/* 此时%dl里边存的是每磁道最大扇区数(=0x12) */
	shrb	$2, %al

	/* save number of sectors */
	movl	%eax, (%si)

setup_sectors:
	/* load logical sector start (top half) */
	movl	LOCAL(kernel_sector_high), %eax	/* =0x00 */

	orl	%eax, %eax
	jnz	LOCAL(geometry_error)

	/* load logical sector start (bottom half) */
	movl	LOCAL(kernel_sector), %eax	/* =0x01 */

	/* zero %edx */
	xorl	%edx, %edx

	/* divide by number of sectors */
	divl	(%si)		/* 0x01 / 0x12 = 0x00*/

	/* save sector start */
	movb	%dl, %cl	/* %dl = 0x01（余数），eax商 */

	xorw	%dx, %dx	/* zero %edx */
	divl	4(%si)		/* divide by number of heads */

	/* do we need too many cylinders? */
	cmpw	8(%si), %ax
	jge	LOCAL(geometry_error)

	/* normalize sector start (1-based) */
	incb	%cl

	/* low bits of cylinder start */
	movb	%al, %ch

	/* high bits of cylinder start */
	xorb	%al, %al
	shrw	$2, %ax
	orb	%al, %cl

	/* save head start */
	movb	%dl, %al

	/* restore %dl */
	popw	%dx

	/* head start */
	movb	%al, %dh

/*
 * BIOS call "INT 0x13 Function 0x2" to read sectors from disk into memory
 *	Call with	%ah = 0x2
 *			%al = number of sectors
 *			%ch = cylinder
 *			%cl = sector (bits 6-7 are high bits of "cylinder")
 *			%dh = head
 *			%dl = drive (0x80 for hard disk, 0x0 for floppy disk)
 *			%es:%bx = segment:offset of buffer 0x7000:0
 *	Return:
 *			%al = 0x0 on success; err code on failure
 */

	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, %bx	/* =0x7000 */
	movw	%bx, %es	/* load %es segment with disk buffer */

	xorw	%bx, %bx	/* %bx = 0, put it at 0 in the segment */
	movw	$0x0201, %ax	/* function 2 */	/*%ah=0x02 读磁盘扇区到内存*/
	int	$0x13

	jc	LOCAL(read_error)

	movw	%es, %bx

LOCAL(copy_buffer):	/* 这段代码就是将0x7000:0x0000地址处的代码搬运256个字（512字节）到 0x0000:0x8000地址上去。 */
	/*
	 * We need to save %cx and %si because the startup code in
	 * kernel uses them without initializing them.
	 */
	pusha
	pushw	%ds

	movw	$0x100, %cx		/* 256 */
	movw	%bx, %ds		/* %bx在跳转到copy_buffer之前就设置为了0x7000 */
	xorw	%si, %si		/* 设置完了%ds:%si=0x7000:0 */
	movw	$GRUB_BOOT_MACHINE_KERNEL_ADDR, %di		/* =0x8000 */
	movw	%si, %es		/* 设置完了%es:%di=0x0:8000，所以实际上是从0x70000(448k)->0x8000(32k)，移动距离还是挺远的 */

	cld						/* 清方向，movsw往内存高地址移动 */

	rep
	movsw

	popw	%ds
	popa

	/* boot kernel */
	jmp	*(LOCAL(kernel_address))	/* 短跳转到(CS):0x8000开始执行加载的第二个扇区 */

/* END OF MAIN LOOP */

/*
 * BIOS Geometry translation error (past the end of the disk geometry!).
 */
LOCAL(geometry_error):
	ERR(geometry_error_string)

/*
 * Read error on the disk.
 */
LOCAL(read_error):
	movw	$read_error_string, %si
LOCAL(error_message):
	call	LOCAL(message)
LOCAL(general_error):
	MSG(general_error_string)

/* go here when you need to stop the machine hard after an error condition */
        /* tell the BIOS a boot failure, which may result in no effect */
        int	$0x18
LOCAL(stop):
	jmp	LOCAL(stop)

notification_string:	.asciz "GRUB "
geometry_error_string:	.asciz "Geom"
hd_probe_error_string:	.asciz "Hard Disk"
read_error_string:	.asciz "Read"
general_error_string:	.asciz " Error\r\n"

/*
 * message: write the string pointed to by %si
 *
 *   WARNING: trashes %si, %ax, and %bx
 */

	/*
	 * Use BIOS "int 10H Function 0Eh" to write character in teletype mode
	 *	%ah = 0xe	%al = character
	 *	%bh = page	%bl = foreground color (graphics modes)
	 */
1:
	movw	$0x0001, %bx
	movb	$0xe, %ah
	int	$0x10		/* display a byte */
LOCAL(message):
	lodsb
	cmpb	$0, %al
	jne	1b	/* if not end of string, jmp to display */
	ret

	/*
	 *  Windows NT breaks compatibility by embedding a magic
	 *  number here.
	 */

#ifdef HYBRID_BOOT
	.org 0x1b0
LOCAL(kernel_sector):
	.long	1
LOCAL(kernel_sector_high):
	.long	0
#endif
	.org GRUB_BOOT_MACHINE_WINDOWS_NT_MAGIC
nt_magic:
	.long 0
	.word 0

	/*
	 *  This is where an MBR would go if on a hard disk.  The code
	 *  here isn't even referenced unless we're on a floppy.  Kinda
	 *  sneaky, huh?
	*/

	.org GRUB_BOOT_MACHINE_PART_START

#ifndef HYBRID_BOOT
	floppy
#else
	scratch
#endif

	.org GRUB_BOOT_MACHINE_PART_END

/* the last 2 bytes in the sector 0 contain the signature */
	.word	GRUB_BOOT_MACHINE_SIGNATURE		/* 0xaa55 */
