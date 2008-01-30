#!/usr/bin/env perl

# ====================================================================
# Written by Andy Polyakov <appro@fy.chalmers.se> for the OpenSSL
# project. The module is, however, dual licensed under OpenSSL and
# CRYPTOGAMS licenses depending on where you obtain it. For further
# details see http://www.openssl.org/~appro/cryptogams/.
# ====================================================================

# December 2007

# The reason for undertaken effort is basically following. Even though
# Power 6 CPU operates at incredible 4.7GHz clock frequency, its PKI
# performance was observed to be less than impressive, essentially as
# fast as 1.8GHz PPC970, or 2.6 times(!) slower than one would hope.
# Well, it's not surprising that IBM had to make some sacrifices to
# boost the clock frequency that much, but no overall improvement?
# Having observed how much difference did switching to FPU make on
# UltraSPARC, playing same stunt on Power 6 appeared appropriate...
# Unfortunately the resulting performance improvement is not as
# impressive, ~30%, and in absolute terms is still very far from what
# one would expect from 4.7GHz CPU. There is a chance that I'm doing
# something wrong, but in the lack of assembler level micro-profiling
# data or at least decent platform guide I can't tell... Or better
# results might be achieved with VMX... Anyway, this module provides
# *worse* performance on other PowerPC implementations, ~40-15% slower
# on PPC970 depending on key length and ~40% slower on Power 5 for all
# key lengths. As it's obviously inappropriate as "best all-round"
# alternative, it has to be complemented with run-time CPU family
# detection. Oh! It should also be noted that unlike other PowerPC
# implementation IALU ppc-mont.pl module performs *suboptimaly* on
# >=1024-bit key lengths on Power 6. It should also be noted that
# *everything* said so far applies to 64-bit builds! As far as 32-bit
# application executed on 64-bit CPU goes, this module is likely to
# become preferred choice, because it's easy to adapt it for such
# case and *is* faster than 32-bit ppc-mont.pl on *all* processors.

$output = shift;

if ($output =~ /32\-mont\.s/) {
	$SIZE_T=4;
	$RZONE=	224;
	$FRAME=	$SIZE_T*12+8*12;
	$fname=	"bn_mul_mont_ppc64";

	$STUX=	"stwux";	# store indexed and update
	$PUSH=	"stw";
	$POP=	"lwz";
	die "not implemented yet";
} elsif ($output =~ /64\-mont\.s/) {
	$SIZE_T=8;
	$RZONE=	288;
	$FRAME=	$SIZE_T*12+8*12;
	$fname=	"bn_mul_mont";

	# same as above, but 64-bit mnemonics...
	$STUX=	"stdux";	# store indexed and update
	$PUSH=	"std";
	$POP=	"ld";
} else { die "nonsense $output"; }

( defined shift || open STDOUT,"| $^X ../perlasm/ppc-xlate.pl $output" ) ||
	die "can't call ../perlasm/ppc-xlate.pl: $!";

$FRAME=($FRAME+63)&~63;
$TRANSFER=16*8;

$carry="r0";
$sp="r1";
$toc="r2";
$rp="r3";	$ovf="r3";
$ap="r4";
$bp="r5";
$np="r6";
$n0="r7";
$num="r8";
$rp="r9";	# $rp is reassigned
$tp="r10";
$j="r11";
$i="r12";
# non-volatile registers
$nap_d="r14";	# interleaved ap and np in double format
$a0="r15";	# ap[0]
$t0="r16";	# temporary registers
$t1="r17";
$t2="r18";
$t3="r19";
$t4="r20";
$t5="r21";
$t6="r22";
$t7="r23";

# PPC offers enough register bank capacity to unroll inner loops twice
#
#     ..A3A2A1A0
#           dcba
#    -----------
#            A0a
#           A0b
#          A0c
#         A0d
#          A1a
#         A1b
#        A1c
#       A1d
#        A2a
#       A2b
#      A2c
#     A2d
#      A3a
#     A3b
#    A3c
#   A3d
#    ..a
#   ..b
#
$ba="f0";
$bb="f1";
$bc="f2";
$bd="f3";
$na="f4";
$nb="f5";
$nc="f6";
$nd="f7";
$dota="f8";
$dotb="f9";
$A0="f10";
$A1="f11";
$A2="f12";
$A3="f13";
$N0="f14";
$N1="f15";
$N2="f16";
$N3="f17";
$T0a="f18";
$T0b="f19";
$T1a="f20";
$T1b="f21";
$T2a="f22";
$T2b="f23";
$T3a="f24";
$T3b="f25";

