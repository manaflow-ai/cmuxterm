//go:build darwin

package main

import "golang.org/x/sys/unix"

func flushTerminalInput(fd int) error {
	// Darwin's TIOCFLUSH takes the stdio FREAD bit as its argument. x/sys/unix
	// does not expose that libc macro, so keep the ABI value local.
	const fread = 0x00000001
	return unix.IoctlSetPointerInt(fd, unix.TIOCFLUSH, fread)
}
