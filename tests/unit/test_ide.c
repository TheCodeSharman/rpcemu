/*
 * Behaviour tests for the IDE device.
 *
 * These drive the emulated drive purely through its public register interface
 * (ide.h) -- the same registers RISC OS pokes -- and assert on what a guest
 * observes (status/error registers, data read back, the backing file). ide.c
 * is compiled and linked as a separate translation unit (see run.sh), so the
 * tests cannot reach its `static` internals: they test behaviour, not
 * implementation, and survive refactoring of ide.c.
 *
 * Because everything goes through writeide()/readide()/... -- which exist in
 * both the unfixed and fixed ide.c -- every test compiles and runs against
 * either. The fixes turn failing (or crashing) behaviour into passing: the
 * suite is uniformly red on `base`, green with feature/ide-fix. No test needs
 * to be #ifdef'd out.
 *
 * Run from an integration checkout (where src/ide.c carries the fix):
 *   tests/unit/run.sh
 */

#include <criterion/criterion.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#include "rpcemu.h"   /* Config */
#include "iomd.h"     /* struct iomd */
#include "ide.h"      /* unit under test */

/* --- ATA registers & bits, from the guest's point of view (the ATA spec) --- */
#define R_ERROR    0x1F1
#define R_SECCOUNT 0x1F2
#define R_LBA0     0x1F3
#define R_LBA8     0x1F4
#define R_LBA16    0x1F5
#define R_DEVHEAD  0x1F6
#define R_CMD      0x1F7   /* write: command; read: status */
#define R_DEVCTL   0x3F6

#define ST_ERR 0x01
#define ST_DRQ 0x08
#define ST_RDY 0x40
#define ST_BSY 0x80

#define ERR_ABRT 0x04
#define ERR_IDNF 0x10

#define CMD_NOP      0x00
#define CMD_READ     0x20
#define CMD_WRITE    0x30
#define CMD_IDENTIFY 0xEC

/* --- the hardware the ide module leans on, stubbed out --- */
Config config;
struct iomd iomd;
void updateirqs(void) { }
void rpclog(const char *format, ...) { (void) format; }
void error(const char *format, ...) { (void) format; }
void fatal(const char *format, ...) { (void) format; abort(); }
void arm_dump(void) { }

static char datadir[512];
const char *rpcemu_get_datadir(void) { return datadir; }

/* ------------------------------------------------------------------ *
 * A temp disc image, attached via the module's own resetide().
 * ------------------------------------------------------------------ */
static char disc_dir[256];
static char disc_hd4[300];

/*
 * Create <tmp>/hd4.hdf with `data_sectors` usable sectors filled with `fill`,
 * then attach it via resetide() (which opens "hd4.hdf" from the data dir).
 *
 * If boot_block, plant the RISC OS geometry marker at offset 0xFC0 so the
 * emulator treats sector 0 as a 512-byte boot block ("skip512"): logical
 * sector N then maps to file sector N+1. Otherwise the geometry bytes are
 * cleared so no boot block is detected (logical N == file N).
 */
static void disc_make(long data_sectors, int boot_block, uint8_t fill)
{
	strcpy(disc_dir, "/tmp/ide_bbox_XXXXXX");
	cr_assert_not_null(mkdtemp(disc_dir));
	snprintf(datadir, sizeof datadir, "%s/", disc_dir);
	snprintf(disc_hd4, sizeof disc_hd4, "%s/hd4.hdf", disc_dir);

	long bytes = (data_sectors + (boot_block ? 1 : 0)) * 512;
	if (bytes < 0x2000) {
		bytes = 0x2000;   /* ensure the 0xFC0 geometry region exists */
	}
	uint8_t *img = malloc((size_t) bytes);
	cr_assert_not_null(img);
	memset(img, fill, (size_t) bytes);
	if (boot_block) {
		img[0xFC0] = 9; img[0xFC1] = 63; img[0xFC2] = 16;  /* log2sec, spt, hpc */
	} else {
		img[0xFC0] = img[0xFC1] = img[0xFC2] = 0;
		img[0xDC0] = img[0xDC1] = img[0xDC2] = 0;
	}

	FILE *f = fopen(disc_hd4, "wb+");
	cr_assert_not_null(f);
	cr_assert_eq(fwrite(img, 1, (size_t) bytes, f), (size_t) bytes);
	fclose(f);
	free(img);

	resetide();   /* attaches hd4.hdf (drive 0); creates an empty hd5.hdf */
}