# sp----------->+-------------------------------+
#		| saved sp			|
#		+-------------------------------+
#		|				|
#		+-------------------------------+
#		| 10 saved gpr, r14-r23		|
#		.				.
#		.				.
#   +12*size_t	+-------------------------------+
#		| 12 saved fpr, f14-f25		|
#		.				.
#		.				.
#   +12*8	+-------------------------------+
#		| padding to 64 byte boundary	|
#		.				.
#		+-------------------------------+
#		| 16 gpr<->fpr transfer zone	|
#		.				.
#		.				.
#   +8*8	+-------------------------------+
#		| __int64 tmp[-1]		|
#		+-------------------------------+
#		| __int64 tmp[num]		|
#		.				.
#		.				.
#		.				.
#   +(num+1)*8	+-------------------------------+
#		| padding to 64 byte boundary	|
#		.				.
#		+-------------------------------+
#		| double nap_d[4*num]		|
#		.				.
#		.				.
#		.				.
#		+-------------------------------+

$code=<<___;
.machine "any"
.text

.globl	.$fname
.align	5
.$fname:
	cmpwi	$num,4
	mr	$rp,r3		; $rp is reassigned
	li	r3,0		; possible "not handled" return code
	bltlr-
	andi.	r0,$num,1	; $num has to be even
	bnelr-

	slwi	$num,$num,3	; num*=8
	li	$i,-4096
	slwi	$tp,$num,2	; place for {an}p_{lh}[num], i.e. 4*num
	add	$tp,$tp,$num	; place for tp[num+1]
	addi	$tp,$tp,`$FRAME+$TRANSFER+8+64+$RZONE`
	subf	$tp,$tp,$sp	; $sp-$tp
	and	$tp,$tp,$i	; minimize TLB usage
	subf	$tp,$sp,$tp	; $tp-$sp
	$STUX	$sp,$sp,$tp	; alloca

	$PUSH	r14,`2*$SIZE_T`($sp)
	$PUSH	r15,`3*$SIZE_T`($sp)
	$PUSH	r16,`4*$SIZE_T`($sp)
	$PUSH	r17,`5*$SIZE_T`($sp)
	$PUSH	r18,`6*$SIZE_T`($sp)
	$PUSH	r19,`7*$SIZE_T`($sp)
	$PUSH	r20,`8*$SIZE_T`($sp)
	$PUSH	r21,`9*$SIZE_T`($sp)
	$PUSH	r22,`10*$SIZE_T`($sp)
	$PUSH	r23,`11*$SIZE_T`($sp)
	stfd	f14,`12*$SIZE_T+0`($sp)
	stfd	f15,`12*$SIZE_T+8`($sp)
	stfd	f16,`12*$SIZE_T+16`($sp)
	stfd	f17,`12*$SIZE_T+24`($sp)
	stfd	f18,`12*$SIZE_T+32`($sp)
	stfd	f19,`12*$SIZE_T+40`($sp)
	stfd	f20,`12*$SIZE_T+48`($sp)
	stfd	f21,`12*$SIZE_T+56`($sp)
	stfd	f22,`12*$SIZE_T+64`($sp)
	stfd	f23,`12*$SIZE_T+72`($sp)
	stfd	f24,`12*$SIZE_T+80`($sp)
	stfd	f25,`12*$SIZE_T+88`($sp)

	ld	$a0,0($ap)	; pull ap[0] value
	ld	$n0,0($n0)	; pull n0[0] value
	ld	$t3,0($bp)	; bp[0]

	addi	$tp,$sp,`$FRAME+$TRANSFER+8+64`
	li	$i,-64
	add	$nap_d,$tp,$num
	and	$nap_d,$nap_d,$i	; align to 64 bytes

	mulld	$t7,$a0,$t3	; ap[0]*bp[0]
	; nap_d is off by 1, because it's used with stfdu/lfdu
	addi	$nap_d,$nap_d,-8
	srwi	$j,$num,`3+1`	; counter register, num/2
	mulld	$t7,$t7,$n0	; tp[0]*n0
	addi	$j,$j,-1
	addi	$tp,$sp,`$FRAME+$TRANSFER-8`
	li	$carry,0
	mtctr	$j

	; transfer bp[0] to FPU as 4x16-bit values
	extrdi	$t0,$t3,16,48
	extrdi	$t1,$t3,16,32
	extrdi	$t2,$t3,16,16
	extrdi	$t3,$t3,16,0
	std	$t0,`$FRAME+0`($sp)
	std	$t1,`$FRAME+8`($sp)
	std	$t2,`$FRAME+16`($sp)
	std	$t3,`$FRAME+24`($sp)
	; transfer (ap[0]*bp[0])*n0 to FPU as 4x16-bit values
	extrdi	$t4,$t7,16,48
	extrdi	$t5,$t7,16,32
	extrdi	$t6,$t7,16,16
	extrdi	$t7,$t7,16,0
	std	$t4,`$FRAME+32`($sp)
	std	$t5,`$FRAME+40`($sp)
	std	$t6,`$FRAME+48`($sp)
	std	$t7,`$FRAME+56`($sp)
	lwz	$t0,4($ap)		; load a[j] as 32-bit word pair
	lwz	$t1,0($ap)
	lwz	$t2,4($np)		; load n[j] as 32-bit word pair
	lwz	$t3,0($np)
	lwz	$t4,12($ap)		; load a[j+1] as 32-bit word pair
	lwz	$t5,8($ap)
	lwz	$t6,12($np)		; load n[j+1] as 32-bit word pair
	lwz	$t7,8($np)
	lfd	$ba,`$FRAME+0`($sp)
	lfd	$bb,`$FRAME+8`($sp)
	lfd	$bc,`$FRAME+16`($sp)
	lfd	$bd,`$FRAME+24`($sp)
	lfd	$na,`$FRAME+32`($sp)
	lfd	$nb,`$FRAME+40`($sp)
	lfd	$nc,`$FRAME+48`($sp)
	lfd	$nd,`$FRAME+56`($sp)
	std	$t0,`$FRAME+64`($sp)
	std	$t1,`$FRAME+72`($sp)
	std	$t2,`$FRAME+80`($sp)
	std	$t3,`$FRAME+88`($sp)
	std	$t4,`$FRAME+96`($sp)
	std	$t5,`$FRAME+104`($sp)
	std	$t6,`$FRAME+112`($sp)
	std	$t7,`$FRAME+120`($sp)
	fcfid	$ba,$ba
	fcfid	$bb,$bb
	fcfid	$bc,$bc
	fcfid	$bd,$bd
	fcfid	$na,$na
	fcfid	$nb,$nb
	fcfid	$nc,$nc
	fcfid	$nd,$nd

	lfd	$A0,`$FRAME+64`($sp)
	lfd	$A1,`$FRAME+72`($sp)
	lfd	$N0,`$FRAME+80`($sp)
	lfd	$N1,`$FRAME+88`($sp)
	lfd	$A2,`$FRAME+96`($sp)
	lfd	$A3,`$FRAME+104`($sp)
	lfd	$N2,`$FRAME+112`($sp)
	lfd	$N3,`$FRAME+120`($sp)
	fcfid	$A0,$A0
	fcfid	$A1,$A1
	fcfid	$N0,$N0
	fcfid	$N1,$N1
	fcfid	$A2,$A2
	fcfid	$A3,$A3
	fcfid	$N2,$N2
	fcfid	$N3,$N3
	addi	$ap,$ap,16
	addi	$np,$np,16

	fmul	$T1a,$A1,$ba
	fmul	$T1b,$A1,$bb
	stfd	$A0,8($nap_d)		; save a[j] in double format
	stfd	$A1,16($nap_d)
	fmul	$T2a,$A2,$ba
	fmul	$T2b,$A2,$bb
	stfd	$N0,24($nap_d)		; save n[j] in double format
	stfd	$N1,32($nap_d)
	fmul	$T3a,$A3,$ba
	fmul	$T3b,$A3,$bb
	stfd	$A2,40($nap_d)		; save a[j+1] in double format
	stfd	$A3,48($nap_d)
	fmul	$T0a,$A0,$ba
	fmul	$T0b,$A0,$bb
	stfd	$N2,56($nap_d)		; save n[j+1] in double format
	stfdu	$N3,64($nap_d)

	fmadd	$T1a,$A0,$bc,$T1a
	fmadd	$T1b,$A0,$bd,$T1b
	fmadd	$T2a,$A1,$bc,$T2a
	fmadd	$T2b,$A1,$bd,$T2b
	fmadd	$T3a,$A2,$bc,$T3a
	fmadd	$T3b,$A2,$bd,$T3b
	fmul	$dota,$A3,$bc
	fmul	$dotb,$A3,$bd

	fmadd	$T1a,$N1,$na,$T1a
	fmadd	$T1b,$N1,$nb,$T1b
	fmadd	$T2a,$N2,$na,$T2a
	fmadd	$T2b,$N2,$nb,$T2b
	fmadd	$T3a,$N3,$na,$T3a
	fmadd	$T3b,$N3,$nb,$T3b
	fmadd	$T0a,$N0,$na,$T0a
	fmadd	$T0b,$N0,$nb,$T0b

	fmadd	$T1a,$N0,$nc,$T1a
	fmadd	$T1b,$N0,$nd,$T1b
	fmadd	$T2a,$N1,$nc,$T2a
	fmadd	$T2b,$N1,$nd,$T2b
	fmadd	$T3a,$N2,$nc,$T3a
	fmadd	$T3b,$N2,$nd,$T3b
	fmadd	$dota,$N3,$nc,$dota
	fmadd	$dotb,$N3,$nd,$dotb

	fctid	$T0a,$T0a
	fctid	$T0b,$T0b
	fctid	$T1a,$T1a
	fctid	$T1b,$T1b
	fctid	$T2a,$T2a
	fctid	$T2b,$T2b
	fctid	$T3a,$T3a
	fctid	$T3b,$T3b

	stfd	$T0a,`$FRAME+0`($sp)
	stfd	$T0b,`$FRAME+8`($sp)
	stfd	$T1a,`$FRAME+16`($sp)
	stfd	$T1b,`$FRAME+24`($sp)
	stfd	$T2a,`$FRAME+32`($sp)
	stfd	$T2b,`$FRAME+40`($sp)
	stfd	$T3a,`$FRAME+48`($sp)
	stfd	$T3b,`$FRAME+56`($sp)

