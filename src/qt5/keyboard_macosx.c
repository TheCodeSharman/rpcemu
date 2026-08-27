/*
  RPCEmu - An Acorn system emulator

  Copyright (C) 2017 Matthew Howkins

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

/* macOS keyboard mapping: Carbon virtual key code -> PS/2 Set 2 make code.
   Qt supplies the virtual key code via QKeyEvent::nativeVirtualKey().

   The key codes are the kVK_* constants from
   Carbon.framework/Frameworks/HIToolbox.framework/Headers/Events.h

   NOTE: the table is terminated with KEY_MAP_END rather than 0, because
   kVK_ANSI_A is 0x00 -- a zero sentinel would truncate the table at 'A'.

   This table assumes a British layout. Keys that differ on other layouts
   (notably Y/Z, which are transposed on French keyboards) are marked. */

#include <stddef.h>
#include <stdint.h>

#include <Carbon/Carbon.h>

#include "keyboard.h"

#define KEY_MAP_END 0xffffu

typedef struct {
	uint32_t	virtual_key;	// Carbon virtual key code (kVK_*)
	uint8_t		set_2[8];	// PS/2 Set 2 make code
} KeyMapInfo;

static const KeyMapInfo key_map[] = {
	{ kVK_Escape, { 0x76 } },		// Escape
	{ kVK_ISO_Section, { 0x0e } },		// `
	{ kVK_ANSI_1, { 0x16 } },		// 1
	{ kVK_ANSI_2, { 0x1e } },		// 2
	{ kVK_ANSI_3, { 0x26 } },		// 3
	{ kVK_ANSI_4, { 0x25 } },		// 4
	{ kVK_ANSI_5, { 0x2e } },		// 5
	{ kVK_ANSI_6, { 0x36 } },		// 6
	{ kVK_ANSI_7, { 0x3d } },		// 7
	{ kVK_ANSI_8, { 0x3e } },		// 8
	{ kVK_ANSI_9, { 0x46 } },		// 9
	{ kVK_ANSI_0, { 0x45 } },		// 0
	{ kVK_ANSI_Minus, { 0x4e } },		// -
	{ kVK_ANSI_Equal, { 0x55 } },		// =
	{ kVK_Delete, { 0x66 } },		// Backspace
	{ kVK_Tab, { 0x0d } },		// Tab
	{ kVK_ANSI_Q, { 0x15 } },		// Q
	{ kVK_ANSI_W, { 0x1d } },		// W
	{ kVK_ANSI_E, { 0x24 } },		// E
	{ kVK_ANSI_R, { 0x2d } },		// R
	{ kVK_ANSI_T, { 0x2c } },		// T
	{ kVK_ANSI_Y, { 0x35 } },		// Y (layout-dependent)
	{ kVK_ANSI_U, { 0x3c } },		// U
	{ kVK_ANSI_I, { 0x43 } },		// I
	{ kVK_ANSI_O, { 0x44 } },		// O
	{ kVK_ANSI_P, { 0x4d } },		// P
	{ kVK_ANSI_LeftBracket, { 0x54 } },	// [
	{ kVK_ANSI_RightBracket, { 0x5b } },	// ]
	{ kVK_Return, { 0x5a } },		// Return

	/* Modifier keys. macOS reports these through NSEvent's modifierFlags mask
	   rather than as key events, but Qt's cocoa plugin turns each change of the
	   mask back into a QKeyEvent in -[QNSView flagsChanged:], and sets
	   nativeVirtualKey() to the real [nsevent keyCode]. So they arrive here like
	   any other key and need nothing more than a table entry -- which is why
	   Ctrl (the one entry that was here) worked while Shift and Alt did not.

	   Option is mapped to Alt: it is the key Apple labels "alt", and RISC OS
	   needs Alt far more than it needs anything Command could stand for.
	   Command follows the other platforms' Left/Right Win mapping.

	   Qt derives press-versus-release from a delta on the whole mask, so it
	   cannot see the second of two same-side-mask modifiers: holding left Shift
	   and then pressing right Shift produces no event, because the Shift bit was
	   already set. Both are mapped anyway -- either alone behaves correctly. */
	{ kVK_Shift, { 0x12 } },		// Left Shift
	{ kVK_RightShift, { 0x59 } },		// Right Shift
	{ kVK_Control, { 0x14 } },		// Left Ctrl
	{ kVK_RightControl, { 0xe0, 0x14 } },	// Right Ctrl
	{ kVK_Option, { 0x11 } },		// Left Alt
	{ kVK_RightOption, { 0xe0, 0x11 } },	// Right Alt
	{ kVK_CapsLock, { 0x58 } },		// Caps Lock (see main_window.cpp)
	{ kVK_Command, { 0xe0, 0x1f } },	// Left Win
	{ kVK_RightCommand, { 0xe0, 0x27 } },	// Right Win
	{ kVK_ANSI_A, { 0x1c } },		// A
	{ kVK_ANSI_S, { 0x1b } },		// S
	{ kVK_ANSI_D, { 0x23 } },		// D
	{ kVK_ANSI_F, { 0x2b } },		// F
	{ kVK_ANSI_G, { 0x34 } },		// G
	{ kVK_ANSI_H, { 0x33 } },		// H (layout-dependent)
	{ kVK_ANSI_J, { 0x3b } },		// J
	{ kVK_ANSI_K, { 0x42 } },		// K
	{ kVK_ANSI_L, { 0x4b } },		// L
	{ kVK_ANSI_Semicolon, { 0x4c } },		// ;
	{ kVK_ANSI_Quote, { 0x52 } },		// '
	{ kVK_ANSI_Backslash, { 0x5d } },		// # (International only)
	{ kVK_ANSI_Grave, { 0x61 } },		// `
	{ kVK_ANSI_Z, { 0x1a } },		// Z (layout-dependent)
	{ kVK_ANSI_X, { 0x22 } },		// X
	{ kVK_ANSI_C, { 0x21 } },		// C
	{ kVK_ANSI_V, { 0x2a } },		// V
	{ kVK_ANSI_B, { 0x32 } },		// B
	{ kVK_ANSI_N, { 0x31 } },		// N
	{ kVK_ANSI_M, { 0x3a } },		// M
	{ kVK_ANSI_Comma, { 0x41 } },		// ,
	{ kVK_ANSI_Period, { 0x49 } },		// .
	{ kVK_ANSI_Slash, { 0x4a } },		// /
	{ kVK_Space, { 0x29 } },		// Space
	{ kVK_F1, { 0x05 } },		// F1
	{ kVK_F2, { 0x06 } },		// F2
	{ kVK_F3, { 0x04 } },		// F3
	{ kVK_F4, { 0x0c } },		// F4
	{ kVK_F5, { 0x03 } },		// F5
	{ kVK_F6, { 0x0b } },		// F6
	{ kVK_F7, { 0x83 } },		// F7
	{ kVK_F8, { 0x0a } },		// F8
	{ kVK_F9, { 0x01 } },		// F9
	{ kVK_F10, { 0x09 } },		// F10
	{ kVK_F11, { 0x78 } },		// F11
	{ kVK_F12, { 0x07 } },		// F12
	{ kVK_F13, { 0xe0, 0x7c } },		// Print Screen/SysRq
	{ kVK_F14, { 0x7e } },		// Scroll Lock
	{ kVK_F15, { 0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77 } },		// Break
	{ kVK_ANSI_KeypadClear, { 0x77 } },	// Keypad Num Lock
	{ kVK_ANSI_KeypadDivide, { 0xe0, 0x4a } },	// Keypad /
	{ kVK_ANSI_KeypadMultiply, { 0x7c } },	// Keypad *
	{ kVK_ANSI_Keypad7, { 0x6c } },		// Keypad 7
	{ kVK_ANSI_Keypad8, { 0x75 } },		// Keypad 8
	{ kVK_ANSI_Keypad9, { 0x7d } },		// Keypad 9
	{ kVK_ANSI_KeypadMinus, { 0x7b } },	// Keypad -
	{ kVK_ANSI_Keypad4, { 0x6b } },		// Keypad 4
	{ kVK_ANSI_Keypad5, { 0x73 } },		// Keypad 5
	{ kVK_ANSI_Keypad6, { 0x74 } },		// Keypad 6
	{ kVK_ANSI_KeypadPlus, { 0x79 } },		// Keypad +
	{ kVK_ANSI_Keypad1, { 0x69 } },		// Keypad 1
	{ kVK_ANSI_Keypad2, { 0x72 } },		// Keypad 2
	{ kVK_ANSI_Keypad3, { 0x7a } },		// Keypad 3
	{ kVK_ANSI_Keypad0, { 0x70 } },		// Keypad 0
	{ kVK_ANSI_KeypadDecimal, { 0x71 } },	// Keypad .
	{ kVK_ANSI_KeypadEnter, { 0xe0, 0x5a } },	// Keypad Enter
	{ kVK_Function, { 0xe0, 0x70 } },		// Insert
	{ kVK_ForwardDelete, { 0xe0, 0x71 } },		// Delete
	{ kVK_Home, { 0xe0, 0x6c } },		// Home
	{ kVK_End, { 0xe0, 0x69 } },		// End
	{ kVK_UpArrow, { 0xe0, 0x75 } },		// Up
	{ kVK_DownArrow, { 0xe0, 0x72 } },		// Down
	{ kVK_LeftArrow, { 0xe0, 0x6b } },		// Left
	{ kVK_RightArrow, { 0xe0, 0x74 } },		// Right
	{ kVK_PageUp, { 0xe0, 0x7d } },		// Page Up
	{ kVK_PageDown, { 0xe0, 0x7a } },		// Page Down
	{ kVK_F16, { 0xe0, 0x2f } },		// Application (Win Menu)
	{ KEY_MAP_END, { 0, 0 } },
};

const uint8_t *
keyboard_map_key(uint32_t native_scancode)
{
	size_t k;

	for (k = 0; key_map[k].virtual_key != KEY_MAP_END; k++) {
		if (key_map[k].virtual_key == native_scancode) {
			return key_map[k].set_2;
		}
	}
	return NULL;
}