static void disc_teardown(void)
{
	char p[400];
	snprintf(p, sizeof p, "%s/hd4.hdf", disc_dir); unlink(p);
	snprintf(p, sizeof p, "%s/hd5.hdf", disc_dir); unlink(p);
	rmdir(disc_dir);
}

/* Byte offset of a logical sector within the backing file (accounts for skip512). */
static long disc_file_offset(long lba, int boot_block)
{
	return (lba + (boot_block ? 1 : 0)) * 512L;
}

/* Write straight into the backing file, then re-attach so the emulator sees it. */
static void disc_poke(long file_offset, const uint8_t *data, int len)
{
	FILE *f = fopen(disc_hd4, "rb+");
	cr_assert_not_null(f);
	cr_assert_eq(fseek(f, file_offset, SEEK_SET), 0);
	cr_assert_eq(fwrite(data, 1, (size_t) len, f), (size_t) len);
	fclose(f);
	resetide();
}

/* Read straight from the backing file (resetide() first, to flush guest writes). */
static void disc_peek(long file_offset, uint8_t *data, int len)
{
	resetide();
	FILE *f = fopen(disc_hd4, "rb");
	cr_assert_not_null(f);
	cr_assert_eq(fseek(f, file_offset, SEEK_SET), 0);
	cr_assert_eq(fread(data, 1, (size_t) len, f), (size_t) len);
	fclose(f);
}

/* ------------------------------------------------------------------ *
 * Driving the ATA register protocol, exactly as a guest driver does.
 * ------------------------------------------------------------------ */
static uint8_t ata_status(void) { return readide(R_CMD); }
static uint8_t ata_error(void)  { return readide(R_ERROR); }

static void ata_lba(int drive, uint32_t lba)
{
	writeide(R_DEVHEAD, (uint8_t) (0x40 | (drive << 4) | ((lba >> 24) & 0x0F))); /* LBA mode */
	writeide(R_SECCOUNT, 1);
	writeide(R_LBA0,  (uint8_t) (lba        & 0xFF));
	writeide(R_LBA8,  (uint8_t) ((lba >> 8)  & 0xFF));
	writeide(R_LBA16, (uint8_t) ((lba >> 16) & 0xFF));
}

static void ata_identify(int drive, uint16_t out[256])
{
	writeide(R_DEVHEAD, (uint8_t) (0xA0 | (drive << 4)));
	writeide(R_CMD, CMD_IDENTIFY);
	callbackide();
	for (int i = 0; i < 256; i++) {
		out[i] = readidew();
	}
}

/* Returns 1 on success, 0 if the drive raised an error (e.g. IDNF). */
static int ata_read_sector(int drive, uint32_t lba, uint8_t out[512])
{
	ata_lba(drive, lba);
	writeide(R_CMD, CMD_READ);
	callbackide();
	if (ata_status() & ST_ERR) {
		return 0;
	}
	for (int i = 0; i < 256; i++) {
		uint16_t w = readidew();
		out[i * 2]     = (uint8_t) (w & 0xFF);
		out[i * 2 + 1] = (uint8_t) (w >> 8);
	}
	return 1;
}

static int ata_write_sector(int drive, uint32_t lba, const uint8_t in[512])
{
	ata_lba(drive, lba);
	writeide(R_CMD, CMD_WRITE);
	for (int i = 0; i < 256; i++) {
		/* the 256th word (512 bytes) triggers the disc write */
		writeidew((uint16_t) (in[i * 2] | (in[i * 2 + 1] << 8)));
	}
	return !(ata_status() & ST_ERR);
}

static void ata_soft_reset(void)
{
	writeide(R_DEVCTL, 0x04);  /* assert SRST */
	writeide(R_DEVCTL, 0x00);  /* release -> the drive runs its power-on diagnostic */
	callbackide();
}

/* =========================== the tests =========================== */