.align	5
L1st:
	lwz	$t0,4($ap)		; load a[j] as 32-bit word pair
	lwz	$t1,0($ap)
	lwz	$t2,4($np)		; load n[j] as 32-bit word pair
	lwz	$t3,0($np)
	lwz	$t4,12($ap)		; load a[j+1] as 32-bit word pair
	lwz	$t5,8($ap)
	lwz	$t6,12($np)		; load n[j+1] as 32-bit word pair
	lwz	$t7,8($np)
	std	$t0,`$FRAME+64`($sp)
	std	$t1,`$FRAME+72`($sp)
	std	$t2,`$FRAME+80`($sp)
	std	$t3,`$FRAME+88`($sp)
	std	$t4,`$FRAME+96`($sp)
	std	$t5,`$FRAME+104`($sp)
	std	$t6,`$FRAME+112`($sp)
	std	$t7,`$FRAME+120`($sp)
	ld	$t0,`$FRAME+0`($sp)
	ld	$t1,`$FRAME+8`($sp)
	ld	$t2,`$FRAME+16`($sp)
	ld	$t3,`$FRAME+24`($sp)
	ld	$t4,`$FRAME+32`($sp)
	ld	$t5,`$FRAME+40`($sp)
	ld	$t6,`$FRAME+48`($sp)
	ld	$t7,`$FRAME+56`($sp)
	lfd	$A0,`$FRAME+64`($sp)
	lfd	$A1,`$FRAME+72`($sp)
	lfd	$N0,`$FRAME+80`($sp)
	lfd	$N1,`$FRAME+88`($sp)
	lfd	$A2,`$FRAME+96`($sp)
	lfd	$A3,`$FRAME+104`($sp)
	lfd	$N2,`$FRAME+112`($sp)
	lfd	$N3,`$FRAME+120`($sp)
	fcfid	$A0,$A0
	fcfid	$A1,$A1
	fcfid	$N0,$N0
	fcfid	$N1,$N1
	fcfid	$A2,$A2
	fcfid	$A3,$A3
	fcfid	$N2,$N2
	fcfid	$N3,$N3
	addi	$ap,$ap,16
	addi	$np,$np,16

	fmul	$T1a,$A1,$ba
	fmul	$T1b,$A1,$bb
	stfd	$A0,8($nap_d)		; save a[j] in double format
	stfd	$A1,16($nap_d)
	fmul	$T2a,$A2,$ba
	fmul	$T2b,$A2,$bb
	stfd	$N0,24($nap_d)		; save n[j] in double format
	stfd	$N1,32($nap_d)
	 add	$t0,$t0,$carry		; can not overflow
	fmul	$T3a,$A3,$ba
	fmul	$T3b,$A3,$bb
	stfd	$A2,40($nap_d)		; save a[j+1] in double format
	stfd	$A3,48($nap_d)
	fmadd	$T0a,$A0,$ba,$dota
	fmadd	$T0b,$A0,$bb,$dotb
	stfd	$N2,56($nap_d)		; save n[j+1] in double format
	stfdu	$N3,64($nap_d)
	 srdi	$carry,$t0,16

	 add	$t1,$t1,$carry
	fmadd	$T1a,$A0,$bc,$T1a
	fmadd	$T1b,$A0,$bd,$T1b
	fmadd	$T2a,$A1,$bc,$T2a
	fmadd	$T2b,$A1,$bd,$T2b
	 srdi	$carry,$t1,16
	 insrdi	$t0,$t1,16,32
	fmadd	$T3a,$A2,$bc,$T3a
	fmadd	$T3b,$A2,$bd,$T3b
	fmul	$dota,$A3,$bc
	fmul	$dotb,$A3,$bd
	 add	$t2,$t2,$carry

	 srdi	$carry,$t2,16
	 insrdi	$t0,$t2,16,16
	fmadd	$T1a,$N1,$na,$T1a
	fmadd	$T1b,$N1,$nb,$T1b
	fmadd	$T2a,$N2,$na,$T2a
	fmadd	$T2b,$N2,$nb,$T2b
	 add	$t3,$t3,$carry
	fmadd	$T3a,$N3,$na,$T3a
	fmadd	$T3b,$N3,$nb,$T3b
	fmadd	$T0a,$N0,$na,$T0a
	fmadd	$T0b,$N0,$nb,$T0b
	 srdi	$carry,$t3,16
	 insrdi	$t0,$t3,16,0		; 0..63 bits

	 add	$t4,$t4,$carry
	fmadd	$T1a,$N0,$nc,$T1a
	fmadd	$T1b,$N0,$nd,$T1b
	fmadd	$T2a,$N1,$nc,$T2a
	fmadd	$T2b,$N1,$nd,$T2b
	 srdi	$carry,$t4,16
	fmadd	$T3a,$N2,$nc,$T3a
	fmadd	$T3b,$N2,$nd,$T3b
	fmadd	$dota,$N3,$nc,$dota
	fmadd	$dotb,$N3,$nd,$dotb
	 add	$t5,$t5,$carry

	 srdi	$carry,$t5,16
	 insrdi	$t4,$t5,16,32
	fctid	$T0a,$T0a
	fctid	$T0b,$T0b
	 add	$t6,$t6,$carry
	fctid	$T1a,$T1a
	fctid	$T1b,$T1b
	 srdi	$carry,$t6,16
	 insrdi	$t4,$t6,16,16
	fctid	$T2a,$T2a
	fctid	$T2b,$T2b
	 add	$t7,$t7,$carry
	fctid	$T3a,$T3a
	fctid	$T3b,$T3b
	 insrdi	$t4,$t7,16,0		; 64..127 bits
	 srdi	$carry,$t7,16		; upper 33 bits

	stfd	$T0a,`$FRAME+0`($sp)
	stfd	$T0b,`$FRAME+8`($sp)
	stfd	$T1a,`$FRAME+16`($sp)
	stfd	$T1b,`$FRAME+24`($sp)
	stfd	$T2a,`$FRAME+32`($sp)
	stfd	$T2b,`$FRAME+40`($sp)
	stfd	$T3a,`$FRAME+48`($sp)
	stfd	$T3b,`$FRAME+56`($sp)
	 std	$t0,8($tp)		; tp[j-1]
	 stdu	$t4,16($tp)		; tp[j]
	bdnz-	L1st

	fctid	$dota,$dota
	fctid	$dotb,$dotb

	ld	$t0,`$FRAME+0`($sp)
	ld	$t1,`$FRAME+8`($sp)
	ld	$t2,`$FRAME+16`($sp)
	ld	$t3,`$FRAME+24`($sp)
	ld	$t4,`$FRAME+32`($sp)
	ld	$t5,`$FRAME+40`($sp)
	ld	$t6,`$FRAME+48`($sp)
	ld	$t7,`$FRAME+56`($sp)
	stfd	$dota,`$FRAME+64`($sp)
	stfd	$dotb,`$FRAME+72`($sp)

	add	$t0,$t0,$carry		; can not overflow
	srdi	$carry,$t0,16
	add	$t1,$t1,$carry
	srdi	$carry,$t1,16
	insrdi	$t0,$t1,16,32
	add	$t2,$t2,$carry
	srdi	$carry,$t2,16
	insrdi	$t0,$t2,16,16
	add	$t3,$t3,$carry
	srdi	$carry,$t3,16
	insrdi	$t0,$t3,16,0		; 0..63 bits
	add	$t4,$t4,$carry
	srdi	$carry,$t4,16
	add	$t5,$t5,$carry
	srdi	$carry,$t5,16
	insrdi	$t4,$t5,16,32
	add	$t6,$t6,$carry
	srdi	$carry,$t6,16
	insrdi	$t4,$t6,16,16
	add	$t7,$t7,$carry
	insrdi	$t4,$t7,16,0		; 64..127 bits
	srdi	$carry,$t7,16		; upper 33 bits
	ld	$t6,`$FRAME+64`($sp)
	ld	$t7,`$FRAME+72`($sp)

	std	$t0,8($tp)		; tp[j-1]
	stdu	$t4,16($tp)		; tp[j]

	add	$t6,$t6,$carry		; can not overflow
	srdi	$carry,$t6,16
	add	$t7,$t7,$carry
	insrdi	$t6,$t7,48,0
	srdi	$ovf,$t7,48
	std	$t6,8($tp)		; tp[num-1]

	slwi	$t7,$num,2
	subf	$nap_d,$t7,$nap_d	; rewind pointer

	li	$i,8			; i=1
