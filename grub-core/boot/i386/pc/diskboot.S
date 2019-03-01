/*
 *  GRUB  --  GRand Unified Bootloader
 *  Copyright (C) 1999,2000,2001,2002,2006,2007,2009,2010   Free Software Foundation, Inc.
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

#define MSG(x)	movw $x, %si; call LOCAL(message)

	.file	"diskboot.S"

	.text

	/* Tell GAS to generate 16-bit instructions so that this code works
	   in real mode. */
	.code16

	.globl	start, _start
start:
_start:
	/*
	 * _start is loaded at 0x8000 and is jumped to with
	 * CS:IP 0:0x8000 in kernel.
	 */

	/*
	 * we continue to use the stack for boot.img and assume that
	 * some registers are set to correct values. See boot.S
	 * for more information.
	 */

	/* save drive reference first thing! */
	pushw	%dx

	/* print a notification message on the screen */
	pushw	%si		/* %si对应boot.S中disk_address_packet处的地址 */
	MSG(notification_string)
	popw	%si

	/* this sets up for the first run through "bootloop" */
	movw	$LOCAL(firstlist), %di	/* $LOCAL(firstlist)的地址赋给%di */

	/* save the sector number of the second sector in %ebp */
	movl	(%di), %ebp				/* %di指向的内存的内容（4字节）赋值给%ebp，结果%ebp=0x00 00 00 02，即从哪个扇区开始读core.img */

        /* this is the loop for reading the rest of the kernel in */
LOCAL(bootloop):	/* 进入外层循环LOCAL(bootloop)，外层循环每次遍历一个first list项。 */

	/* check the number of sectors to read */
	cmpw	$0, 8(%di)		/* 8(%di)对应上面的blocklist_default_len，也即即将读取的扇区数，该值0会在生成该段程序时改写成正确的数值。因为后面循环会递减该值，如果该值等于0，表示将硬盘的所有数据搬到了内存中，此时跳转到LOCAL(bootit)中。 */

	/* if zero, go to the start function */
	je	LOCAL(bootit)

LOCAL(setup_sectors): 		/* 然后进入内层循环，int 0x13中断读取硬盘一次最大只能读取0x7f个扇区，因此需要循环读取。  */
	/* check if we use LBA or CHS */
	cmpb	$0, -1(%si)			/* 首先从boot.S的mode地址处（-1(%si)）获得硬盘的模式，如果为0，表示为CHS模式，跳转到LOCAL(chs_mode)，否则继续执行。 */

	/* use CHS if zero, LBA otherwise */
	je	LOCAL(chs_mode)

	/* load logical sector start */
	movl	(%di), %ebx			/* 把blocklist_default_start的高低位各4个字节保存在ebx和ecx寄存器中。表示硬盘LBA模式下扇区的逻辑起始地址，默认值为0x2，即第3个扇区。 */
	movl	4(%di), %ecx

	/* the maximum is limited to 0x7f because of Phoenix EDD */
	xorl	%eax, %eax
	movb	$0x7f, %al			/* 接着将al寄存器赋值0x7f，表示每次拷贝最大的扇区数，8(%di)表示剩余多少扇区没有拷贝，如果8(%di)小于al，则表示将要进行最后一次拷贝，此时将8(%di)赋值给al。 */

	/* how many do we really want to read? */
	cmpw	%ax, 8(%di)	/* compare against total number of sectors */

	/* which is greater? */
	jg	1f

	/* if less than, set to total */
	movw	8(%di), %ax