Test(ide, identify_reports_real_geometry_and_28bit_lba, .fini = disc_teardown)
{
	disc_make(4096, 1, 0x00);
	uint16_t id[256];
	ata_identify(0, id);

	uint32_t lba_capacity = id[60] | ((uint32_t) id[61] << 16);
	cr_assert_eq(lba_capacity, 4096,
		"IDENTIFY must report the true 28-bit LBA sector count");
	cr_assert(id[49] & 0x0200,
		"IDENTIFY must set the LBA-supported bit (word 49 bit 9)");
	cr_assert_not(id[83] & (1 << 10),
		"IDENTIFY must NOT claim 48-bit LBA (word 83 bit 10) -- the RiscPC IDE cannot do it");
	cr_assert_neq(id[1], 65535,
		"IDENTIFY must report the real cylinder count, not the ~32 GB placeholder");
}

Test(ide, lba_access_hits_the_correct_sector_on_a_boot_block_image, .fini = disc_teardown)
{
	/* The skip512 + LBA data-corruption case. On a boot-block image, an
	   LBA-addressed access must map logical sector N to file sector N+1. The
	   old code fell back to CHS for skip512 images and hit a wholly different
	   sector -- reading/writing the wrong place on disc. */
	const uint32_t LBA = 1000;
	uint8_t marker[512], got[512];
	memset(marker, 0xA5, sizeof marker);

	/* Read path: plant a marker at the CORRECT file offset, read it via LBA. */
	disc_make(8192, 1, 0x3C);   /* whole disc filled with a different pattern */
	disc_poke(disc_file_offset(LBA, 1), marker, 512);
	cr_assert(ata_read_sector(0, LBA, got));
	cr_assert_arr_eq(got, marker, 512,
		"LBA read landed on the wrong sector (skip512+LBA offset bug)");

	/* Write path: write via LBA, confirm it landed at the CORRECT file offset. */
	disc_make(8192, 1, 0x3C);
	cr_assert(ata_write_sector(0, LBA, marker));
	disc_peek(disc_file_offset(LBA, 1), got, 512);
	cr_assert_arr_eq(got, marker, 512,
		"LBA write landed on the wrong sector (skip512+LBA offset bug)");
}

Test(ide, access_past_end_of_disc_is_rejected_with_idnf, .fini = disc_teardown)
{
	disc_make(64, 0, 0x00);
	uint8_t buf[512];
	memset(buf, 0x5A, sizeof buf);

	cr_assert_not(ata_read_sector(0, 64, buf),
		"reading past the end of the disc must fail, not silently zero-fill");
	cr_assert(ata_status() & ST_ERR);
	cr_assert_eq(ata_error(), ERR_IDNF);

	cr_assert_not(ata_write_sector(0, 100, buf),
		"writing past the end of the disc must fail, not extend the image");
	cr_assert_eq(ata_error(), ERR_IDNF);
}

Test(ide, unimplemented_command_aborts_instead_of_crashing, .fini = disc_teardown)
{
	/* A guest issuing an unsupported command (here NOP 0x00, and an unknown
	   opcode) must get ABRT back, never take the emulator down. The unfixed
	   ide.c called fatal() -> abort(), so this test crashes against it. */
	disc_make(64, 0, 0x00);

	writeide(R_CMD, CMD_NOP);
	cr_assert(ata_status() & ST_ERR);
	cr_assert_eq(ata_error(), ERR_ABRT);

	writeide(R_CMD, 0xFD);
	cr_assert(ata_status() & ST_ERR);
	cr_assert_eq(ata_error(), ERR_ABRT);
}

Test(ide, soft_reset_reports_diagnostic_passed, .fini = disc_teardown)
{
	/* RISC OS 5 auto-detects IDE by issuing an ATA soft reset (SRST) and then
	   reading the error register, treating anything other than 0x01/0x81 as
	   "no drive present". The reset must post the diagnostic code 0x01. */
	disc_make(64, 0, 0x00);
	ata_soft_reset();
	cr_assert_eq(ata_error(), 0x01,
		"soft reset must post ATA diagnostic 0x01 so RISC OS 5 detects the drive");
}