.align	5
Louter:
	ldx	$t3,$bp,$i	; bp[i]
	ld	$t6,`$FRAME+$TRANSFER+8`($sp)	; tp[0]
	mulld	$t7,$a0,$t3	; ap[0]*bp[i]

	addi	$tp,$sp,`$FRAME+$TRANSFER`
	add	$t7,$t7,$t6	; ap[0]*bp[i]+tp[0]
	li	$carry,0
	mulld	$t7,$t7,$n0	; tp[0]*n0
	mtctr	$j

	; transfer bp[i] to FPU as 4x16-bit values
	extrdi	$t0,$t3,16,48
	extrdi	$t1,$t3,16,32
	extrdi	$t2,$t3,16,16
	extrdi	$t3,$t3,16,0
	std	$t0,`$FRAME+0`($sp)
	std	$t1,`$FRAME+8`($sp)
	std	$t2,`$FRAME+16`($sp)
	std	$t3,`$FRAME+24`($sp)
	; transfer (ap[0]*bp[i]+tp[0])*n0 to FPU as 4x16-bit values
	extrdi	$t4,$t7,16,48
	extrdi	$t5,$t7,16,32
	extrdi	$t6,$t7,16,16
	extrdi	$t7,$t7,16,0
	std	$t4,`$FRAME+32`($sp)
	std	$t5,`$FRAME+40`($sp)
	std	$t6,`$FRAME+48`($sp)
	std	$t7,`$FRAME+56`($sp)

	lfd	$A0,8($nap_d)		; load a[j] in double format
	lfd	$A1,16($nap_d)
	lfd	$N0,24($nap_d)		; load n[j] in double format
	lfd	$N1,32($nap_d)
	lfd	$A2,40($nap_d)		; load a[j+1] in double format
	lfd	$A3,48($nap_d)
	lfd	$N2,56($nap_d)		; load n[j+1] in double format
	lfdu	$N3,64($nap_d)

	lfd	$ba,`$FRAME+0`($sp)
	lfd	$bb,`$FRAME+8`($sp)
	lfd	$bc,`$FRAME+16`($sp)
	lfd	$bd,`$FRAME+24`($sp)
	lfd	$na,`$FRAME+32`($sp)
	lfd	$nb,`$FRAME+40`($sp)
	lfd	$nc,`$FRAME+48`($sp)
	lfd	$nd,`$FRAME+56`($sp)

	fcfid	$ba,$ba
	fcfid	$bb,$bb
	fcfid	$bc,$bc
	fcfid	$bd,$bd
	fcfid	$na,$na
	fcfid	$nb,$nb
	fcfid	$nc,$nc
	fcfid	$nd,$nd

	fmul	$T1a,$A1,$ba
	fmul	$T1b,$A1,$bb
	fmul	$T2a,$A2,$ba
	fmul	$T2b,$A2,$bb
	fmul	$T3a,$A3,$ba
	fmul	$T3b,$A3,$bb
	fmul	$T0a,$A0,$ba
	fmul	$T0b,$A0,$bb

	fmadd	$T1a,$A0,$bc,$T1a
	fmadd	$T1b,$A0,$bd,$T1b
	fmadd	$T2a,$A1,$bc,$T2a
	fmadd	$T2b,$A1,$bd,$T2b
	fmadd	$T3a,$A2,$bc,$T3a
	fmadd	$T3b,$A2,$bd,$T3b
	fmul	$dota,$A3,$bc
	fmul	$dotb,$A3,$bd

	fmadd	$T1a,$N1,$na,$T1a
	fmadd	$T1b,$N1,$nb,$T1b
	fmadd	$T2a,$N2,$na,$T2a
	fmadd	$T2b,$N2,$nb,$T2b
	fmadd	$T3a,$N3,$na,$T3a
	fmadd	$T3b,$N3,$nb,$T3b
	fmadd	$T0a,$N0,$na,$T0a
	fmadd	$T0b,$N0,$nb,$T0b

	fmadd	$T1a,$N0,$nc,$T1a
	fmadd	$T1b,$N0,$nd,$T1b
	fmadd	$T2a,$N1,$nc,$T2a
	fmadd	$T2b,$N1,$nd,$T2b
	fmadd	$T3a,$N2,$nc,$T3a
	fmadd	$T3b,$N2,$nd,$T3b
	fmadd	$dota,$N3,$nc,$dota
	fmadd	$dotb,$N3,$nd,$dotb

	fctid	$T0a,$T0a
	fctid	$T0b,$T0b
	fctid	$T1a,$T1a
	fctid	$T1b,$T1b
	fctid	$T2a,$T2a
	fctid	$T2b,$T2b
	fctid	$T3a,$T3a
	fctid	$T3b,$T3b

	stfd	$T0a,`$FRAME+0`($sp)
	stfd	$T0b,`$FRAME+8`($sp)
	stfd	$T1a,`$FRAME+16`($sp)
	stfd	$T1b,`$FRAME+24`($sp)
	stfd	$T2a,`$FRAME+32`($sp)
	stfd	$T2b,`$FRAME+40`($sp)
	stfd	$T3a,`$FRAME+48`($sp)
	stfd	$T3b,`$FRAME+56`($sp)