1:
	/* subtract from total */
	subw	%ax, 8(%di)			/* 进入标号1，首先将剩余的扇区数8(%di)减去当前即将读出的扇区数al */

	/* add into logical sector start */
	addl	%eax, (%di)			/* 起始扇区数(%di)加上%eax，如果有进位，则需要将进位加到4(%di)中，这三条指令都是为下一次拷贝做准备。 */
	adcl	$0, 4(%di)			/* Integer adds operand1 and the carry flag to operand2 and stores the result in operand2 */

	/* set up disk address packet */

	/* the size and the reserved byte */
	movw	$0x0010, (%si)		/* (%si)指向disk_address_packet , 0x10是数据块的大小*/

	/* the number of sectors */
	movw	%ax, 2(%si)			/* 0x007f是本次传输的扇区数 */

	/* the absolute address */
	movl	%ebx, 8(%si)		/* 8(%si)和12(%si)保存了本次传输的起始扇区数，起始值为0x2 */
	movl	%ecx, 12(%si)

	/* the segment of buffer address */
	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, 6(%si)		/* 6(%si)保存了缓存地址，默认值为GRUB_BOOT_MACHINE_BUFFER_SEG，也即0x7000，和boot.S中的缓存地址一样 */

	/* save %ax from destruction! */
	pushw	%ax			/* 最后将本次读取的扇区数ax入栈 */

	/* the offset of buffer address */
	movw	$0, 4(%si)	/* 将4(%si)清0 */

/*
 * BIOS call "INT 0x13 Function 0x42" to read sectors from disk into memory
 *	Call with	%ah = 0x42
 *			%dl = drive number
 *			%ds:%si = segment:offset of disk address packet
 *	Return:
 *			%al = 0x0 on success; err code on failure
 */

	movb	$0x42, %ah	/* 然后执行int 0x13中断，参数ah为0x42，执行读取。 */
	int	$0x13

	jc	LOCAL(read_error)	/* 如果CF置1，则发生错误，跳转到LOCAL(read_error) */

	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, %bx
	jmp	LOCAL(copy_buffer)

LOCAL(chs_mode):
	/* load logical sector start (top half) */
	movl	4(%di), %eax
	orl	%eax, %eax
	jnz	LOCAL(geometry_error)

	/* load logical sector start (bottom half) */
	movl	(%di), %eax

	/* zero %edx */
	xorl	%edx, %edx

	/* divide by number of sectors */
	divl	(%si)

	/* save sector start */
	movb	%dl, 10(%si)

	xorl	%edx, %edx	/* zero %edx */
	divl	4(%si)		/* divide by number of heads */

	/* save head start */
	movb	%dl, 11(%si)

	/* save cylinder start */
	movw	%ax, 12(%si)

	/* do we need too many cylinders? */
	cmpw	8(%si), %ax
	jge	LOCAL(geometry_error)

	/* determine the maximum sector length of this read */
	movw	(%si), %ax	/* get number of sectors per track/head */

	/* subtract sector start */
	subb	10(%si), %al

	/* how many do we really want to read? */
	cmpw	%ax, 8(%di)	/* compare against total number of sectors */


	/* which is greater? */
	jg	2f

	/* if less than, set to total */
	movw	8(%di), %ax

2:
	/* subtract from total */
	subw	%ax, 8(%di)

	/* add into logical sector start */
	addl	%eax, (%di)
	adcl	$0, 4(%di)

/*
 *  This is the loop for taking care of BIOS geometry translation (ugh!)
 */

	/* get high bits of cylinder */
	movb	13(%si), %dl

	shlb	$6, %dl		/* shift left by 6 bits */
	movb	10(%si), %cl	/* get sector */

	incb	%cl		/* normalize sector (sectors go
					from 1-N, not 0-(N-1) ) */
	orb	%dl, %cl	/* composite together */
	movb	12(%si), %ch	/* sector+hcyl in cl, cylinder in ch */

	/* restore %dx */
	popw	%dx
	pushw	%dx

	/* head number */
	movb	11(%si), %dh

	pushw	%ax	/* save %ax from destruction! */

/*
 * BIOS call "INT 0x13 Function 0x2" to read sectors from disk into memory
 *	Call with	%ah = 0x2
 *			%al = number of sectors
 *			%ch = cylinder
 *			%cl = sector (bits 6-7 are high bits of "cylinder")
 *			%dh = head
 *			%dl = drive (0x80 for hard disk, 0x0 for floppy disk)
 *			%es:%bx = segment:offset of buffer
 *	Return:
 *			%al = 0x0 on success; err code on failure
 */

	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, %bx
	movw	%bx, %es	/* load %es segment with disk buffer */

	xorw	%bx, %bx	/* %bx = 0, put it at 0 in the segment */
	movb	$0x2, %ah	/* function 2 */
	int	$0x13

	jc	LOCAL(read_error)

	/* save source segment */
	movw	%es, %bx