.align	5
Linner:
	lfd	$A0,8($nap_d)		; load a[j] in double format
	lfd	$A1,16($nap_d)
	lfd	$N0,24($nap_d)		; load n[j] in double format
	lfd	$N1,32($nap_d)
	lfd	$A2,40($nap_d)		; load a[j+1] in double format
	lfd	$A3,48($nap_d)
	lfd	$N2,56($nap_d)		; load n[j+1] in double format
	lfdu	$N3,64($nap_d)

	 ld	$t0,`$FRAME+0`($sp)
	 ld	$t1,`$FRAME+8`($sp)
	 ld	$t2,`$FRAME+16`($sp)
	 ld	$t3,`$FRAME+24`($sp)

	fmul	$T1a,$A1,$ba
	fmul	$T1b,$A1,$bb
	 ld	$t4,`$FRAME+32`($sp)
	 ld	$t5,`$FRAME+40`($sp)
	fmul	$T2a,$A2,$ba
	fmul	$T2b,$A2,$bb
	 add	$t0,$t0,$carry		; can not overflow
	fmul	$T3a,$A3,$ba
	fmul	$T3b,$A3,$bb
	 ld	$t6,`$FRAME+48`($sp)
	 ld	$t7,`$FRAME+56`($sp)
	fmadd	$T0a,$A0,$ba,$dota
	fmadd	$T0b,$A0,$bb,$dotb
	 srdi	$carry,$t0,16
	 add	$t1,$t1,$carry
	fmadd	$T1a,$A0,$bc,$T1a
	fmadd	$T1b,$A0,$bd,$T1b
	fmadd	$T2a,$A1,$bc,$T2a
	fmadd	$T2b,$A1,$bd,$T2b
	 srdi	$carry,$t1,16
	 insrdi	$t0,$t1,16,32
	fmadd	$T3a,$A2,$bc,$T3a
	fmadd	$T3b,$A2,$bd,$T3b
	fmul	$dota,$A3,$bc
	fmul	$dotb,$A3,$bd
	 add	$t2,$t2,$carry
	 ldu	$t1,8($tp)		; tp[j]
	 srdi	$carry,$t2,16
	 insrdi	$t0,$t2,16,16
	fmadd	$T1a,$N1,$na,$T1a
	fmadd	$T1b,$N1,$nb,$T1b
	fmadd	$T2a,$N2,$na,$T2a
	fmadd	$T2b,$N2,$nb,$T2b
	 add	$t3,$t3,$carry
	 ldu	$t2,8($tp)		; tp[j+1]
	fmadd	$T3a,$N3,$na,$T3a
	fmadd	$T3b,$N3,$nb,$T3b
	fmadd	$T0a,$N0,$na,$T0a
	fmadd	$T0b,$N0,$nb,$T0b
	 srdi	$carry,$t3,16
	 insrdi	$t0,$t3,16,0		; 0..63 bits
	 add	$t4,$t4,$carry
	fmadd	$T1a,$N0,$nc,$T1a
	fmadd	$T1b,$N0,$nd,$T1b
	fmadd	$T2a,$N1,$nc,$T2a
	fmadd	$T2b,$N1,$nd,$T2b
	 srdi	$carry,$t4,16
	fmadd	$T3a,$N2,$nc,$T3a
	fmadd	$T3b,$N2,$nd,$T3b
	fmadd	$dota,$N3,$nc,$dota
	fmadd	$dotb,$N3,$nd,$dotb
	 add	$t5,$t5,$carry
	 srdi	$carry,$t5,16
	 insrdi	$t4,$t5,16,32
	fctid	$T0a,$T0a
	fctid	$T0b,$T0b
	fctid	$T1a,$T1a
	fctid	$T1b,$T1b
	 add	$t6,$t6,$carry
	fctid	$T2a,$T2a
	fctid	$T2b,$T2b
	 srdi	$carry,$t6,16
	 insrdi	$t4,$t6,16,16
	fctid	$T3a,$T3a
	fctid	$T3b,$T3b

	stfd	$T0a,`$FRAME+0`($sp)
	stfd	$T0b,`$FRAME+8`($sp)
	 add	$t7,$t7,$carry
	 addc	$t3,$t0,$t1
	stfd	$T1a,`$FRAME+16`($sp)
	stfd	$T1b,`$FRAME+24`($sp)
	 insrdi	$t4,$t7,16,0		; 64..127 bits
	 srdi	$carry,$t7,16		; upper 33 bits
	stfd	$T2a,`$FRAME+32`($sp)
	stfd	$T2b,`$FRAME+40`($sp)
	 adde	$t5,$t4,$t2
	stfd	$T3a,`$FRAME+48`($sp)
	stfd	$T3b,`$FRAME+56`($sp)
	 addze	$carry,$carry
	 std	$t3,-16($tp)		; tp[j-1]
	 std	$t5,-8($tp)		; tp[j]
	bdnz-	Linner

	fctid	$dota,$dota
	fctid	$dotb,$dotb
	ld	$t0,`$FRAME+0`($sp)
	ld	$t1,`$FRAME+8`($sp)
	ld	$t2,`$FRAME+16`($sp)
	ld	$t3,`$FRAME+24`($sp)
	ld	$t4,`$FRAME+32`($sp)
	ld	$t5,`$FRAME+40`($sp)
	ld	$t6,`$FRAME+48`($sp)
	ld	$t7,`$FRAME+56`($sp)
	stfd	$dota,`$FRAME+64`($sp)
	stfd	$dotb,`$FRAME+72`($sp)

	add	$t0,$t0,$carry		; can not overflow
	srdi	$carry,$t0,16
	add	$t1,$t1,$carry
	srdi	$carry,$t1,16
	insrdi	$t0,$t1,16,32
	add	$t2,$t2,$carry
	ld	$t1,8($tp)		; tp[j]
	srdi	$carry,$t2,16
	insrdi	$t0,$t2,16,16
	add	$t3,$t3,$carry
	ldu	$t2,16($tp)		; tp[j+1]
	srdi	$carry,$t3,16
	insrdi	$t0,$t3,16,0		; 0..63 bits
	add	$t4,$t4,$carry
	srdi	$carry,$t4,16
	add	$t5,$t5,$carry
	srdi	$carry,$t5,16
	insrdi	$t4,$t5,16,32
	add	$t6,$t6,$carry
	srdi	$carry,$t6,16
	insrdi	$t4,$t6,16,16
	add	$t7,$t7,$carry
	insrdi	$t4,$t7,16,0		; 64..127 bits
	srdi	$carry,$t7,16		; upper 33 bits
	ld	$t6,`$FRAME+64`($sp)
	ld	$t7,`$FRAME+72`($sp)

	addc	$t3,$t0,$t1
	adde	$t5,$t4,$t2
	addze	$carry,$carry

	std	$t3,-16($tp)		; tp[j-1]
	std	$t5,-8($tp)		; tp[j]

	add	$carry,$carry,$ovf	; comsume upmost overflow
	add	$t6,$t6,$carry		; can not overflow
	srdi	$carry,$t6,16
	add	$t7,$t7,$carry
	insrdi	$t6,$t7,48,0
	srdi	$ovf,$t7,48
	std	$t6,0($tp)		; tp[num-1]

	slwi	$t7,$num,2
	addi	$i,$i,8
	subf	$nap_d,$t7,$nap_d	; rewind pointer
	cmpw	$i,$num
	blt-	Louter

	subf	$np,$num,$np	; rewind np
	addi	$j,$j,1		; restore counter
	subfc	$i,$i,$i	; j=0 and "clear" XER[CA]
	addi	$tp,$sp,`$FRAME+$TRANSFER+8`
	addi	$t4,$sp,`$FRAME+$TRANSFER+16`
	addi	$t5,$np,8
	addi	$t6,$rp,8
	mtctr	$j