LOCAL(copy_buffer):

	/* load addresses for copy from disk buffer to destination */
	movw	10(%di), %es	/* load destination segment */

	/* restore %ax */
	popw	%ax

	/* determine the next possible destination address (presuming
		512 byte sectors!) */
	shlw	$5, %ax		/* shift %ax five bits to the left */
	addw	%ax, 10(%di)	/* add the corrected value to the destination
				   address for next time */

	/* save addressing regs */
	pusha
	pushw	%ds

	/* get the copy length */
	shlw	$3, %ax
	movw	%ax, %cx

	xorw	%di, %di	/* zero offset of destination addresses */
	xorw	%si, %si	/* zero offset of source addresses */
	movw	%bx, %ds	/* restore the source segment */

	cld		/* sets the copy direction to forward */

	/* perform copy */
	rep		/* sets a repeat */
	movsw		/* this runs the actual copy */

	/* restore addressing regs and print a dot with correct DS
	   (MSG modifies SI, which is saved, and unused AX and BX) */
	popw	%ds
	MSG(notification_step)
	popa

	/* check if finished with this dataset */
	cmpw	$0, 8(%di)
	jne	LOCAL(setup_sectors)

	/* update position to load from */
	subw	$GRUB_BOOT_MACHINE_LIST_SIZE, %di	/* 12 */

	/* jump to bootloop */
	jmp	LOCAL(bootloop)

/* END OF MAIN LOOP */

LOCAL(bootit):
	/* print a newline */
	MSG(notification_done)
	popw	%dx	/* this makes sure %dl is our "boot" drive */
	ljmp	$0, $(GRUB_BOOT_MACHINE_KERNEL_ADDR + 0x200)	/* 0x0:8200 */


/*
 * BIOS Geometry translation error (past the end of the disk geometry!).
 */
LOCAL(geometry_error):
	MSG(geometry_error_string)
	jmp	LOCAL(general_error)

/*
 * Read error on the disk.
 */
LOCAL(read_error):
	MSG(read_error_string)

LOCAL(general_error):
	MSG(general_error_string)

/* go here when you need to stop the machine hard after an error condition */
LOCAL(stop):	jmp	LOCAL(stop)

notification_string:	.asciz "loading"

notification_step:	.asciz "."
notification_done:	.asciz "\r\n"

geometry_error_string:	.asciz "Geom"
read_error_string:	.asciz "Read"
general_error_string:	.asciz " Error"

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

	incw	%si
LOCAL(message):
	movb	(%si), %al
	cmpb	$0, %al
	jne	1b	/* if not end of string, jmp to display */
	ret

/*
 *  This area is an empty space between the main body of code below which
 *  grows up (fixed after compilation, but between releases it may change
 *  in size easily), and the lists of sectors to read, which grows down
 *  from a fixed top location.
 */

	.word 0
	.word 0

	.org 0x200 - GRUB_BOOT_MACHINE_LIST_SIZE	/* 0x200即512，即第二个扇区数据的末尾。GRUB_BOOT_MACHINE_LIST_SIZE为12，表示一个first list项读取参数的字节数，最大一共15个first list项（14个有效），从上面也可以看出4+4+2+2=12。因此LOCAL(firstlist)处的地址就为0x1f4，该地址对应最后一个first list项。 */
LOCAL(firstlist):	/* this label has to be before the first list entry!!! */
        /* fill the first data listing with the default */
blocklist_default_start:
	/* this is the sector start parameter, in logical sectors from
	   the start of the disk, sector 0 */
	.long 2, 0
blocklist_default_len:
	/* this is the number of sectors to read.  grub-mkimage
	   will fill this up */
	.word 0
blocklist_default_seg:
	/* this is the segment of the starting address to load the data into */
	.word (GRUB_BOOT_MACHINE_KERNEL_SEG + 0x20)	/* =0x0820，目标地址：0x8200:0 */