.align	4
Lsub:	ldx	$t0,$tp,$i
	ldx	$t1,$np,$i
	ldx	$t2,$t4,$i
	ldx	$t3,$t5,$i
	subfe	$t0,$t1,$t0	; tp[j]-np[j]
	subfe	$t2,$t3,$t2	; tp[j+1]-np[j+1]
	stdx	$t0,$rp,$i
	stdx	$t2,$t6,$i
	addi	$i,$i,16
	bdnz-	Lsub

	li	$i,0
	subfe	$ovf,$i,$ovf	; handle upmost overflow bit
	and	$ap,$tp,$ovf
	andc	$np,$rp,$ovf
	or	$ap,$ap,$np	; ap=borrow?tp:rp
	addi	$t7,$ap,8
	mtctr	$j

.align	4
Lcopy:				; copy or in-place refresh
	ldx	$t0,$ap,$i
	ldx	$t1,$t7,$i
	std	$i,8($nap_d)	; zap nap_d
	std	$i,16($nap_d)
	std	$i,24($nap_d)
	std	$i,32($nap_d)
	std	$i,40($nap_d)
	std	$i,48($nap_d)
	std	$i,56($nap_d)
	stdu	$i,64($nap_d)
	stdx	$t0,$rp,$i
	stdx	$t1,$t6,$i
	stdx	$i,$tp,$i	; zap tp at once
	stdx	$i,$t4,$i
	addi	$i,$i,16
	bdnz-	Lcopy

	$POP	r14,`2*$SIZE_T`($sp)
	$POP	r15,`3*$SIZE_T`($sp)
	$POP	r16,`4*$SIZE_T`($sp)
	$POP	r17,`5*$SIZE_T`($sp)
	$POP	r18,`6*$SIZE_T`($sp)
	$POP	r19,`7*$SIZE_T`($sp)
	$POP	r20,`8*$SIZE_T`($sp)
	$POP	r21,`9*$SIZE_T`($sp)
	$POP	r22,`10*$SIZE_T`($sp)
	$POP	r23,`11*$SIZE_T`($sp)
	lfd	f14,`12*$SIZE_T+0`($sp)
	lfd	f15,`12*$SIZE_T+8`($sp)
	lfd	f16,`12*$SIZE_T+16`($sp)
	lfd	f17,`12*$SIZE_T+24`($sp)
	lfd	f18,`12*$SIZE_T+32`($sp)
	lfd	f19,`12*$SIZE_T+40`($sp)
	lfd	f20,`12*$SIZE_T+48`($sp)
	lfd	f21,`12*$SIZE_T+56`($sp)
	lfd	f22,`12*$SIZE_T+64`($sp)
	lfd	f23,`12*$SIZE_T+72`($sp)
	lfd	f24,`12*$SIZE_T+80`($sp)
	lfd	f25,`12*$SIZE_T+88`($sp)
	$POP	$sp,0($sp)
	li	r3,1	; signal "handled"
	blr
	.long	0
.asciz  "Montgomery Multiplication for PPC64, CRYPTOGAMS by <appro\@fy.chalmers.se>"
___

$code =~ s/\`([^\`]*)\`/eval $1/gem;
print $code;
close STDOUT;